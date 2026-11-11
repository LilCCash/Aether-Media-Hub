package app.aether.core.debrid

import app.aether.core.addons.ResourceUrlBuilder
import app.aether.core.json.Flex
import app.aether.core.json.flexDouble
import app.aether.core.json.flexInt
import app.aether.core.json.flexLong
import app.aether.core.json.flexString
import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.util.SecretStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

data class RealDebridUser(val type: String?, val expiration: String?) {
    val isPremium: Boolean get() = type.equals("premium", true)
    val planName: String get() = if (isPremium) "Premium" else type?.replaceFirstChar { it.uppercase() } ?: "Free"
}

/**
 * The Real-Debrid REST API (https://api.real-debrid.com/rest/1.0) with the viewer's private API token (Bearer). The token lives in
 * the [SecretStore] and is read at every call; it never reaches a log or an error message.
 *
 * Real-Debrid retired `/torrents/instantAvailability`: nothing here claims a torrent is ready before it is in the account. In
 * cached-only mode a torrent is played only when it is already in the account; otherwise the viewer is asked to add it.
 */
class RealDebridClient(
    private val http: HttpClient,
    private val secrets: SecretStore,
    private val baseUrl: String = PRODUCTION_BASE_URL,
    private val pollMillis: Long = 3000,
    private val maxWaitMillis: Long = 20 * 60_000,
) {
    val isConfigured: Boolean get() = !secrets.get(KEY_SECRET).isNullOrBlank()

    fun saveKey(key: String) {
        val clean = key.trim()
        require(TorBoxClient.isWellFormedKey(clean)) { "token non valido" }
        secrets.put(KEY_SECRET, clean)
    }

    fun removeKey() = secrets.remove(KEY_SECRET)

    /** The token, for the addon addresses the routing switches to Real-Debrid. Never log it. */
    fun token(): String? = secrets.get(KEY_SECRET)?.trim()?.takeIf { it.isNotEmpty() }

    suspend fun fetchUser(): RealDebridUser {
        val root = call("GET", "/user") as? JsonObject ?: throw DebridError.RealDebridApi("RESPONSE")
        return RealDebridUser(root.flexString("type"), root.flexString("expiration"))
    }

    suspend fun resolve(
        request: DebridRequest,
        mode: DebridResolver.Mode,
        onProgress: (DebridProgress) -> Unit = {},
        chooseFile: suspend (List<DebridFile>) -> DebridFile? = { null },
    ): String {
        val hash = request.infoHash.lowercase()
        if (hash.length != 40 || !hash.all { it in '0'..'9' || it in 'a'..'f' }) throw DebridError.Failed("Identificatore del torrent non valido.")
        onProgress(DebridProgress("Controllo Real-Debrid…", null, null))
        val list = call("GET", "/torrents", query = listOf("limit" to "500")) as? JsonArray ?: JsonArray(emptyList())
        var id = list.firstNotNullOfOrNull { item ->
            val obj = item as? JsonObject ?: return@firstNotNullOfOrNull null
            if (obj.flexString("hash")?.lowercase() == hash) obj.flexString("id") else null
        }
        val wasInAccount = id != null
        if (mode is DebridResolver.Mode.CachedOnly && !wasInAccount) throw DebridError.RealDebridNotInAccount
        if (id == null) {
            onProgress(DebridProgress("Aggiungo il torrent a Real-Debrid…", null, null))
            val magnet = buildString {
                append("magnet:?xt=urn:btih:").append(hash)
                request.trackers.take(8).forEach { append("&tr=").append(ResourceUrlBuilder.encode(it)) }
            }
            val added = call("POST", "/torrents/addMagnet", form = mapOf("magnet" to magnet)) as? JsonObject
            id = added?.flexString("id")?.takeIf { it.isNotEmpty() } ?: throw DebridError.RealDebridApi("NO_ID")
            call("POST", "/torrents/selectFiles/$id", form = mapOf("files" to "all"))
        }
        val deadline = System.currentTimeMillis() + if (mode is DebridResolver.Mode.CachedOnly) 60_000 else maxWaitMillis
        var info: JsonObject
        while (true) {
            info = call("GET", "/torrents/info/$id") as? JsonObject ?: throw DebridError.RealDebridApi("RESPONSE")
            val status = info.flexString("status") ?: "unknown"
            if (status == "downloaded") break
            if (status in FAILED_STATES) throw DebridError.RealDebridItemFailed(status)
            if (status == "waiting_files_selection") call("POST", "/torrents/selectFiles/$id", form = mapOf("files" to "all"))
            val fraction = info.flexDouble("progress")?.let { (it / 100).coerceIn(0.0, 1.0) }
            onProgress(DebridProgress(statusText(status), fraction, listOfNotNull(
                fraction?.let { "${(it * 100).toInt()}%" },
                info.flexLong("speed")?.takeIf { it > 0 }?.let { "%.1f MB/s".format(it / 1_048_576.0) },
            ).joinToString(" · ").ifEmpty { null }))
            if (System.currentTimeMillis() > deadline) throw DebridError.Failed("Real-Debrid sta ancora preparando il torrent: riprova più tardi.")
            delay(pollMillis)
        }
        val raw = (info["files"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
        // Only the selected files have a link, in the same order.
        val selected = raw.filter { it.flexInt("selected") == 1 }.ifEmpty { raw }
        val files = selected.mapNotNull { f ->
            val fileId = f.flexInt("id") ?: return@mapNotNull null
            val path = f.flexString("path") ?: return@mapNotNull null
            DebridFile(fileId, path.trimStart('/'), path.substringAfterLast('/'), f.flexLong("bytes"), null, zipped = false, infected = false)
        }
        val episode = DebridEpisode.parse(request.stremioId)
        val file = when (val outcome = TorBoxFileMatcher.select(files, request.filename, episode, DebridEpisode.expectsEpisode(request.stremioId), null)) {
            is TorBoxFileMatcher.Outcome.Selected -> outcome.file
            is TorBoxFileMatcher.Outcome.NoConfidentMatch -> chooseFile(outcome.candidates) ?: throw DebridError.Cancelled
            TorBoxFileMatcher.Outcome.NoVideo -> throw DebridError.NoVideo
            TorBoxFileMatcher.Outcome.ArchivesOnly -> throw DebridError.ArchivesOnly
        }
        val links = (info["links"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
        val index = files.indexOfFirst { it.id == file.id }
        val link = links.getOrNull(index) ?: throw DebridError.Failed("Real-Debrid non ha restituito il link del file scelto.")
        onProgress(DebridProgress("Preparo il link…", null, null))
        val unrestricted = call("POST", "/unrestrict/link", form = mapOf("link" to link)) as? JsonObject
        val download = unrestricted?.flexString("download")
        if (download == null || !download.startsWith("https://")) throw DebridError.Failed("Link di riproduzione Real-Debrid non valido.")
        return download
    }

    private fun statusText(status: String) = when (status) {
        "magnet_conversion" -> "Real-Debrid legge il magnet…"
        "queued" -> "In coda su Real-Debrid…"
        "downloading" -> "Real-Debrid sta scaricando…"
        "compressing", "uploading" -> "Real-Debrid sta preparando i file…"
        else -> "In attesa di Real-Debrid…"
    }

    private suspend fun call(method: String, path: String, query: List<Pair<String, String>> = emptyList(), form: Map<String, String>? = null): JsonElement? {
        val token = token() ?: throw DebridError.RealDebridNotConfigured
        val url = baseUrl.trimEnd('/') + path + if (query.isEmpty()) "" else "?" + query.joinToString("&") { "${ResourceUrlBuilder.encode(it.first)}=${ResourceUrlBuilder.encode(it.second)}" }
        val body = form?.entries?.sortedBy { it.key }?.joinToString("&") { "${ResourceUrlBuilder.encode(it.key)}=${ResourceUrlBuilder.encode(it.value)}" }
        val headers = mapOf("Authorization" to "Bearer $token", "Accept" to "application/json")
        var attempt = 0
        while (true) {
            val response = try {
                http.send(HttpRequest(url, method, headers, body, if (body != null) "application/x-www-form-urlencoded" else null, 20, 8 * 1024 * 1024))
            } catch (error: CancellationException) {
                throw error
            } catch (error: AddonError) {
                if (attempt < 2 && method == "GET" && error.isTransient) { attempt++; delay(600L * attempt); continue }
                throw DebridError.RealDebridNetwork()
            }
            when {
                response.status == 401 || response.status == 403 -> throw DebridError.RealDebridInvalidKey
                response.status == 429 -> { if (attempt < 2) { attempt++; delay(1500L * attempt); continue }; throw DebridError.RealDebridRateLimited() }
                response.status >= 500 -> { if (method == "GET" && attempt < 2) { attempt++; delay(800L * attempt); continue }; throw DebridError.RealDebridUnavailable(response.status) }
                response.status == 204 -> return null
                !response.isSuccess -> {
                    val code = (Flex.parse(response.text) as? JsonObject)?.flexString("error") ?: "HTTP_${response.status}"
                    throw DebridError.RealDebridApi(code)
                }
            }
            return if (response.text.isBlank()) null else Flex.parse(response.text)
        }
    }

    companion object {
        const val PRODUCTION_BASE_URL = "https://api.real-debrid.com/rest/1.0"
        const val KEY_SECRET = "realdebrid.key"
        val FAILED_STATES = setOf("error", "virus", "dead", "magnet_error")
    }
}

/** The debrid service the viewer chose in Impostazioni ▸ Servizi. */
@kotlinx.serialization.Serializable
enum class DebridService(val title: String) { TORBOX("TorBox"), REAL_DEBRID("Real-Debrid") }

/** Resolves a torrent with the active service. */
class DebridRouter(val torBox: TorBoxClient, val realDebrid: RealDebridClient, private val active: () -> DebridService) {
    private val torBoxResolver = DebridResolver(torBox)

    val service: DebridService get() = active()
    val isConfigured: Boolean get() = when (active()) { DebridService.TORBOX -> torBox.isConfigured; DebridService.REAL_DEBRID -> realDebrid.isConfigured }

    /** The context the addon routing needs; the token is read now and goes only into addon addresses. */
    fun streamContext(): StreamDebridContext = when (active()) {
        DebridService.TORBOX -> StreamDebridContext(DebridService.TORBOX, null)
        DebridService.REAL_DEBRID -> StreamDebridContext(DebridService.REAL_DEBRID, realDebrid.token())
    }

    suspend fun resolve(
        request: DebridRequest,
        mode: DebridResolver.Mode,
        onProgress: (DebridProgress) -> Unit = {},
        chooseFile: suspend (List<DebridFile>) -> DebridFile? = { null },
    ): String = when (active()) {
        DebridService.TORBOX -> torBoxResolver.resolve(request, mode, onProgress, chooseFile)
        DebridService.REAL_DEBRID -> realDebrid.resolve(request, mode, onProgress, chooseFile)
    }
}

data class StreamDebridContext(val service: DebridService, val realDebridKey: String?)
