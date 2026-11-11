package app.aether.core.playback

import app.aether.core.model.MetaItem
import app.aether.core.model.Video

/**
 * Episode navigation, following `MetaItem::next_video` in stremio-core: no crossing into season 0 (specials) from a regular season,
 * unreleased episodes are skipped, live items never advance.
 */
object NextEpisodeResolver {
    fun next(afterVideoId: String, meta: MetaItem, now: Long = System.currentTimeMillis()): Video? {
        if (meta.isLive) return null
        val index = meta.videos.indexOfFirst { it.id == afterVideoId }
        if (index < 0 || index + 1 >= meta.videos.size) return null
        val currentSeason = meta.videos[index].season ?: 0
        val candidate = meta.videos[index + 1]
        val candidateSeason = candidate.season ?: 0
        val released = (candidate.releasedMillis ?: 0L) <= now
        return if ((candidateSeason != 0 || currentSeason == candidateSeason) && released) candidate else null
    }

    fun previous(beforeVideoId: String, meta: MetaItem): Video? {
        if (meta.isLive) return null
        val index = meta.videos.indexOfFirst { it.id == beforeVideoId }
        return if (index > 0) meta.videos[index - 1] else null
    }

    /** First released, not-yet-watched episode strictly after [afterVideoId], never entering season 0 from a regular season. */
    fun nextUnwatched(afterVideoId: String, meta: MetaItem, watched: Set<String>, now: Long = System.currentTimeMillis()): Video? {
        var cursor = afterVideoId
        var guard = 0
        while (guard < 2000) {
            val candidate = next(cursor, meta, now) ?: return null
            if (candidate.id !in watched) return candidate
            cursor = candidate.id
            guard++
        }
        return null
    }

    /**
     * The episode to play when the user presses "Guarda" on a series: the one in progress, else the first unwatched after the last
     * watched, else the first regular-season episode.
     */
    fun episodeToPlay(meta: MetaItem, watched: Set<String>, lastWatchedId: String?, inProgressId: String?, now: Long = System.currentTimeMillis()): Video? {
        inProgressId?.let { id -> meta.videos.firstOrNull { it.id == id }?.let { return it } }
        lastWatchedId?.let { id -> nextUnwatched(id, meta, watched, now)?.let { return it } }
        val regular = meta.videos.filter { (it.season ?: 1) != 0 && (it.releasedMillis ?: 0L) <= now }
        return regular.firstOrNull { it.id !in watched } ?: regular.firstOrNull() ?: meta.videos.firstOrNull()
    }
}
