package app.aether.core.metadata

import app.aether.core.model.ExternalIds
import app.aether.core.model.MetaItem
import app.aether.core.model.TrailerRef
import app.aether.core.model.Video
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.util.SecretStore
import java.net.URLEncoder
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.concurrent.ConcurrentHashMap
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** What the title page shows beyond an addon's meta, read from TMDB with the user's own key. Empty sections are not shown. */
data class RichDetails(
    val tmdbId: Int,
    val isMovie: Boolean,
    val cast: List<Person> = emptyList(),
    val directors: List<String> = emptyList(),
    val creators: List<String> = emptyList(),
    val companies: List<String> = emptyList(),
    val budget: Long? = null,
    val revenue: Long? = null,
    val trailers: List<TrailerRef> = emptyList(),
    val similar: List<Similar> = emptyList(),
    val status: String? = null,
    val countries: List<String> = emptyList(),
    val originalLanguage: String? = null,
    val seasonCount: Int? = null,
    val episodeCount: Int? = null,
) {
    data class Person(val name: String, val role: String?, val photo: String?)
    data class Similar(val tmdbId: Int, val title: String, val poster: String?, val year: String?, val isMovie: Boolean)

    val isEmpty: Boolean
        get() = cast.isEmpty() && directors.isEmpty() && creators.isEmpty() && companies.isEmpty() && budget == null &&
            revenue == null && trailers.isEmpty() && similar.isEmpty() && status == null
}

/**
 * Optional metadata from TMDB (v3 key or v4 read token) and TheTVDB (v4 key, optional subscriber PIN). Keys come from the
 * encrypted [SecretStore] and are never logged. Addon metadata stays the source of truth for ids and streams: the providers fill
 * what is missing and add the rich section.
 */
