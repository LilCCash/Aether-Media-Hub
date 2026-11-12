package app.aether.core.library

import app.aether.core.model.ContentType
import app.aether.core.model.MetaItem
import app.aether.core.model.Video
import app.aether.core.playback.NextEpisodeResolver
import app.aether.core.search.MetaDeduper
import app.aether.core.util.JsonFileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** Watchlist, favourites, watch progress, history and search history; everything stays on the device. */
class LibraryStore(
    private val file: JsonFileStore<LibraryState>,
    policy: LibraryPolicy = LibraryPolicy(),
    private val now: () -> Long = System::currentTimeMillis,
) {
    private var state = LibraryState()
    private var loaded = false
    @Volatile
    var policy: LibraryPolicy = policy

    private val _revision = MutableStateFlow(0L)

    /** Increases after every change: collectors reload what they show. */
    val revision: StateFlow<Long> get() = _revision

    @Synchronized
    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        state = file.load() ?: LibraryState()
    }

    private fun changed() {
        file.save(state)
        _revision.value = _revision.value + 1
    }

    // MARK: Watchlist and favourites

    @Synchronized fun entry(id: String): LibraryEntry? { ensureLoaded(); return state.entries[id]?.takeIf { !it.isRemoved } }
    fun isInWatchlist(id: String) = entry(id)?.inWatchlist ?: false
    fun isFavorite(id: String) = entry(id)?.isFavorite ?: false

    @Synchronized
    fun setWatchlist(enabled: Boolean, meta: MetaItem) = mutateEntry(meta) { it.copy(inWatchlist = enabled) }

    @Synchronized
    fun setFavorite(enabled: Boolean, meta: MetaItem) = mutateEntry(meta) { it.copy(isFavorite = enabled) }

    private fun mutateEntry(meta: MetaItem, change: (LibraryEntry) -> LibraryEntry) {
        ensureLoaded()
        val time = now()
        val existing = state.entries[meta.id]
        val base = existing?.takeIf { !it.isRemoved }?.copy(
            name = meta.name, poster = meta.poster ?: existing.poster, background = meta.background ?: existing.background,
            logo = meta.logo ?: existing.logo, releaseInfo = meta.releaseInfo ?: existing.releaseInfo,
            imdbRating = meta.imdbRating ?: existing.imdbRating,
        ) ?: LibraryEntry(meta.id, meta.type, meta.name, meta.poster, meta.posterShape, meta.background, meta.logo, meta.releaseInfo, meta.imdbRating, addedAt = time, modifiedAt = time)
        var updated = change(base).copy(modifiedAt = time, isRemoved = false)
        if (!updated.inWatchlist && !updated.isFavorite) updated = updated.copy(isRemoved = true)
        state = state.copy(entries = state.entries + (meta.id to updated))
        changed()
    }

    @Synchronized
    fun watchlist(): List<LibraryEntry> {
        ensureLoaded()
        return state.entries.values.filter { !it.isRemoved && it.inWatchlist }.sortedByDescending { it.modifiedAt }
    }

    @Synchronized
    fun favorites(): List<LibraryEntry> {
        ensureLoaded()
        return state.entries.values.filter { !it.isRemoved && it.isFavorite }.sortedByDescending { it.modifiedAt }
    }

    // MARK: Progress and history

    @Synchronized
    fun progress(metaId: String, videoId: String): PlaybackProgress? {
        ensureLoaded()
        return state.progress[PlaybackProgress.key(metaId, videoId)]
    }

    /** Seconds to resume from, or null when there is nothing meaningful to resume (completed, or too early). */
    fun resumePosition(metaId: String, videoId: String): Double? {
        val record = progress(metaId, videoId) ?: return null
        if (record.isCompleted || record.position < policy.minimumRecordedSeconds) return null
        return record.position
    }

    /** Called periodically by the player. Returns true when the video crossed the "watched" threshold. */
    @Synchronized
    fun recordProgress(meta: MetaItem, video: Video?, position: Double, duration: Double): Boolean {
        ensureLoaded()
        if (!policy.recordHistory || !position.isFinite() || !duration.isFinite()) return false
        val videoId = video?.id ?: meta.id
        val key = PlaybackProgress.key(meta.id, videoId)
        var record = state.progress[key] ?: PlaybackProgress(
            meta.id, videoId, meta.type, meta.name, video?.title, video?.season, video?.episode, meta.poster, meta.posterShape, meta.background,
        )
        if (record.position < policy.minimumRecordedSeconds && position < policy.minimumRecordedSeconds && !record.isCompleted) return false
        record = record.copy(
            title = meta.name, poster = meta.poster ?: record.poster, background = meta.background ?: record.background,
            episodeTitle = video?.title ?: record.episodeTitle, season = video?.season ?: record.season,
            episode = video?.episode ?: record.episode, position = maxOf(0.0, position),
            duration = if (duration > 0) duration else record.duration, updatedAt = now(), isDismissed = false,
        )
        var crossed = false
        if (record.duration > 0 && record.position / record.duration >= policy.watchedThreshold) {
            if (!record.isCompleted) crossed = true
            record = record.copy(isCompleted = true)
        } else if (record.isCompleted && record.duration > 0 && record.fraction < 0.5) {
            record = record.copy(isCompleted = false)
        }
        state = state.copy(progress = trim(state.progress + (key to record)))
        changed()
        return crossed
    }

    @Synchronized
    fun markWatched(watched: Boolean, meta: MetaItem, videos: List<Video?>) {
        ensureLoaded()
        var progress = state.progress
        for (video in videos) {
            val videoId = video?.id ?: meta.id
            val key = PlaybackProgress.key(meta.id, videoId)
            if (!watched) { progress = progress - key; continue }
            val base = progress[key] ?: PlaybackProgress(
                meta.id, videoId, meta.type, meta.name, video?.title, video?.season, video?.episode, meta.poster, meta.posterShape, meta.background,
            )
            progress = progress + (key to base.copy(isCompleted = true, position = if (base.duration > 0) base.duration else base.position, updatedAt = now(), isDismissed = true))
        }
        state = state.copy(progress = progress)
        changed()
    }

    @Synchronized
    fun watchedVideoIds(metaId: String): Set<String> {
        ensureLoaded()
        return state.progress.values.filter { it.metaId == metaId && it.isCompleted }.map { it.videoId }.toSet()
    }

    @Synchronized
    fun progressFor(metaId: String): Map<String, PlaybackProgress> {
        ensureLoaded()
        return state.progress.values.filter { it.metaId == metaId }.associateBy { it.videoId }
    }

    /** The latest unfinished video of each title, newest first. */
    @Synchronized
    fun continueWatching(limit: Int = 30): List<PlaybackProgress> {
        ensureLoaded()
        val latest = HashMap<String, PlaybackProgress>()
        for (record in state.progress.values) {
            val current = latest[record.metaId]
            if (current != null && current.updatedAt >= record.updatedAt) continue
            latest[record.metaId] = record
        }
        return latest.values
            .filter { !it.isCompleted && !it.isDismissed && it.position >= policy.minimumRecordedSeconds && !ContentType.isLive(it.type) }
            .sortedByDescending { it.updatedAt }.take(limit)
    }

    /** The latest *completed* episode of each series, newest first; the UI asks the metadata for the following episode. */
    @Synchronized
    fun nextUpSeeds(limit: Int = 20): List<PlaybackProgress> {
        ensureLoaded()
        val latest = HashMap<String, PlaybackProgress>()
        for (record in state.progress.values.filter { ContentType.hasEpisodes(it.type) }) {
            val current = latest[record.metaId]
            if (current != null && current.updatedAt >= record.updatedAt) continue
            latest[record.metaId] = record
        }
        return latest.values.filter { it.isCompleted && it.season != null && it.episode != null }.sortedByDescending { it.updatedAt }.take(limit)
    }

    @Synchronized
    fun history(limit: Int = 500): List<PlaybackProgress> {
        ensureLoaded()
        return state.progress.values.filter { it.isCompleted || it.position >= policy.minimumRecordedSeconds }
            .sortedByDescending { it.updatedAt }.take(limit)
    }

    @Synchronized
    fun dismissFromContinueWatching(metaId: String) {
        ensureLoaded()
        state = state.copy(progress = state.progress.mapValues { (_, record) -> if (record.metaId == metaId) record.copy(isDismissed = true) else record })
        changed()
    }

    @Synchronized
    fun removeHistory(id: String) { ensureLoaded(); state = state.copy(progress = state.progress - id); changed() }

    @Synchronized
    fun clearHistory() { ensureLoaded(); state = state.copy(progress = emptyMap()); changed() }

    private fun trim(progress: Map<String, PlaybackProgress>): Map<String, PlaybackProgress> {
        if (progress.size <= policy.maxProgressRecords) return progress
        return progress.values.sortedByDescending { it.updatedAt }.take(policy.maxProgressRecords).associateBy { it.id }
    }

    // MARK: Search history

    // MARK: Diary

    @Synchronized
    fun diary(): List<DiaryEntry> { ensureLoaded(); return state.diary.sortedByDescending { it.watchedAt } }

    /** Adds or replaces a viewing; a second viewing of the same title is a rewatch. */
    @Synchronized
    fun saveDiary(entry: DiaryEntry) {
        ensureLoaded()
        val fixed = entry.copy(rating = entry.rating?.coerceIn(1, 10), rewatch = entry.rewatch || state.diary.any { it.metaId == entry.metaId && it.id != entry.id && it.episodeLabel == entry.episodeLabel })
        val list = state.diary.filter { it.id != entry.id } + fixed
        state = state.copy(diary = list.sortedByDescending { it.watchedAt }.take(5000))
        changed()
    }

    @Synchronized
    fun removeDiary(id: String) { ensureLoaded(); state = state.copy(diary = state.diary.filter { it.id != id }); changed() }

    // MARK: Collections

    @Synchronized
    fun collections(): List<LibraryCollection> { ensureLoaded(); return state.collections }

    /** A new list (or the one with that name); null when the name is empty or longer than 40 letters. */
    @Synchronized
    fun createCollection(name: String): LibraryCollection? {
        ensureLoaded()
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.length > 40) return null
        state.collections.firstOrNull { it.name.equals(trimmed, ignoreCase = true) }?.let { return it }
        val made = LibraryCollection(name = trimmed)
        state = state.copy(collections = state.collections + made)
        changed()
        return made
    }

    @Synchronized
    fun renameCollection(id: String, name: String) {
        ensureLoaded()
        val trimmed = name.trim()
        if (trimmed.isEmpty() || trimmed.length > 40) return
        state = state.copy(collections = state.collections.map { if (it.id == id) it.copy(name = trimmed) else it }); changed()
    }

    @Synchronized
    fun deleteCollection(id: String) { ensureLoaded(); state = state.copy(collections = state.collections.filter { it.id != id }); changed() }

    @Synchronized
    fun toggleInCollection(id: String, meta: MetaItem) {
        ensureLoaded()
        state = state.copy(collections = state.collections.map { c ->
            if (c.id != id) c else if (c.items.any { it.id == meta.id }) c.copy(items = c.items.filter { it.id != meta.id })
            else c.copy(items = listOf(CollectionItem(meta.id, meta.type, meta.name, meta.poster)) + c.items)
        })
        changed()
    }

    @Synchronized
    fun collectionsContaining(metaId: String): List<LibraryCollection> { ensureLoaded(); return state.collections.filter { c -> c.items.any { it.id == metaId } } }

    /** Titles started and left alone for more than [days] days (not finished, not dismissed), the longest forgotten first. */
    @Synchronized
    fun abandoned(days: Int = 30, limit: Int = 60): List<PlaybackProgress> {
        ensureLoaded()
        val cutoff = now() - days * 86_400_000L
        val latest = HashMap<String, PlaybackProgress>()
        for (record in state.progress.values) {
            val current = latest[record.metaId]
            if (current != null && current.updatedAt >= record.updatedAt) continue
            latest[record.metaId] = record
        }
        return latest.values.filter { !it.isCompleted && it.updatedAt < cutoff && it.position >= 60 && !ContentType.isLive(it.type) }
            .sortedBy { it.updatedAt }.take(limit)
    }

    @Synchronized
    fun searchHistory(): List<SearchHistoryItem> { ensureLoaded(); return state.searchHistory }

    @Synchronized
    fun addSearch(query: String) {
        ensureLoaded()
        val clean = query.trim().replace(Regex("\\s+"), " ")
        if (clean.isEmpty()) return
        val item = SearchHistoryItem(clean, now())
        state = state.copy(searchHistory = (listOf(item) + state.searchHistory.filter { it.id != item.id }).take(policy.maxSearchHistory))
        changed()
    }

    @Synchronized
    fun removeSearch(query: String) {
        ensureLoaded()
        state = state.copy(searchHistory = state.searchHistory.filter { it.id != query.lowercase() })
        changed()
    }

    @Synchronized
    fun clearSearchHistory() { ensureLoaded(); state = state.copy(searchHistory = emptyList()); changed() }

    /** Local search through the watchlist, favourites and history: works with no network. */
    @Synchronized
    fun searchLocal(query: String, limit: Int = 30): List<MetaItem> {
        ensureLoaded()
        val needle = MetaDeduper.normalise(query)
        if (needle.isEmpty()) return emptyList()
        val items = ArrayList<MetaItem>()
        state.entries.values.filter { !it.isRemoved }.forEach { items.add(it.asMeta) }
        state.progress.values.forEach { items.add(it.asMeta) }
        return MetaDeduper.dedupe(items).filter { MetaDeduper.normalise(it.name).contains(needle) }.take(limit)
    }

    // MARK: Backup and merge

    @Synchronized
    fun snapshot(): LibraryState { ensureLoaded(); return state }

    @Synchronized
    fun replace(with: LibraryState) { ensureLoaded(); state = with; changed() }

    @Synchronized
    fun merge(other: LibraryState) {
        ensureLoaded()
        state = LibraryMerge.merge(state, other, now(), policy.maxSearchHistory)
        changed()
    }

    @Synchronized
    fun deleteAll() { ensureLoaded(); state = LibraryState(); changed() }

    /** The episode a series' main button should start, from the stored progress. */
    fun episodeToPlay(meta: MetaItem): Video? {
        val progress = progressFor(meta.id).values
        val lastCompleted = progress.filter { it.isCompleted }.maxByOrNull { it.updatedAt }?.videoId
        val inProgress = progress.filter { !it.isCompleted && it.position >= 10 }.maxByOrNull { it.updatedAt }?.videoId
        return NextEpisodeResolver.episodeToPlay(meta, watchedVideoIds(meta.id), lastCompleted, inProgress)
    }
}
