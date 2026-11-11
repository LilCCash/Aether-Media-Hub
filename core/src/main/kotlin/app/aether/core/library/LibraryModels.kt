package app.aether.core.library

import app.aether.core.model.ContentType
import app.aether.core.model.MetaItem
import app.aether.core.model.PosterShape
import kotlinx.serialization.Serializable

/** A title in the user's watchlist and/or favourites. Removals stay as tombstones so a merge never resurrects them. */
@Serializable
data class LibraryEntry(
    val id: String,
    val type: String,
    val name: String,
    val poster: String? = null,
    val posterShape: PosterShape = PosterShape.POSTER,
    val background: String? = null,
    val logo: String? = null,
    val releaseInfo: String? = null,
    val imdbRating: String? = null,
    val inWatchlist: Boolean = false,
    val isFavorite: Boolean = false,
    val addedAt: Long = System.currentTimeMillis(),
    val modifiedAt: Long = System.currentTimeMillis(),
    val isRemoved: Boolean = false,
) {
    val asMeta: MetaItem
        get() = MetaItem(id, type, name, poster, posterShape, background, logo, releaseInfo = releaseInfo, imdbRating = imdbRating)
}

/** Where the viewer stopped in one video (a film or an episode). */
@Serializable
data class PlaybackProgress(
    val metaId: String,
    val videoId: String,
    val type: String,
    val title: String,
    val episodeTitle: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val poster: String? = null,
    val posterShape: PosterShape = PosterShape.POSTER,
    val background: String? = null,
    val position: Double = 0.0,
    val duration: Double = 0.0,
    val updatedAt: Long = System.currentTimeMillis(),
    val isCompleted: Boolean = false,
    val isDismissed: Boolean = false,
) {
    val id: String get() = key(metaId, videoId)

    val fraction: Double get() = if (duration > 0) (position / duration).coerceIn(0.0, 1.0) else 0.0
    val remaining: Double? get() = if (duration > 0) maxOf(0.0, duration - position) else null

    val episodeLabel: String?
        get() {
            val s = season ?: return null
            val e = episode ?: return null
            return "S%02dE%02d".format(s, e)
        }

    val asMeta: MetaItem get() = MetaItem(metaId, type, title, poster, posterShape, background)

    companion object {
        fun key(metaId: String, videoId: String) = "$metaId|$videoId"
    }
}

@Serializable
data class SearchHistoryItem(val query: String, val date: Long = System.currentTimeMillis()) {
    val id: String get() = query.lowercase()
}

@Serializable
data class LibraryState(
    val schemaVersion: Int = 1,
    val entries: Map<String, LibraryEntry> = emptyMap(),
    val progress: Map<String, PlaybackProgress> = emptyMap(),
    val searchHistory: List<SearchHistoryItem> = emptyList(),
)

data class LibraryPolicy(
    val watchedThreshold: Double = 0.9,
    val minimumRecordedSeconds: Double = 10.0,
    /** Whether playback creates history and progress at all (the privacy switch). */
    val recordHistory: Boolean = true,
    val maxProgressRecords: Int = 2000,
    val maxSearchHistory: Int = 30,
)

/**
 * Deterministic merge of two library states (this device + a backup or another device): per record the most recently modified side
 * wins, removals are tombstones that win like any newer write, progress merges per video, search history is the union.
 */
object LibraryMerge {
    const val TOMBSTONE_RETENTION_MS = 365L * 86_400_000L

    fun merge(local: LibraryState, remote: LibraryState, now: Long, maxSearchHistory: Int = 30): LibraryState {
        val entries = HashMap<String, LibraryEntry>()
        for (id in local.entries.keys + remote.entries.keys) {
            val l = local.entries[id]
            val r = remote.entries[id]
            val chosen = when {
                l != null && r != null -> if (r.modifiedAt > l.modifiedAt) r else l
                else -> l ?: r
            } ?: continue
            if (chosen.isRemoved && now - chosen.modifiedAt > TOMBSTONE_RETENTION_MS) continue
            entries[id] = chosen
        }
        val progress = HashMap<String, PlaybackProgress>()
        for (id in local.progress.keys + remote.progress.keys) {
            val l = local.progress[id]
            val r = remote.progress[id]
            if (l != null && r != null) {
                val newer = r.updatedAt > l.updatedAt
                var winner = if (newer) r else l
                val loser = if (newer) l else r
                if (loser.isCompleted && !winner.isCompleted && winner.updatedAt == loser.updatedAt) winner = winner.copy(isCompleted = true)
                if (winner.duration == 0.0 && loser.duration > 0) winner = winner.copy(duration = loser.duration)
                progress[id] = winner
            } else {
                (l ?: r)?.let { progress[id] = it }
            }
        }
        val latest = HashMap<String, SearchHistoryItem>()
        for (item in local.searchHistory + remote.searchHistory) {
            val existing = latest[item.id]
            if (existing != null && existing.date >= item.date) continue
            latest[item.id] = item
        }
        return LibraryState(
            entries = entries,
            progress = progress,
            searchHistory = latest.values.sortedByDescending { it.date }.take(maxSearchHistory),
        )
    }
}

internal fun isLiveType(type: String) = ContentType.isLive(type)
