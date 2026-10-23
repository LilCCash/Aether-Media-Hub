package app.aether.core.model

import app.aether.core.json.flexBool
import app.aether.core.json.flexInt
import app.aether.core.json.flexString
import app.aether.core.json.lossyList
import app.aether.core.json.obj
import app.aether.core.json.stringList
import app.aether.core.util.AddonDate
import app.aether.core.util.year
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

@Serializable
enum class PosterShape(val aspectRatio: Double) {
    POSTER(0.675), SQUARE(1.0), LANDSCAPE(1.77);

    companion object {
        fun parse(text: String?): PosterShape = when (text?.lowercase()) {
            "square" -> SQUARE
            "landscape" -> LANDSCAPE
            else -> POSTER
        }
    }
}

@Serializable
data class MetaLink(val name: String, val category: String, val url: String)

/** Trailer reference. Legacy shape `{source: "<youtubeId>"}`; the modern shape is stream-like (`ytId`). */
@Serializable
data class TrailerRef(val youtubeId: String, val type: String = "Trailer") {
    val watchUrl: String get() = "https://www.youtube.com/watch?v=$youtubeId"
}

/** An episode / upload / programme of a meta item. */
@Serializable
data class Video(
    val id: String,
    val title: String = "",
    val releasedMillis: Long? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val thumbnail: String? = null,
    val overview: String? = null,
    val available: Boolean? = null,
    /** Streams embedded in the meta response; when present Stremio does not ask other addons. */
    val streams: List<AddonStream> = emptyList(),
) {
    val isEpisode: Boolean get() = season != null && episode != null

    /** "S01E03" style label, null for non-episodes. */
    val episodeLabel: String?
        get() {
            val s = season ?: return null
            val e = episode ?: return null
            return "S%02dE%02d".format(s, e)
        }

    val isFuture: Boolean get() = (releasedMillis ?: 0L) > System.currentTimeMillis()
}

@Serializable
data class MetaBehaviorHints(
    val defaultVideoId: String? = null,
    val isLive: Boolean = false,
    val hasScheduledVideos: Boolean = false,
)

/** Ids of the same title in IMDb / TMDB / TheTVDB, when the addon or the id itself tells them. */
@Serializable
data class ExternalIds(val imdb: String? = null, val tmdb: Int? = null, val tvdb: Int? = null) {
    fun filling(other: ExternalIds) = ExternalIds(imdb ?: other.imdb, tmdb ?: other.tmdb, tvdb ?: other.tvdb)

    companion object {
        fun fromMetaId(id: String): ExternalIds = if (MetaItem.isImdbId(id)) ExternalIds(imdb = id) else ExternalIds()
    }
}

/** Used both for catalog entries (a preview with no `videos`) and for the full detail response. */
@Serializable
data class MetaItem(
    val id: String,
    val type: String,
    val name: String,
    val poster: String? = null,
    val posterShape: PosterShape = PosterShape.POSTER,
    val background: String? = null,
    val logo: String? = null,
    val description: String? = null,
    val releaseInfo: String? = null,
    val imdbRating: String? = null,
    val releasedMillis: Long? = null,
    val runtime: String? = null,
    val genres: List<String> = emptyList(),
    val cast: List<String> = emptyList(),
    val directors: List<String> = emptyList(),
    val writers: List<String> = emptyList(),
    val language: String? = null,
    val country: String? = null,
    val awards: String? = null,
    val website: String? = null,
    val trailers: List<TrailerRef> = emptyList(),
    val links: List<MetaLink> = emptyList(),
    val videos: List<Video> = emptyList(),
    val behaviorHints: MetaBehaviorHints = MetaBehaviorHints(),
    val externalIds: ExternalIds = ExternalIds(),
) {
    val isLive: Boolean get() = behaviorHints.isLive || ContentType.isLive(type)
    val imdbId: String? get() = if (isImdbId(id)) id else null

    /** First 4-digit year of `releaseInfo` ("2010", "2000-2014"), else the release date's. */
    val year: Int?
        get() {
            releaseInfo?.let { firstYear(it) }?.let { return it }
            return releasedMillis?.let { java.time.Instant.ofEpochMilli(it).year() }
        }

    val ratingValue: Double? get() = imdbRating?.replace(',', '.')?.toDoubleOrNull()

    /** Seasons that have at least one video, ascending. Season 0 (specials) comes first. */
    val seasons: List<Int> get() = videos.mapNotNull { it.season }.distinct().sorted()

    fun videos(inSeason: Int): List<Video> = videos.filter { it.season == inSeason }
    val hasEpisodes: Boolean get() = videos.any { it.isEpisode }

    /** Fills empty fields of this item from [other] (metadata from several addons merges this way). */
    fun merging(other: MetaItem): MetaItem = copy(
        poster = poster ?: other.poster,
        background = background ?: other.background,
        logo = logo ?: other.logo,
        description = description?.takeIf { it.isNotEmpty() } ?: other.description,
        releaseInfo = releaseInfo ?: other.releaseInfo,
        imdbRating = imdbRating ?: other.imdbRating,
        releasedMillis = releasedMillis ?: other.releasedMillis,
        runtime = runtime ?: other.runtime,
        genres = genres.ifEmpty { other.genres },
        cast = cast.ifEmpty { other.cast },
        directors = directors.ifEmpty { other.directors },
        writers = writers.ifEmpty { other.writers },
        language = language ?: other.language,
        country = country ?: other.country,
        awards = awards ?: other.awards,
        website = website ?: other.website,
        trailers = trailers.ifEmpty { other.trailers },
        links = links.ifEmpty { other.links },
        videos = videos.ifEmpty { other.videos },
        externalIds = externalIds.filling(other.externalIds),
    )

    companion object {
        fun isImdbId(id: String): Boolean = id.length >= 3 && id.startsWith("tt") && id.drop(2).all { it in '0'..'9' }

        fun firstYear(text: String): Int? {
            val digits = StringBuilder()
            for (c in text) {
                if (c in '0'..'9') {
                    digits.append(c)
                    if (digits.length == 4) return digits.toString().toInt()
                } else {
                    digits.clear()
                }
            }
            return null
        }

        /** Sort episodes by (season, episode); videos without series info keep their relative order after them. */
        fun sortedVideos(videos: List<Video>): List<Video> {
            if (videos.none { it.isEpisode }) return videos
            return videos.withIndex().sortedWith(
                compareBy<IndexedValue<Video>>({ it.value.season ?: Int.MAX_VALUE }, { it.value.episode ?: Int.MAX_VALUE }, { it.index }),
            ).map { it.value }
        }
    }
}

