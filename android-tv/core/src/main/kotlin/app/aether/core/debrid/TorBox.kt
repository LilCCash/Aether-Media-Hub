package app.aether.core.debrid

import app.aether.core.addons.ResourceUrlBuilder
import app.aether.core.json.Flex
import app.aether.core.json.flexBool
import app.aether.core.json.flexDouble
import app.aether.core.json.flexInt
import app.aether.core.json.flexLong
import app.aether.core.json.flexString
import app.aether.core.json.obj
import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.net.HttpResponse
import app.aether.core.util.SecretStore
import java.text.Normalizer
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/** Why a TorBox step failed; [message] is user-facing Italian text and never contains the key or a link. */
sealed class DebridError(override val message: String, val isRetryable: Boolean = false) : Exception(message) {
    object NotConfigured : DebridError("Per riprodurre i torrent serve la chiave TorBox: inseriscila in Impostazioni ▸ Servizi.")
    object InvalidKey : DebridError("TorBox ha rifiutato la chiave: controllala in Impostazioni ▸ Servizi.")
    object NotCached : DebridError("Questo torrent non è nella cache di TorBox: scaricarlo richiede tempo e spazio sul tuo account.")
    object NoVideo : DebridError("Nel torrent non c'è nessun file video riproducibile.")
    object ArchivesOnly : DebridError("Il torrent contiene solo archivi (zip/rar): TorBox non può trasmetterli come video.")
    class NoConfidentMatch(val candidates: List<DebridFile>) :
        DebridError("Non riesco a capire quale file corrisponde a questo episodio: scegli quello giusto.")
    class Api(code: String, detail: String?) : DebridError("TorBox ha risposto con un errore (${safe(code)})${detail?.let { ": $it" } ?: ""}.")
    class Network(detail: String) : DebridError("Impossibile contattare TorBox: $detail", isRetryable = true)
    class RateLimited : DebridError("TorBox chiede di rallentare: riprova tra poco.", isRetryable = true)
    class Failed(detail: String) : DebridError(detail)
    object Cancelled : DebridError("Operazione annullata.")

    companion object {
        fun safe(code: String) = code.take(40).filter { it.isLetterOrDigit() || it in "_-" }
    }
}

data class DebridFile(val id: Int, val name: String, val shortName: String, val size: Long?, val mimeType: String?, val zipped: Boolean, val infected: Boolean)

data class TorBoxTorrent(
    val id: Int,
    val hash: String?,
    val name: String?,
    val size: Long?,
    val progress: Double?,
    val downloadState: String?,
    val downloadSpeed: Long?,
    val eta: Int?,
    val downloadFinished: Boolean,
    val downloadPresent: Boolean,
    val files: List<DebridFile>,
)

data class TorBoxUser(val plan: Int?, val isSubscribed: Boolean?, val premiumExpiresAt: String?)

/** A snapshot of what TorBox is doing, for the progress line under the source. */
data class DebridProgress(val message: String, val fraction: Double?, val detail: String?)

