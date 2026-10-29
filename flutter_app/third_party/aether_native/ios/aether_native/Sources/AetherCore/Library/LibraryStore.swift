import Foundation

/// Local library: watchlist, favourites, resume points, history, search history. Persisted as JSON with debounced writes.
public actor LibraryStore {
    private let store: JSONFileStore<LibraryState>
    private let now: @Sendable () -> Date
    private let saveDelay: UInt64

    public private(set) var policy: LibraryPolicy
    private var state = LibraryState()
    private var loaded = false
    private var dirty = false
    private var saveTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(store: JSONFileStore<LibraryState>, policy: LibraryPolicy = LibraryPolicy(),
                saveDelaySeconds: Double = 1.5, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.policy = policy
        self.saveDelay = UInt64(max(0, saveDelaySeconds) * 1_000_000_000)
        self.now = now
    }

    public func setPolicy(_ newPolicy: LibraryPolicy) {
        policy = newPolicy
    }

    // MARK: Lifecycle

    public func load() {
        if loaded { return }
        loaded = true
        if let stored = store.load() {
            state = stored
        }
    }

    /// Writes pending changes immediately (call when the app goes to background).
    public func flush() {
        load()
        saveTask?.cancel()
        saveTask = nil
        if dirty {
            try? store.save(state)
            dirty = false
        }
    }

    /// Stream that fires after every mutation, for UI refresh.
    public func updates() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func didMutate() {
        dirty = true
        for continuation in observers.values { continuation.yield() }
        if saveTask == nil {
            let delay = saveDelay
            saveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                await self?.performScheduledSave()
            }
        }
    }

    private func performScheduledSave() {
        saveTask = nil
        if dirty {
            try? store.save(state)
            dirty = false
        }
    }

    // MARK: Watchlist / favourites

    public func entry(id: String) -> LibraryEntry? {
        load()
        guard let entry = state.entries[id], !entry.isRemoved else { return nil }
        return entry
    }

    public func isInWatchlist(_ id: String) -> Bool { return entry(id: id)?.inWatchlist ?? false }
    public func isFavorite(_ id: String) -> Bool { return entry(id: id)?.isFavorite ?? false }

    public func setWatchlist(_ enabled: Bool, meta: MetaItem) {
        mutateEntry(meta: meta) { $0.inWatchlist = enabled }
    }

    public func setFavorite(_ enabled: Bool, meta: MetaItem) {
        mutateEntry(meta: meta) { $0.isFavorite = enabled }
    }

    private func mutateEntry(meta: MetaItem, _ change: (inout LibraryEntry) -> Void) {
        load()
        let timestamp = now()
        var entry = state.entries[meta.id] ?? LibraryEntry(meta: meta, now: timestamp)
        if entry.isRemoved {
            entry = LibraryEntry(meta: meta, now: timestamp)
        }
        // Refresh display fields from the freshest metadata we have.
        entry.name = meta.name
        entry.type = meta.type
        if let poster = meta.poster { entry.poster = poster }
        if let background = meta.background { entry.background = background }
        if let logo = meta.logo { entry.logo = logo }
        if let info = meta.releaseInfo { entry.releaseInfo = info }
        if let rating = meta.imdbRating { entry.imdbRating = rating }
        change(&entry)
        entry.modifiedAt = timestamp
        if !entry.inWatchlist && !entry.isFavorite {
            entry.isRemoved = true
        } else {
            entry.isRemoved = false
        }
        state.entries[meta.id] = entry
        didMutate()
    }

    public func watchlist() -> [LibraryEntry] {
        load()
        return state.entries.values.filter { !$0.isRemoved && $0.inWatchlist }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func favorites() -> [LibraryEntry] {
        load()
        return state.entries.values.filter { !$0.isRemoved && $0.isFavorite }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: Progress & history

    public func progress(metaID: String, videoID: String) -> PlaybackProgress? {
        load()
        return state.progress[PlaybackProgress.key(metaID: metaID, videoID: videoID)]
    }

    /// Seconds to resume from, or nil if there is nothing meaningful to resume (completed / too early).
    public func resumePosition(metaID: String, videoID: String) -> Double? {
        guard let record = progress(metaID: metaID, videoID: videoID) else { return nil }
        if record.isCompleted { return nil }
        if record.position < policy.minimumRecordedSeconds { return nil }
        return record.position
    }

    /// Called periodically by the player. Returns true if the video crossed the "watched" threshold.
    @discardableResult
    public func recordProgress(meta: MetaItem, video: Video?, position: Double, duration: Double) -> Bool {
        load()
        guard policy.recordHistory else { return false }
        guard position.isFinite, duration.isFinite else { return false }
        let videoID = video?.id ?? meta.id
        let key = PlaybackProgress.key(metaID: meta.id, videoID: videoID)
        var record = state.progress[key] ?? PlaybackProgress(
            metaID: meta.id, videoID: videoID, type: meta.type, title: meta.name,
            episodeTitle: video?.title, season: video?.season, episode: video?.episode,
            poster: meta.poster, posterShape: meta.posterShape, background: meta.background)
        if record.position < policy.minimumRecordedSeconds && position < policy.minimumRecordedSeconds && !record.isCompleted {
            // Not worth recording yet.
            return false
        }
        record.title = meta.name
        record.poster = meta.poster ?? record.poster
        record.background = meta.background ?? record.background
        record.episodeTitle = video?.title ?? record.episodeTitle
        record.season = video?.season ?? record.season
        record.episode = video?.episode ?? record.episode
        record.position = max(0, position)
        if duration > 0 { record.duration = duration }
        record.updatedAt = now()
        record.isDismissed = false
        var crossed = false
        if record.duration > 0 && record.position / record.duration >= policy.watchedThreshold {
            if !record.isCompleted { crossed = true }
            record.isCompleted = true
        } else if record.isCompleted && record.duration > 0 && record.fraction < 0.5 {
            // The user is re-watching from the start.
            record.isCompleted = false
        }
        state.progress[key] = record
        trimProgress()
        didMutate()
        return crossed
    }

    public func markWatched(_ watched: Bool, meta: MetaItem, video: Video?) {
        load()
        let videoID = video?.id ?? meta.id
        let key = PlaybackProgress.key(metaID: meta.id, videoID: videoID)
        if !watched {
            state.progress.removeValue(forKey: key)
            didMutate()
            return
        }
        var record = state.progress[key] ?? PlaybackProgress(
            metaID: meta.id, videoID: videoID, type: meta.type, title: meta.name,
            episodeTitle: video?.title, season: video?.season, episode: video?.episode,
            poster: meta.poster, posterShape: meta.posterShape, background: meta.background)
        record.isCompleted = true
        if record.duration > 0 { record.position = record.duration }
        record.updatedAt = now()
        record.isDismissed = true
        state.progress[key] = record
        didMutate()
    }

    /// Marks many episodes at once (a whole season) with a single persistence round.
    public func markWatched(_ watched: Bool, meta: MetaItem, videos: [Video]) {
        load()
        for video in videos {
            let key = PlaybackProgress.key(metaID: meta.id, videoID: video.id)
            if !watched {
                state.progress.removeValue(forKey: key)
                continue
            }
            var record = state.progress[key] ?? PlaybackProgress(
                metaID: meta.id, videoID: video.id, type: meta.type, title: meta.name,
                episodeTitle: video.title, season: video.season, episode: video.episode,
                poster: meta.poster, posterShape: meta.posterShape, background: meta.background)
            record.isCompleted = true
            if record.duration > 0 { record.position = record.duration }
            record.updatedAt = now()
            record.isDismissed = true
            state.progress[key] = record
        }
        didMutate()
    }

    public func watchedVideoIDs(metaID: String) -> Set<String> {
        load()
        var result = Set<String>()
        for record in state.progress.values where record.metaID == metaID && record.isCompleted {
            result.insert(record.videoID)
        }
        return result
    }

    /// Latest unfinished video per title, newest first.
    public func continueWatching(limit: Int = 30) -> [PlaybackProgress] {
        load()
        var latestByMeta: [String: PlaybackProgress] = [:]
        for record in state.progress.values {
            if let current = latestByMeta[record.metaID], current.updatedAt >= record.updatedAt { continue }
            latestByMeta[record.metaID] = record
        }
        let candidates = latestByMeta.values.filter { record in
            !record.isCompleted && !record.isDismissed
                && record.position >= policy.minimumRecordedSeconds
                && !ContentType.isLive(record.type)
        }
        return Array(candidates.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// Latest *completed* episode per series, newest first. The UI resolves the following episode via metadata.
    public func nextUpSeeds(limit: Int = 20) -> [PlaybackProgress] {
        load()
        var latestByMeta: [String: PlaybackProgress] = [:]
        for record in state.progress.values where ContentType.hasEpisodes(record.type) {
            if let current = latestByMeta[record.metaID], current.updatedAt >= record.updatedAt { continue }
            latestByMeta[record.metaID] = record
        }
        let seeds = latestByMeta.values.filter { $0.isCompleted && $0.season != nil && $0.episode != nil }
        return Array(seeds.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    public func history(limit: Int = 500) -> [PlaybackProgress] {
        load()
        let records = state.progress.values.filter { $0.isCompleted || $0.position >= policy.minimumRecordedSeconds }
        return Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    public func dismissFromContinueWatching(metaID: String) {
        load()
        for (key, record) in state.progress where record.metaID == metaID {
            var updated = record
            updated.isDismissed = true
            state.progress[key] = updated
        }
        didMutate()
    }

    public func removeHistory(id: String) {
        load()
        state.progress.removeValue(forKey: id)
        didMutate()
    }

    public func clearHistory() {
        load()
        state.progress = [:]
        didMutate()
    }

    private func trimProgress() {
        guard state.progress.count > policy.maxProgressRecords else { return }
        let sorted = state.progress.values.sorted { $0.updatedAt > $1.updatedAt }
        let keep = sorted.prefix(policy.maxProgressRecords)
        var trimmed: [String: PlaybackProgress] = [:]
        for record in keep { trimmed[record.id] = record }
        state.progress = trimmed
    }

    // MARK: Search history

    public func searchHistory() -> [SearchHistoryItem] {
        load()
        return state.searchHistory
    }

    public func addSearch(_ query: String) {
        load()
        guard policy.recordHistory else { return }
        let trimmed = SearchService.normalisedQuery(query)
        guard trimmed.count >= 2 else { return }
        state.searchHistory.removeAll(where: { $0.id == trimmed.lowercased() })
        state.searchHistory.insert(SearchHistoryItem(query: trimmed, date: now()), at: 0)
        if state.searchHistory.count > policy.maxSearchHistory {
            state.searchHistory = Array(state.searchHistory.prefix(policy.maxSearchHistory))
        }
        didMutate()
    }

    public func removeSearch(_ query: String) {
        load()
        state.searchHistory.removeAll(where: { $0.id == query.lowercased() })
        didMutate()
    }

    public func clearSearchHistory() {
        load()
        state.searchHistory = []
        didMutate()
    }

    // MARK: Local search

    /// Case/diacritic-insensitive match over watchlist, favourites and history titles.
    public func searchLocal(_ query: String, limit: Int = 30) -> [MetaItem] {
        load()
        let needle = MetaDeduper.normalise(query)
        guard !needle.isEmpty else { return [] }
        var items: [MetaItem] = []
        for entry in state.entries.values where !entry.isRemoved {
            if MetaDeduper.normalise(entry.name).contains(needle) { items.append(entry.asMeta) }
        }
        for record in state.progress.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if MetaDeduper.normalise(record.title).contains(needle) { items.append(record.asMeta) }
        }
        return Array(MetaDeduper.dedupe(items).prefix(limit))
    }

    // MARK: Backup / restore

    public func snapshot() -> LibraryState {
        load()
        return state
    }

    /// Replaces the whole state (restore) or applies a merged state.
    public func replace(with newState: LibraryState) {
        load()
        state = newState
        didMutate()
        flush()
    }

    public func merge(_ other: LibraryState) {
        load()
        state = LibraryMerge.merge(local: state, remote: other, now: now())
        didMutate()
        flush()
    }

    public func deleteAll() {
        load()
        state = LibraryState()
        saveTask?.cancel()
        saveTask = nil
        dirty = false
        store.delete()
        for continuation in observers.values { continuation.yield() }
    }
}
