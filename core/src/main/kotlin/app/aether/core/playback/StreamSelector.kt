package app.aether.core.playback

import app.aether.core.model.AddonStream

enum class VideoQualityCap(val title: String, val maxHeight: Int) {
    AUTO("Massima disponibile", Int.MAX_VALUE), P2160("Fino a 4K", 2160), P1080("Fino a 1080p", 1080), P720("Fino a 720p", 720)
}

/** How the list of sources is ordered. */
enum class StreamOrdering {
    /** The addon list decides: every source of the first addon comes before every source of the second. */
    BY_ADDON,
    /** One ranking for all sources, whatever addon they come from; the addon order only breaks ties. */
    BEST,
}

data class StreamPreferences(
    val qualityCap: VideoQualityCap = VideoQualityCap.AUTO,
    val preferredLanguage: String? = null,
    val preferLanguage: Boolean = true,
    /** Addon ids in user order. */
    val addonOrder: List<String> = emptyList(),
    val ordering: StreamOrdering = StreamOrdering.BEST,
    val capabilities: PlaybackCapabilities = PlaybackCapabilities(),
)

/** A stream with its analysis, ready to be ranked / displayed. */
data class RankedStream(val stream: AddonStream, val info: StreamInfo, val score: Long) {
    val id: String get() = stream.id
}

object StreamSelector {
    /**
     * Orders streams. `BEST`: playable first, then language, quality (within the cap), codec friendliness, addon order.
     * `BY_ADDON`: the addon's place in the user's list first, then the same ranking inside each addon. Unplayable streams are kept at
     * the bottom so the user can see *why* they cannot be played.
     */
    fun rank(streams: List<AddonStream>, preferences: StreamPreferences): List<RankedStream> {
        class Row(val item: RankedStream, val addonPlace: Int)
        val rows = streams.mapIndexed { position, stream ->
            val info = StreamAnalyzer.analyze(stream, preferences.capabilities)
            var score = when (info.support) {
                PlaybackSupport.Supported -> 10_000L
                PlaybackSupport.Unknown -> 5_000L
                is PlaybackSupport.Unsupported -> 0L
            }
            if (info.support.isPlayable) {
                val height = info.quality.height
                if (height > 0) {
                    score += if (height <= preferences.qualityCap.maxHeight) height / 10 + 100 else -(2_000 - minOf(1_900, height / 2))
                }
                val language = preferences.preferredLanguage
                if (language != null && preferences.preferLanguage) {
                    if (language in info.languages) score += 800 else if ("multi" in info.languages) score += 500
                }
                when (info.codec) {
                    VideoCodec.H264 -> score += 30
                    VideoCodec.HEVC -> score += 20
                    VideoCodec.AV1 -> score -= 40
                    VideoCodec.XVID, VideoCodec.MPEG2 -> score -= 60
                    else -> {}
                }
                if (info.kind == StreamKind.HLS) score += 15
                if (info.warnings.isNotEmpty()) score -= 25
                if (info.needsHeaders) score -= 10
            }
            val order = stream.addonId?.let { preferences.addonOrder.indexOf(it) } ?: -1
            if (order >= 0) score += maxOf(0, 8 - order)
            score = score * 1000 - position
            val place = if (order >= 0) order else Int.MAX_VALUE
            Row(RankedStream(stream, info, score), place)
        }
        return when (preferences.ordering) {
            StreamOrdering.BEST -> rows.map { it.item }.sortedByDescending { it.score }
            StreamOrdering.BY_ADDON -> rows.sortedWith(
                compareByDescending<Row> { it.item.info.support.isPlayable }.thenBy { it.addonPlace }.thenByDescending { it.item.score },
            ).map { it.item }
        }
    }

    /**
     * Picks what to play automatically: a stream sharing the previous episode's `bingeGroup` (continuity of release, quality and addon),
     * else the best-ranked playable one. With `BY_ADDON` the choice stays inside the first addon that has something playable.
     */
    fun autoSelect(ranked: List<RankedStream>, previousBingeGroup: String? = null, ordering: StreamOrdering = StreamOrdering.BEST): RankedStream? {
        var playable = ranked.filter { it.info.support.isPlayable }
        if (ordering == StreamOrdering.BY_ADDON) playable.firstOrNull()?.let { first -> playable = playable.filter { it.stream.addonId == first.stream.addonId } }
        if (!previousBingeGroup.isNullOrEmpty()) playable.firstOrNull { it.stream.behaviorHints.bingeGroup == previousBingeGroup }?.let { return it }
        return playable.firstOrNull()
    }
}