/** The TorBox API (https://api.torbox.app/v1/api). The key lives in the [SecretStore]; it is never logged. */
class TorBoxClient(
    private val http: HttpClient,
    private val secrets: SecretStore,
    private val baseUrl: String = PRODUCTION_BASE_URL,
) {
    val isConfigured: Boolean get() = !secrets.get(KEY_SECRET).isNullOrBlank()

    fun saveKey(key: String) {
        val clean = key.trim()
        require(isWellFormedKey(clean)) { "chiave non valida" }
        secrets.put(KEY_SECRET, clean)
    }

    fun removeKey() = secrets.remove(KEY_SECRET)

    private fun key(): String = secrets.get(KEY_SECRET)?.takeIf { it.isNotBlank() } ?: throw DebridError.NotConfigured

    suspend fun fetchUser(): TorBoxUser {
        val data = call("GET", "/user/me", query = listOf("settings" to "false")).data as? JsonObject ?: throw DebridError.Failed("Risposta di TorBox non valida.")
        return TorBoxUser(data.flexInt("plan"), data.flexBool("is_subscribed"), data.flexString("premium_expires_at"))
    }

    /** Which of the (canonical lowercase) hashes TorBox has cached. At most 100 per call. */
    suspend fun checkCached(hashes: List<String>): Set<String> {
        if (hashes.isEmpty()) return emptySet()
        val body = buildJsonObject { putJsonArray("hashes") { hashes.forEach { add(JsonPrimitive(it)) } } }
        val data = call("POST", "/torrents/checkcached", query = listOf("format" to "list", "list_files" to "false"), body = body.toString(), json = true).data
        val wanted = hashes.toSet()
        val found = HashSet<String>()
        fun add(element: JsonElement?) {
            val hash = (element as? JsonObject)?.flexString("hash")?.lowercase()
            if (hash != null && hash in wanted) found.add(hash)
        }
        when (data) {
            is JsonArray -> data.forEach { add(it) }
            is JsonObject -> data.forEach { (name, value) ->
                // `format=object` shape: the hash is the key; list shape sits under "items".
                if (name.lowercase() in wanted && value !is JsonPrimitive) found.add(name.lowercase())
            }
            else -> {}
        }
        return found
    }

    /** `createtorrent`. With [onlyIfCached] TorBox adds the torrent only when it already has it and never starts a download. */
    suspend fun createTorrent(magnet: String, onlyIfCached: Boolean): Int {
        var form = "magnet=" + ResourceUrlBuilder.encode(magnet)
        if (onlyIfCached) form += "&add_only_if_cached=true"
        form += "&allow_zip=false"
        val envelope = try {
            call("POST", "/torrents/createtorrent", body = form, json = false)
        } catch (error: DebridError.Api) {
            if (onlyIfCached && meansNotCached(error.message)) throw DebridError.NotCached
            throw error
        }
        val data = envelope.data as? JsonObject
        return data?.flexInt("torrent_id") ?: data?.flexInt("queued_id") ?: throw DebridError.Failed("TorBox non ha restituito il torrent.")
    }

    suspend fun myList(id: Int): TorBoxTorrent? {
        val data = call("GET", "/torrents/mylist", query = listOf("bypass_cache" to "true", "id" to id.toString()), maxBytes = 16 * 1024 * 1024).data
        val item = when (data) {
            is JsonObject -> data
            is JsonArray -> data.firstOrNull { (it as? JsonObject)?.flexInt("id") == id } as? JsonObject
            else -> null
        } ?: return null
        return parseTorrent(item)
    }

    /** The CDN link of one file. The link may carry the account key itself: keep it in memory for the session, never log or send it. */
    suspend fun requestDownloadLink(torrentId: Int, fileId: Int): String {
        val query = listOf(
            "torrent_id" to torrentId.toString(), "file_id" to fileId.toString(), "zip_link" to "false", "redirect" to "false", "append_name" to "false",
        )
        val data = call("GET", "/torrents/requestdl", query = query, tokenInQuery = true).data
        val link = (data as? JsonPrimitive)?.content?.trim().orEmpty()
        if (!(link.startsWith("https://") || link.startsWith("http://"))) throw DebridError.Failed("TorBox non ha restituito un link di download.")
        if (link.startsWith("http://") && link.contains(key())) throw DebridError.Failed("Il link di download non è cifrato (http).")
        return link
    }

    private class Envelope(val data: JsonElement?)

    private suspend fun call(
        method: String,
        path: String,
        query: List<Pair<String, String>> = emptyList(),
        body: String? = null,
        json: Boolean = false,
        tokenInQuery: Boolean = false,
        maxBytes: Int = 4 * 1024 * 1024,
    ): Envelope {
        val key = key()
        val params = ArrayList(query)
        if (tokenInQuery) params.add("token" to key)
        val url = baseUrl.trimEnd('/') + path + if (params.isEmpty()) "" else "?" + params.joinToString("&") { "${ResourceUrlBuilder.encode(it.first)}=${ResourceUrlBuilder.encode(it.second)}" }
        val headers = if (tokenInQuery) emptyMap() else mapOf("Authorization" to "Bearer $key")
        var attempt = 0
        while (true) {
            val response: HttpResponse = try {
                http.send(HttpRequest(url, method, headers, body, if (json) "application/json" else "application/x-www-form-urlencoded", 20, maxBytes))
            } catch (error: AddonError) {
                if (attempt < 2 && method == "GET" && error.isTransient) { attempt++; delay(600L * attempt); continue }
                throw DebridError.Network(scrub(error.message, key))
            }
            if (response.status == 429) {
                if (attempt < 2) { attempt++; delay(1500L * attempt); continue }
                throw DebridError.RateLimited()
            }
            if (response.status >= 500 && method == "GET" && attempt < 2) { attempt++; delay(800L * attempt); continue }
            return parse(response, key)
        }
    }

    private fun parse(response: HttpResponse, key: String): Envelope {
        val root = Flex.parse(response.text) as? JsonObject
        val code = root?.flexString("error")
        val detail = root?.flexString("detail")?.let { scrub(it, key).take(160) }
        if (response.status == 401 || response.status == 403 || code?.uppercase() in setOf("BAD_TOKEN", "AUTH_ERROR", "NO_AUTH", "INVALID_TOKEN") ||
            detail?.contains("not authenticated", true) == true
        ) throw DebridError.InvalidKey
        if (response.status == 409 && code == null) throw DebridError.Api("CONFLICT", detail)
        if (!response.isSuccess || root?.flexBool("success") == false || !code.isNullOrEmpty()) {
            throw DebridError.Api(code ?: "HTTP_${response.status}", detail)
        }
        return Envelope(root?.get("data"))
    }

    companion object {
        const val PRODUCTION_BASE_URL = "https://api.torbox.app/v1/api"
        const val KEY_SECRET = "torbox.key"

        fun isWellFormedKey(key: String): Boolean = key.isNotEmpty() && key.length <= 256 && key.all { it.code in 0x21..0x7E }

        fun meansNotCached(text: String): Boolean {
            val lower = text.lowercase()
            return "cache" in lower || "conflict" in lower || "409" in lower
        }

        fun scrub(text: String, key: String): String = if (key.isEmpty()) text else text.replace(key, "•••")

        fun parseTorrent(item: JsonObject): TorBoxTorrent? {
            val id = item.flexInt("id") ?: return null
            val files = ((item["files"] as? JsonArray) ?: JsonArray(emptyList())).mapNotNull { element ->
                val f = element as? JsonObject ?: return@mapNotNull null
                val fileId = f.flexInt("id") ?: return@mapNotNull null
                val name = f.flexString("name") ?: return@mapNotNull null
                DebridFile(
                    id = fileId, name = name, shortName = f.flexString("short_name") ?: name.substringAfterLast('/'),
                    size = f.flexLong("size"), mimeType = f.flexString("mimetype"), zipped = f.flexBool("zipped") ?: false,
                    infected = f.flexBool("infected") ?: false,
                )
            }
            return TorBoxTorrent(
                id = id, hash = item.flexString("hash"), name = item.flexString("name"), size = item.flexLong("size"),
                progress = item.flexDouble("progress"), downloadState = item.flexString("download_state"),
                downloadSpeed = item.flexLong("download_speed"), eta = item.flexInt("eta"),
                downloadFinished = item.flexBool("download_finished") ?: false, downloadPresent = item.flexBool("download_present") ?: false,
                files = files,
            )
        }
    }
}

