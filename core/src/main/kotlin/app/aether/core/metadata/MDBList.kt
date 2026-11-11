package app.aether.core.metadata

import app.aether.core.addons.ResourceUrlBuilder
import app.aether.core.json.Flex
import app.aether.core.json.flexDouble
import app.aether.core.json.flexInt
import app.aether.core.json.flexString
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpRequest
import app.aether.core.util.SecretStore
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** One rating of a title, as MDBList reports it (source already in our spelling). */
data class MdbRating(val source: String, val value: Double?, val score: Double?, val votes: Int?) {
    val title: String get() = TITLES[source] ?: source.replaceFirstChar { it.uppercase() }

    /** "7.7", "92%" or "81", written the way each service writes its own scale. */
    val display: String?
        get() = when (source) {
            "tomatoes", "tomatoesaudience", "trakt" -> (score ?: value)?.let { "${Math.round(it)}%" }
            "metacritic" -> (value ?: score)?.let { "${Math.round(it)}" }
            else -> value?.let { if (it <= 10) "%.1f".format(java.util.Locale.ROOT, it) else "${Math.round(it)}" } ?: score?.let { "${Math.round(it)}" }
        }

    companion object {
        val TITLES = mapOf(
            "imdb" to "IMDb", "tmdb" to "TMDB", "tomatoes" to "Rotten Tomatoes", "tomatoesaudience" to "Pubblico RT",
            "metacritic" to "Metacritic", "metacriticuser" to "Metacritic utenti", "trakt" to "Trakt", "letterboxd" to "Letterboxd",
            "rogerebert" to "Roger Ebert", "myanimelist" to "MyAnimeList",
        )

        fun canonical(raw: String): String = when (raw.lowercase()) {
            "rottentomatoes", "rotten_tomatoes", "tomatoes" -> "tomatoes"
            "popcorn", "audience", "tomatoesaudience", "tomatoes_audience" -> "tomatoesaudience"
            "metacriticuser", "metacritic_user" -> "metacriticuser"
            "myanimelist", "mal" -> "myanimelist"
            else -> raw.lowercase()
        }
    }
}

/** MDBList (api.mdblist.com) with the viewer's own key: the ratings of a title from several services at once. Never logs the key. */
class MdbListClient(private val http: HttpClient, private val secrets: SecretStore, private val baseUrl: String = "https://api.mdblist.com") {
    private val cache = ConcurrentHashMap<String, List<MdbRating>>()

    val isConfigured: Boolean get() = !secrets.get(KEY_SECRET).isNullOrBlank()

    /** Empty without a key or on any failure. */
    suspend fun ratings(tmdbId: Int, isMovie: Boolean): List<MdbRating> {
        val path = "/tmdb/${if (isMovie) "movie" else "show"}/$tmdbId"
        cache[path]?.let { return it }
        val text = try { get(path) } catch (e: CancellationException) { throw e } catch (_: Throwable) { null } ?: return emptyList()
        return parse(text).also { cache[path] = it }
    }

    /** Settings: is the key accepted? Returns null when it is, else an Italian message. */
    suspend fun check(): String? = try {
        if (get("/user") == null) "MDBList ha rifiutato la chiave." else null
    } catch (e: CancellationException) { throw e } catch (_: Throwable) { "MDBList non risponde." }

    private suspend fun get(path: String): String? {
        val key = secrets.get(KEY_SECRET)?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val response = http.send(HttpRequest("$baseUrl$path?apikey=${ResourceUrlBuilder.encode(key)}", headers = mapOf("Accept" to "application/json"), timeoutSeconds = 10, maxBytes = 1024 * 1024))
        return if (response.isSuccess) response.text else null
    }

    companion object {
        const val KEY_SECRET = "metadata.mdblist.apiKey"

        fun parse(text: String): List<MdbRating> {
            val list = ((Flex.parse(text) as? JsonObject)?.get("ratings") as? JsonArray) ?: return emptyList()
            val seen = HashSet<String>()
            return list.mapNotNull { element ->
                val entry = element as? JsonObject ?: return@mapNotNull null
                val raw = entry.flexString("source")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                val source = MdbRating.canonical(raw)
                if (!seen.add(source)) return@mapNotNull null
                MdbRating(source, entry.flexDouble("value"), entry.flexDouble("score"), entry.flexInt("votes")).takeIf { it.display != null }
            }
        }

    }
}