class MetadataEnrichment(private val http: HttpClient, private val secrets: SecretStore, private val language: () -> String = { "it-IT" }) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val richCache = ConcurrentHashMap<String, RichDetails>()
    private val episodeCache = ConcurrentHashMap<String, List<TvdbEpisode>>()
    private val tvdbIdCache = ConcurrentHashMap<String, Int>()
    @Volatile private var tvdbToken: Pair<String, String>? = null

    val hasTmdb: Boolean get() = tmdbKey().isNotEmpty()
    val hasTvdb: Boolean get() = tvdbKey().isNotEmpty()

    private fun tmdbKey() = secrets.get(TMDbKey).orEmpty().trim()
    private fun tvdbKey() = secrets.get(TVDbKey).orEmpty().trim()
    private fun tvdbPin() = secrets.get(TVDbPin).orEmpty().trim()

    private class ProviderError(message: String) : Exception(message)

    // MARK: Public

    /** Fills the missing descriptive fields from TMDB, then from TheTVDB; episode thumbnails and summaries come from TheTVDB. */
    suspend fun enrich(meta: MetaItem): MetaItem {
        if (!isTitle(meta)) return meta
        var result = meta
        if (hasTmdb) result = runCatching { applyTmdb(result) }.getOrDefault(result)
        if (hasTvdb) result = runCatching { applyTvdb(result) }.getOrDefault(result)
        return result
    }

    /** The rich section for the title page, or null when TMDB is not configured or knows nothing. */
    suspend fun rich(meta: MetaItem): RichDetails? {
        if (!hasTmdb || !isTitle(meta)) return null
        return runCatching { loadRich(meta) }.getOrNull()?.takeIf { !it.isEmpty }
    }

    /** The IMDb id of a similar title, so it can be opened like any catalog entry. */
    suspend fun imdbIdFor(similar: RichDetails.Similar): String? = runCatching {
        val kind = if (similar.isMovie) "movie" else "tv"
        tmdbGet("/$kind/${similar.tmdbId}/external_ids").str("imdb_id")?.takeIf { it.isNotBlank() }
    }.getOrNull()

    /** Settings: null when the key is accepted, else a short reason. */
    suspend fun checkTmdb(): String? = try { tmdbGet("/configuration"); null } catch (e: Throwable) { reason(e) }
    suspend fun checkTvdb(): String? = try { tvdbBearer(force = true); null } catch (e: Throwable) { reason(e) }

    fun clearCaches() { richCache.clear(); episodeCache.clear(); tvdbIdCache.clear(); tvdbToken = null }

    private fun isTitle(meta: MetaItem) = meta.type in SERIES || meta.type == "movie"
    private fun reason(e: Throwable) = (e as? ProviderError)?.message ?: app.aether.core.net.AddonError.from(e).message

    // MARK: TMDB

    private fun isSeries(meta: MetaItem) = meta.type in SERIES

    private suspend fun resolveTmdb(meta: MetaItem): Pair<String, Int>? {
        val kind = if (isSeries(meta)) "tv" else "movie"
        meta.externalIds.tmdb?.let { return kind to it }
        val imdb = meta.externalIds.imdb ?: meta.imdbId
        if (imdb != null) {
            val found = tmdbGet("/find/$imdb", "external_source" to "imdb_id")
            val hit = found.arr(if (kind == "tv") "tv_results" else "movie_results").firstOrNull()?.int("id")
            if (hit != null) return kind to hit
        }
        val year = meta.year?.let { if (kind == "tv") "first_air_date_year" to "$it" else "year" to "$it" }
        val query = listOfNotNull("query" to meta.name, year)
        val hit = tmdbGet("/search/$kind", *query.toTypedArray()).arr("results").firstOrNull()?.int("id") ?: return null
        return kind to hit
    }

    private suspend fun tmdbDetails(kind: String, id: Int): JsonObject = tmdbGet(
        "/$kind/$id",
        "append_to_response" to "credits,videos,similar,external_ids",
        "include_video_language" to "${language().take(2)},en,null",
    )

    private suspend fun applyTmdb(meta: MetaItem): MetaItem {
        val (kind, id) = resolveTmdb(meta) ?: return meta
        val detail = tmdbDetails(kind, id)
        val series = kind == "tv"
        val credits = detail.obj("credits")
        val genres = detail.arr("genres").mapNotNull { it.str("name") }
        val cast = credits?.arr("cast").orEmpty().take(12).mapNotNull { it.str("name") }
        val directors = credits?.arr("crew").orEmpty().filter { it.str("job") == "Director" }.take(4).mapNotNull { it.str("name") }
        val date = detail.str(if (series) "first_air_date" else "release_date")
        val external = detail.obj("external_ids")
        val trailers = trailersOf(detail)
        return meta.copy(
            poster = meta.poster ?: detail.str("poster_path")?.let { "$IMAGE_BASE/w500$it" },
            background = meta.background ?: detail.str("backdrop_path")?.let { "$IMAGE_BASE/w1280$it" },
            description = meta.description?.takeIf { it.isNotBlank() } ?: detail.str("overview")?.takeIf { it.isNotBlank() },
            releaseInfo = meta.releaseInfo ?: date?.take(4),
            imdbRating = meta.imdbRating ?: detail.dbl("vote_average")?.takeIf { it > 0 }?.let { "%.1f".format(java.util.Locale.US, it) },
            releasedMillis = meta.releasedMillis ?: dateMillis(date),
            runtime = meta.runtime ?: (detail.int("runtime") ?: detail.arr("episode_run_time").firstOrNull()?.int())?.let { "$it min" },
            genres = meta.genres.ifEmpty { genres },
            cast = meta.cast.ifEmpty { cast },
            directors = meta.directors.ifEmpty { directors },
            trailers = meta.trailers.ifEmpty { trailers },
            externalIds = meta.externalIds.filling(ExternalIds(imdb = external?.str("imdb_id")?.takeIf { it.isNotBlank() }, tmdb = id, tvdb = external?.int("tvdb_id"))),
        )
    }

    private suspend fun loadRich(meta: MetaItem): RichDetails? {
        val (kind, id) = resolveTmdb(meta) ?: return null
        richCache["$kind:$id"]?.let { return it }
        val detail = tmdbDetails(kind, id)
        val series = kind == "tv"
        val credits = detail.obj("credits")
        val rich = RichDetails(
            tmdbId = id, isMovie = !series,
            cast = credits?.arr("cast").orEmpty().take(16).mapNotNull { p ->
                RichDetails.Person(p.str("name") ?: return@mapNotNull null, p.str("character")?.takeIf { it.isNotBlank() }, p.str("profile_path")?.let { "$IMAGE_BASE/w185$it" })
            },
            directors = if (series) emptyList() else credits?.arr("crew").orEmpty().filter { it.str("job") == "Director" }.mapNotNull { it.str("name") }.distinct(),
            creators = detail.arr("created_by").mapNotNull { it.str("name") },
            companies = detail.arr("production_companies").mapNotNull { it.str("name") }.take(6),
            budget = if (series) null else detail.lng("budget")?.takeIf { it > 0 },
            revenue = if (series) null else detail.lng("revenue")?.takeIf { it > 0 },
            trailers = trailersOf(detail),
            similar = detail.obj("similar")?.arr("results").orEmpty().take(16).mapNotNull { s ->
                val sid = s.int("id") ?: return@mapNotNull null
                RichDetails.Similar(sid, s.str("title") ?: s.str("name") ?: return@mapNotNull null, s.str("poster_path")?.let { "$IMAGE_BASE/w342$it" },
                    (s.str("release_date") ?: s.str("first_air_date"))?.take(4), !series)
            }.filter { it.poster != null },
            status = detail.str("status")?.takeIf { it.isNotBlank() },
            countries = detail.arr("production_countries").mapNotNull { it.str("name") },
            originalLanguage = detail.str("original_language"),
            seasonCount = detail.int("number_of_seasons"),
            episodeCount = detail.int("number_of_episodes"),
        )
        richCache["$kind:$id"] = rich
        return rich
    }

    private fun trailersOf(detail: JsonObject): List<TrailerRef> = detail.obj("videos")?.arr("results").orEmpty()
        .filter { it.str("site") == "YouTube" && it.str("type") in setOf("Trailer", "Teaser") }
        .sortedByDescending { it.str("type") == "Trailer" }
        .mapNotNull { v -> v.str("key")?.takeIf { k -> k.all { it.isLetterOrDigit() || it == '-' || it == '_' } }?.let { TrailerRef(it, v.str("type") ?: "Trailer") } }
        .take(4)

    private suspend fun tmdbGet(path: String, vararg query: Pair<String, String>): JsonObject {
        val key = tmdbKey()
        if (key.isEmpty()) throw ProviderError("Chiave TMDB non impostata.")
        val bearer = key.startsWith("eyJ") && key.count { it == '.' } == 2
        val params = buildList {
            add("language" to language())
            addAll(query)
            if (!bearer) add("api_key" to key)
        }
        val url = "https://api.themoviedb.org/3$path?" + params.joinToString("&") { "${it.first}=${enc(it.second)}" }
        val response = http.send(HttpRequest(url, headers = if (bearer) mapOf("Authorization" to "Bearer $key", "Accept" to "application/json") else mapOf("Accept" to "application/json"), timeoutSeconds = 12, maxBytes = 2 * 1024 * 1024))
        when {
            response.status == 401 || response.status == 403 -> throw ProviderError("TMDB non accetta la chiave (controlla di aver copiato la chiave API v3 o il token di lettura v4).")
            response.status == 404 -> return JsonObject(emptyMap())
            response.status == 429 -> throw ProviderError("TMDB: troppe richieste, riprova tra poco.")
            !response.isSuccess -> throw ProviderError("TMDB ha risposto con errore HTTP ${response.status}.")
        }
        return json.parseToJsonElement(response.text) as? JsonObject ?: throw ProviderError("Risposta TMDB non valida.")
    }

    // MARK: TheTVDB

    data class TvdbEpisode(val season: Int, val number: Int, val name: String?, val overview: String?, val image: String?)

    private suspend fun tvdbBearer(force: Boolean = false): String {
        val key = tvdbKey()
        if (key.isEmpty()) throw ProviderError("Chiave TheTVDB non impostata.")
        val pin = tvdbPin()
        val fingerprint = "$key|$pin"
        tvdbToken?.takeIf { !force && it.first == fingerprint }?.let { return it.second }
        val body = buildJsonObject { put("apikey", key); if (pin.isNotEmpty()) put("pin", pin) }.toString()
        val response = http.send(HttpRequest("https://api4.thetvdb.com/v4/login", method = "POST", body = body, contentType = "application/json", headers = mapOf("Accept" to "application/json"), timeoutSeconds = 12))
        when {
            response.status == 401 || response.status == 403 -> throw ProviderError("TheTVDB non accetta la chiave (o il PIN). Serve la chiave API v4; se è di un abbonato aggiungi anche il PIN.")
            !response.isSuccess -> throw ProviderError("TheTVDB ha risposto con errore HTTP ${response.status}.")
        }
        val token = (json.parseToJsonElement(response.text) as? JsonObject)?.obj("data")?.str("token") ?: throw ProviderError("Risposta TheTVDB non valida.")
        tvdbToken = fingerprint to token
        return token
    }

    private suspend fun tvdbGet(path: String): JsonObject? {
        repeat(2) { attempt ->
            val response = http.send(HttpRequest("https://api4.thetvdb.com/v4$path", headers = mapOf("Authorization" to "Bearer ${tvdbBearer(force = attempt > 0)}", "Accept" to "application/json"), timeoutSeconds = 12, maxBytes = 4 * 1024 * 1024))
            if (response.status == 401 && attempt == 0) return@repeat
            if (response.status == 404) return null
            if (!response.isSuccess) throw ProviderError("TheTVDB ha risposto con errore HTTP ${response.status}.")
            return json.parseToJsonElement(response.text) as? JsonObject
        }
        return null
    }

    private suspend fun tvdbId(meta: MetaItem): Int? {
        meta.externalIds.tvdb?.let { return it }
        val imdb = meta.externalIds.imdb ?: meta.imdbId ?: return null
        tvdbIdCache[imdb]?.let { return it }
        val rows = tvdbGet("/search/remoteid/$imdb")?.arr("data").orEmpty()
        val id = rows.firstNotNullOfOrNull { (it.obj("series") ?: it.obj("movie"))?.int("id") } ?: return null
        tvdbIdCache[imdb] = id
        return id
    }

    private suspend fun applyTvdb(meta: MetaItem): MetaItem {
        val needsBasics = meta.description.isNullOrBlank() || meta.poster.isNullOrBlank() || meta.background.isNullOrBlank()
        val series = isSeries(meta)
        val id = tvdbId(meta) ?: return meta
        var result = meta
        if (needsBasics) {
            val detail = tvdbGet("/${if (series) "series" else "movies"}/$id/extended?short=true")?.obj("data")
            if (detail != null) {
                val date = detail.str("firstAired") ?: detail.str("releaseDate") ?: detail.arr("releases").firstOrNull()?.str("date")
                result = result.copy(
                    poster = result.poster ?: detail.str("image"),
                    description = result.description?.takeIf { it.isNotBlank() } ?: detail.str("overview"),
                    releaseInfo = result.releaseInfo ?: date?.take(4),
                    genres = result.genres.ifEmpty { detail.arr("genres").mapNotNull { it.str("name") } },
                    externalIds = result.externalIds.filling(ExternalIds(tvdb = id)),
                )
            }
        }
        if (series && result.videos.any { it.isEpisode && (it.thumbnail == null || it.overview.isNullOrBlank()) }) {
            val episodes = episodeCache.getOrPut("$id") { loadTvdbEpisodes(id) }
            if (episodes.isNotEmpty()) {
                val index = episodes.associateBy { it.season to it.number }
                result = result.copy(videos = result.videos.map { v ->
                    val e = if (v.season != null && v.episode != null) index[v.season to v.episode] else null
                    if (e == null) v else v.copy(
                        thumbnail = v.thumbnail ?: e.image,
                        overview = v.overview?.takeIf { it.isNotBlank() } ?: e.overview,
                        title = v.title.ifBlank { e.name.orEmpty() },
                    )
                })
            }
        }
        return result
    }

    private suspend fun loadTvdbEpisodes(id: Int): List<TvdbEpisode> {
        val all = mutableListOf<TvdbEpisode>()
        for (page in 0 until 8) {
            val data = tvdbGet("/series/$id/episodes/default?page=$page") ?: break
            val rows = data.obj("data")?.arr("episodes").orEmpty()
            if (rows.isEmpty()) break
            rows.forEach { r ->
                val s = r.int("seasonNumber") ?: return@forEach
                val n = r.int("number") ?: return@forEach
                all += TvdbEpisode(s, n, r.str("name"), r.str("overview"), r.str("image"))
            }
            if (data.obj("links")?.str("next") == null) break
        }
        return all
    }

    // MARK: Helpers

    private fun dateMillis(value: String?): Long? = runCatching { LocalDate.parse(value).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8")

    private fun JsonElement.obj(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
    private fun JsonElement.arr(key: String): List<JsonElement> = ((this as? JsonObject)?.get(key) as? JsonArray)?.toList().orEmpty()
    private fun JsonElement.str(key: String): String? = ((this as? JsonObject)?.get(key) as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
    private fun JsonElement.int(key: String): Int? = str(key)?.toDoubleOrNull()?.toInt()
    private fun JsonElement.lng(key: String): Long? = str(key)?.toDoubleOrNull()?.toLong()
    private fun JsonElement.dbl(key: String): Double? = str(key)?.toDoubleOrNull()
    private fun JsonElement.int(): Int? = (this as? JsonPrimitive)?.content?.toDoubleOrNull()?.toInt()

    companion object {
        const val TMDbKey = "metadata.tmdb.apiKey"
        const val TVDbKey = "metadata.tvdb.apiKey"
        const val TVDbPin = "metadata.tvdb.pin"
        private const val IMAGE_BASE = "https://image.tmdb.org/t/p"
        private val SERIES = setOf("series", "tv", "show")
    }
}