/** An episode asked for by a Stremio video id (`tt0944947:1:2`). */
data class DebridEpisode(val season: Int, val episode: Int) {
    companion object {
        fun parse(stremioId: String?): DebridEpisode? {
            val parts = stremioId?.split(':') ?: return null
            if (parts.size < 3) return null
            val season = parts[parts.size - 2].toIntOrNull() ?: return null
            val episode = parts[parts.size - 1].toIntOrNull() ?: return null
            return DebridEpisode(season, episode)
        }

        fun expectsEpisode(stremioId: String?): Boolean = (stremioId?.count { it == ':' } ?: 0) >= 2
    }
}

/** Chooses the file to stream out of a torrent: a name hint first, then the episode number, then (films only) the largest video. */
object TorBoxFileMatcher {
    sealed class Outcome {
        data class Selected(val file: DebridFile) : Outcome()
        data class NoConfidentMatch(val candidates: List<DebridFile>) : Outcome()
        object NoVideo : Outcome()
        object ArchivesOnly : Outcome()
    }

    private val videoExtensions = setOf("mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg")
    private val archiveExtensions = setOf("zip", "rar", "7z", "tar", "gz", "iso")

    fun isVideo(file: DebridFile): Boolean {
        val ext = file.name.substringAfterLast('.', "").lowercase()
        return ext in videoExtensions || file.mimeType?.startsWith("video/") == true
    }

