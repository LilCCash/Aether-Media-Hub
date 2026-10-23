package app.aether.core.metadata

import app.aether.core.model.ExternalIds
import app.aether.core.model.MetaItem
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.util.SecretStore
import java.net.URLEncoder
import java.time.LocalDate
import java.time.ZoneOffset
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Optional metadata enrichment. API keys are read from the encrypted SecretStore and never logged.
 * Addon metadata remains the source of truth for episode IDs/streams; these providers only fill descriptive fields.
 */
class MetadataEnrichment(private val http: HttpClient, private val secrets: SecretStore) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private var tvdbToken: String? = null

    suspend fun enrich(meta: MetaItem): MetaItem {
        if (meta.type !in setOf("movie", "series", "tv", "show")) return meta
        val tmdbKey = secrets.get(TMDbKey).orEmpty().trim()
        val tvdbKey = secrets.get(TVDbKey).orEmpty().trim()
        var result = meta
        if (tmdbKey.isNotEmpty()) result = runCatching { fromTmdb(result, tmdbKey) }.getOrDefault(result)
        if (tvdbKey.isNotEmpty() && (result.description.isNullOrBlank() || result.poster.isNullOrBlank())) {
            result = runCatching { fromTvdb(result, tvdbKey) }.getOrDefault(result)
        }
        return result
    }

    private suspend fun fromTmdb(meta: MetaItem, key: String): MetaItem {
        val isSeries = meta.type in setOf("series", "tv", "show")
        val kind = if (isSeries) "tv" else "movie"
        val year = meta.year?.let { if (isSeries) "&first_air_date_year=$it" else "&year=$it" }.orEmpty()
        val query = enc(meta.name)
        val search = getJson("https://api.themoviedb.org/3/search/$kind?api_key=${enc(key)}&query=$query$year")
        val results = search.array("results")
        val best = results.firstOrNull() ?: return meta
        val id = best.int("id") ?: return meta
        val detail = getJson("https://api.themoviedb.org/3/$kind/$id?api_key=${enc(key)}&append_to_response=credits,external_ids")
        val external = detail.obj("external_ids")
        val credits = detail.obj("credits")
        val genres = detail.array("genres").mapNotNull { it.string("name") }
        val cast = credits?.array("cast").orEmpty().take(10).mapNotNull { it.string("name") }
        val directors = credits?.array("crew").orEmpty().filter { it.string("job") == "Director" }.take(4).mapNotNull { it.string("name") }
        val date = detail.string(if (isSeries) "first_air_date" else "release_date")
        val released = dateMillis(date)
        return meta.copy(
            poster = meta.poster ?: detail.string("poster_path")?.let { "https://image.tmdb.org/t/p/w500$it" },
            background = meta.background ?: detail.string("backdrop_path")?.let { "https://image.tmdb.org/t/p/w1280$it" },
            description = meta.description?.takeIf { it.isNotBlank() } ?: detail.string("overview")?.takeIf { it.isNotBlank() },
            releaseInfo = meta.releaseInfo ?: date?.take(4),
            imdbRating = meta.imdbRating ?: detail.double("vote_average")?.takeIf { it > 0 }?.let { "%.1f".format(java.util.Locale.US, it) },
            releasedMillis = meta.releasedMillis ?: released,
            runtime = meta.runtime ?: (detail.int("runtime") ?: detail.array("episode_run_time").firstOrNull()?.intValue())?.let { "$it min" },
            genres = meta.genres.ifEmpty { genres },
            cast = meta.cast.ifEmpty { cast },
            directors = meta.directors.ifEmpty { directors },
            externalIds = meta.externalIds.filling(ExternalIds(
                imdb = external?.string("imdb_id"),
                tmdb = id,
                tvdb = external?.int("tvdb_id"),
            )),
        )
    }

    private suspend fun fromTvdb(meta: MetaItem, key: String): MetaItem {
        val token = tvdbToken ?: run {
            val login = http.send(HttpRequest(
                url = "https://api4.thetvdb.com/v4/login", method = "POST",
                body = """{"apikey":"${jsonEscape(key)}"}""", contentType = "application/json", timeoutSeconds = 8,
            ))
            if (!login.isSuccess) return meta
            json.parseToJsonElement(login.text).jsonObject.obj("data")?.string("token")?.also { tvdbToken = it } ?: return meta
        }
        val kind = if (meta.type in setOf("series", "tv", "show")) "series" else "movie"
        val search = http.send(HttpRequest(
            url = "https://api4.thetvdb.com/v4/search?query=${enc(meta.name)}&type=$kind",
            headers = mapOf("Authorization" to "Bearer $token"), timeoutSeconds = 8,
        ))
        if (!search.isSuccess) return meta
        val rows = json.parseToJsonElement(search.text).jsonObject.array("data")
        val best = rows.firstOrNull() ?: return meta
        val id = best.string("tvdb_id") ?: best.string("id") ?: return meta
        val detailResponse = http.send(HttpRequest(
            url = "https://api4.thetvdb.com/v4/${if (kind == "series") "series" else "movies"}/$id/extended",
            headers = mapOf("Authorization" to "Bearer $token"), timeoutSeconds = 8,
        ))
        if (!detailResponse.isSuccess) return meta
        val detail = json.parseToJsonElement(detailResponse.text).jsonObject.obj("data") ?: return meta
        val image = detail.string("image") ?: detail.string("image_url") ?: best.string("image_url")
        val genres = detail.array("genres").mapNotNull { it.string("name") }
        val cast = detail.array("characters").take(10).mapNotNull { it.string("name") }
        val date = detail.string("firstAired") ?: detail.string("releaseDate")
        return meta.copy(
            poster = meta.poster ?: image,
            description = meta.description?.takeIf { it.isNotBlank() } ?: detail.string("overview")?.takeIf { it.isNotBlank() } ?: best.string("overview"),
            releaseInfo = meta.releaseInfo ?: date?.take(4),
            releasedMillis = meta.releasedMillis ?: dateMillis(date),
            genres = meta.genres.ifEmpty { genres },
            cast = meta.cast.ifEmpty { cast },
            externalIds = meta.externalIds.filling(ExternalIds(tvdb = id.toIntOrNull())),
        )
    }

    private suspend fun getJson(url: String): JsonObject {
        val response = http.send(HttpRequest(url, timeoutSeconds = 8, maxBytes = 2 * 1024 * 1024))
        if (!response.isSuccess) error("Metadata provider HTTP ${response.status}")
        return json.parseToJsonElement(response.text).jsonObject
    }

    private fun dateMillis(value: String?): Long? = runCatching {
        LocalDate.parse(value).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli()
    }.getOrNull()

    private fun enc(value: String) = URLEncoder.encode(value, "UTF-8")
    private fun jsonEscape(value: String) = value.replace("\\", "\\\\").replace("\"", "\\\"")
    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.array(key: String): List<kotlinx.serialization.json.JsonElement> = (this[key] as? JsonArray)?.toList().orEmpty()
    private fun kotlinx.serialization.json.JsonElement.obj(key: String): JsonObject? = (this as? JsonObject)?.get(key) as? JsonObject
    private fun JsonObject.string(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull()
    private fun JsonObject.int(key: String): Int? = string(key)?.toIntOrNull()
    private fun JsonObject.double(key: String): Double? = string(key)?.toDoubleOrNull()
    private fun kotlinx.serialization.json.JsonElement.string(key: String): String? = (this as? JsonObject)?.string(key)
    private fun kotlinx.serialization.json.JsonElement.int(key: String): Int? = (this as? JsonObject)?.int(key)
    private fun kotlinx.serialization.json.JsonElement.intValue(): Int? = runCatching { jsonPrimitive.content.toInt() }.getOrNull()
    private fun kotlinx.serialization.json.JsonElement.arr(): List<kotlinx.serialization.json.JsonElement> = (this as? JsonArray)?.toList().orEmpty()
    private fun kotlinx.serialization.json.JsonPrimitive.contentOrNull(): String? = content.takeIf { it != "null" }
    companion object {
        const val TMDbKey = "metadata.tmdb.apiKey"
        const val TVDbKey = "metadata.tvdb.apiKey"
    }
}
