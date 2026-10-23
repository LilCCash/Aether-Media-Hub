package app.aether.tv

import app.aether.core.model.AddonStream
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.playback.RankedStream

/** What the source picker is asked to find streams for. */
data class StreamRequest(val meta: MetaItem, val video: Video?, val resumeAt: Double?, val autoSelect: Boolean = false)

/** Everything the player needs to start: the title, what to play and what to fall back on. */
data class PlaybackRequest(
    val meta: MetaItem,
    val video: Video?,
    val stream: AddonStream,
    /** The address handed to the player: the direct link, or the one TorBox resolved (a secret: never logged). */
    val url: String,
    val headers: Map<String, String>,
    val alternatives: List<RankedStream>,
    val startPositionSeconds: Double?,
)

/**
 * Hand-over between screens for objects that do not fit in a navigation route (a title preview, the stream chosen). It lives as long as
 * the process; the routes themselves carry only the ids, so the back stack stays small and restorable.
 */
object Session {
    private val previews = object : LinkedHashMap<String, MetaItem>(32, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, MetaItem>?) = size > 64
    }

    @Synchronized fun putPreview(meta: MetaItem) { previews["${meta.type}/${meta.id}"] = meta }
    @Synchronized fun preview(type: String, id: String): MetaItem? = previews["$type/$id"]

    @Volatile var streamRequest: StreamRequest? = null
    @Volatile var playback: PlaybackRequest? = null

    /** An addon address received through a `stremio://` or `aether://` link, waiting for the addons screen to ask the viewer. */
    @Volatile var pendingAddonInput: String? = null
}