    fun select(files: List<DebridFile>, filename: String?, episode: DebridEpisode?, expectsEpisode: Boolean, fileIndexHint: Int? = null): Outcome {
        val videos = files.filter { isVideo(it) }
        if (videos.isEmpty()) {
            return if (files.any { it.name.substringAfterLast('.', "").lowercase() in archiveExtensions }) Outcome.ArchivesOnly else Outcome.NoVideo
        }
        val usable = videos.filter { !it.infected && !it.zipped }
        if (usable.isEmpty()) return Outcome.ArchivesOnly
        val hint = filename?.trim().orEmpty()
        if (hint.isNotEmpty()) {
            val matches = usable.filter { nameMatches(hint, it) }
            if (matches.isNotEmpty()) return Outcome.Selected(pick(matches, fileIndexHint, files, largest = false))
        }
        if (expectsEpisode) {
            if (episode != null) {
                val matches = usable.filter { tagMatches(it, episode) }
                if (matches.isNotEmpty()) return Outcome.Selected(pick(matches, fileIndexHint, files, largest = false))
            }
            if (usable.size == 1) return Outcome.Selected(usable[0])
            return Outcome.NoConfidentMatch(usable)
        }
        return Outcome.Selected(pick(usable, fileIndexHint, files, largest = true))
    }

    private fun pick(candidates: List<DebridFile>, indexHint: Int?, all: List<DebridFile>, largest: Boolean): DebridFile {
        if (candidates.size == 1) return candidates[0]
        indexHint?.let { hint -> all.getOrNull(hint)?.let { byIndex -> candidates.firstOrNull { it.id == byIndex.id }?.let { return it } } }
        return candidates.maxByOrNull { it.size ?: 0L } ?: candidates[0]
    }

    /** Compared exactly, then the way Torrentio normalises names (`&` → `and`, only letters and digits). */
    fun nameMatches(hint: String, file: DebridFile): Boolean {
        val names = listOf(file.name, file.shortName, file.name.substringAfterLast('/'))
        if (names.any { it.equals(hint, true) }) return true
        val wanted = canonical(hint)
        return wanted.isNotEmpty() && names.any { canonical(it) == wanted }
    }

    fun canonical(text: String): String = Normalizer.normalize(text.replace("&", "and"), Normalizer.Form.NFC).lowercase().filter { it.isLetterOrDigit() }

    private val patterns = listOf(
        Regex("[Ss](\\d{1,2})[ ._-]?[Ee](\\d{1,3})"),
        Regex("(?<![0-9])(\\d{1,2})[xX](\\d{2,3})(?![0-9])"),
        Regex("[Ss]eason[ ._-]?(\\d{1,2})[ ._-]*[Ee]pisode[ ._-]?(\\d{1,3})", RegexOption.IGNORE_CASE),
    )