object MetaParser {
    fun parse(item: JsonObject): MetaItem? {
        val id = item.flexString("id")?.takeIf { it.isNotEmpty() } ?: return null
        val name = item.flexString("name") ?: item.flexString("title") ?: return null
        val declaredImdb = item.flexString("imdb_id")?.takeIf { MetaItem.isImdbId(it) }
        val declared = ExternalIds(declaredImdb, item.flexInt("moviedb_id") ?: item.flexInt("tmdb_id"), item.flexInt("tvdb_id"))
        val directors = item.stringList("directors").ifEmpty { item.stringList("director") }
        val writers = item.stringList("writers").ifEmpty { item.stringList("writer") }
        return MetaItem(
            id = id,
            type = item.flexString("type") ?: ContentType.OTHER,
            name = name,
            poster = item.flexString("poster"),
            posterShape = PosterShape.parse(item.flexString("posterShape")),
            background = item.flexString("background"),
            logo = item.flexString("logo"),
            description = item.flexString("description"),
            releaseInfo = item.flexString("releaseInfo") ?: item.flexString("year"),
            imdbRating = item.flexString("imdbRating"),
            releasedMillis = AddonDate.parse(item.flexString("released"))?.toEpochMilli(),
            runtime = item.flexString("runtime"),
            genres = item.stringList("genres").ifEmpty { item.stringList("genre") },
            cast = item.stringList("cast"),
            directors = directors,
            writers = writers,
            language = item.flexString("language"),
            country = item.flexString("country"),
            awards = item.flexString("awards"),
            website = item.flexString("website"),
            trailers = item.lossyList("trailers") { t ->
                val yt = t.flexString("source") ?: t.flexString("ytId") ?: return@lossyList null
                TrailerRef(yt, t.flexString("type") ?: t.flexString("title") ?: "Trailer")
            },
            links = item.lossyList("links") { l ->
                MetaLink(l.flexString("name") ?: return@lossyList null, l.flexString("category") ?: return@lossyList null, l.flexString("url") ?: return@lossyList null)
            },
            videos = MetaItem.sortedVideos(item.lossyList("videos") { parseVideo(it) }),
            behaviorHints = item.obj("behaviorHints")?.let {
                MetaBehaviorHints(it.flexString("defaultVideoId"), it.flexBool("isLive") ?: false, it.flexBool("hasScheduledVideos") ?: false)
            } ?: MetaBehaviorHints(),
            externalIds = ExternalIds.fromMetaId(id).filling(declared),
        )
    }

    fun parseVideo(item: JsonObject): Video? {
        val id = item.flexString("id")?.takeIf { it.isNotEmpty() } ?: return null
        var streams = item.lossyList("streams") { StreamParser.parse(it) }
        if (streams.isEmpty()) {
            val single = item.obj("stream")?.let { StreamParser.parse(it) }
            streams = if (single != null) listOf(single) else item.lossyList("stream") { StreamParser.parse(it) }
        }
        return Video(
            id = id,
            title = item.flexString("title") ?: item.flexString("name") ?: "",
            releasedMillis = AddonDate.parse(item.flexString("released"))?.toEpochMilli(),
            season = item.flexInt("season"),
            episode = item.flexInt("episode"),
            thumbnail = item.flexString("thumbnail"),
            overview = item.flexString("overview") ?: item.flexString("description"),
            available = item.flexBool("available"),
            streams = streams,
        )
    }
}
