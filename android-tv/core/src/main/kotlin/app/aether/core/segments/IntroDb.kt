package app.aether.core.segments

import app.aether.core.json.Flex
import app.aether.core.json.flexDouble
import app.aether.core.json.obj
import app.aether.core.net.AddonError
import app.aether.core.net.HttpClient
import app.aether.core.net.HttpLimits
import app.aether.core.net.HttpRequest
import kotlinx.serialization.json.JsonObject

/** A stretch of an episode the viewer can jump over: the opening titles or the recap of the previous episode. */
data class SkipSegment(val kind: Kind, val start: Double, val end: Double) {
    enum class Kind { INTRO, RECAP }
    val duration: Double get() = end - start
}

data class EpisodeSkipSegments(val intro: SkipSegment? = null, val recap: SkipSegment? = null) {
    val isEmpty: Boolean get() = intro == null && recap == null

    /**
     * The segment the playhead is in, or null. A segment that ends well after the end of the file is the timing of another cut and is
     * ignored. The button is offered [LEAD] seconds before a segment starts and until [TAIL] seconds before it ends.
     */
    fun active(position: Double, duration: Double? = null): SkipSegment? {
        if (!position.isFinite() || position < 0) return null
        for (segment in listOfNotNull(recap, intro)) {
            if (duration != null && duration > 0 && segment.end > duration + 5) continue
            if (position >= segment.start - LEAD && position < segment.end - TAIL) return segment
        }
        return null
    }

    companion object {
        const val LEAD = 1.0
        const val TAIL = 1.0
        val NONE = EpisodeSkipSegments()
    }
}

/** Client of the public IntroDB read API (https://api.introdb.app, no key): `GET /segments?imdb_id=tt…&season=N&episode=M`. */
class IntroDbClient(private val http: HttpClient, private val baseUrl: String = "https://api.introdb.app") {
    /** Null when nothing is known for the episode; the data is contributed by volunteers and can be a few seconds off for another cut. */
    suspend fun segments(imdbId: String, season: Int, episode: Int): EpisodeSkipSegments? {
        if (!imdbId.matches(Regex("tt\\d{5,10}")) || season < 0 || episode < 0) return null
        val url = "$baseUrl/segments?imdb_id=$imdbId&season=$season&episode=$episode"
        val response = try {
            http.send(HttpRequest(url, timeoutSeconds = 6, maxBytes = HttpLimits.SMALL))
        } catch (_: AddonError) {
            return null
        }
        if (!response.isSuccess) return null
        val root = Flex.parse(response.text) as? JsonObject ?: return null
        val intro = segment(root.obj("intro"), SkipSegment.Kind.INTRO)
        val recap = segment(root.obj("recap"), SkipSegment.Kind.RECAP)
        return EpisodeSkipSegments(intro, recap).takeIf { !it.isEmpty }
    }

    private fun segment(item: JsonObject?, kind: SkipSegment.Kind): SkipSegment? {
        item ?: return null
        val start = item.flexDouble("start_sec") ?: item.flexDouble("start_ms")?.let { it / 1000.0 } ?: return null
        val end = item.flexDouble("end_sec") ?: item.flexDouble("end_ms")?.let { it / 1000.0 } ?: return null
        if (!start.isFinite() || !end.isFinite() || start < 0 || end <= start || end - start > 600) return null
        return SkipSegment(kind, start, end)
    }
}