    fun tagMatches(file: DebridFile, wanted: DebridEpisode): Boolean {
        for (name in listOf(file.shortName, file.name)) {
            for (pattern in patterns) {
                for (match in pattern.findAll(name)) {
                    if (match.groupValues[1].toInt() == wanted.season && match.groupValues[2].toInt() == wanted.episode) return true
                }
            }
        }
        return false
    }
}

data class DebridRequest(
    val infoHash: String,
    val trackers: List<String>,
    val fileIndex: Int?,
    val filename: String?,
    val stremioId: String?,
)

/** Turns a torrent stream into a link a player can open, through the user's TorBox account. */
class DebridResolver(private val client: TorBoxClient) {
    sealed class Mode { object CachedOnly : Mode(); object AllowDownload : Mode() }

    /** [chooseFile] is asked only when no file can be told from the others; returning null cancels. */
    suspend fun resolve(
        request: DebridRequest,
        mode: Mode,
        onProgress: (DebridProgress) -> Unit = {},
        chooseFile: suspend (List<DebridFile>) -> DebridFile? = { null },
    ): String {
        if (!TorBoxClient.isWellFormedHash(request.infoHash)) throw DebridError.Failed("Identificatore del torrent non valido.")
        val hash = request.infoHash.lowercase()
        onProgress(DebridProgress("Controllo TorBox…", null, null))
        val magnet = buildString {
            append("magnet:?xt=urn:btih:").append(hash)
            request.trackers.take(8).forEach { append("&tr=").append(ResourceUrlBuilder.encode(it)) }
        }
        val torrentId = client.createTorrent(magnet, onlyIfCached = mode is Mode.CachedOnly)
        var torrent: TorBoxTorrent? = client.myList(torrentId)
        var waited = 0
        while (true) {
            val current = torrent
            if (current != null && (current.downloadFinished || current.downloadPresent) && current.files.isNotEmpty()) break
            if (mode is Mode.CachedOnly && waited >= 6) throw DebridError.NotCached
            if (waited > 600) throw DebridError.Failed("TorBox sta ancora scaricando: riprova più tardi.")
            if (current != null) {
                val fraction = current.progress?.let { if (it > 1.0) it / 100.0 else it }?.coerceIn(0.0, 1.0)
                onProgress(DebridProgress("TorBox sta scaricando…", fraction, listOfNotNull(
                    fraction?.let { "${(it * 100).toInt()}%" },
                    current.downloadSpeed?.takeIf { it > 0 }?.let { "%.1f MB/s".format(it / 1_048_576.0) },
                    current.eta?.takeIf { it > 0 }?.let { "~${it / 60} min" },
                ).joinToString(" · ").ifEmpty { null }))
            } else {
                onProgress(DebridProgress("In attesa di TorBox…", null, null))
            }
            delay(if (mode is Mode.CachedOnly) 700 else 2000)
            waited++
            torrent = client.myList(torrentId)
        }
        val files = torrent!!.files
        val episode = DebridEpisode.parse(request.stremioId)
        val outcome = TorBoxFileMatcher.select(files, request.filename, episode, DebridEpisode.expectsEpisode(request.stremioId), request.fileIndex)
        val file = when (outcome) {
            is TorBoxFileMatcher.Outcome.Selected -> outcome.file
            is TorBoxFileMatcher.Outcome.NoConfidentMatch -> chooseFile(outcome.candidates) ?: throw DebridError.Cancelled
            TorBoxFileMatcher.Outcome.NoVideo -> throw DebridError.NoVideo
            TorBoxFileMatcher.Outcome.ArchivesOnly -> throw DebridError.ArchivesOnly
        }
        onProgress(DebridProgress("Preparo il link…", null, null))
        return client.requestDownloadLink(torrent.id, file.id)
    }
}

private fun TorBoxClient.Companion.isWellFormedHash(hash: String) = hash.length == 40 && hash.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
