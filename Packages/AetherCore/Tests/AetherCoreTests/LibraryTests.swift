import XCTest
@testable import AetherCore

final class LibraryStoreTests: XCTestCase {
    private var directory: URL!
    private var clock: Date = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = try makeTempDirectory()
        clock = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private func makeStore(policy: LibraryPolicy = LibraryPolicy()) -> LibraryStore {
        let file = JSONFileStore<LibraryState>(url: directory.appendingPathComponent("library.json"))
        let box = ClockBox(clock)
        return LibraryStore(store: file, policy: policy, saveDelaySeconds: 0.05, now: { box.now })
    }

    /// The store takes a @Sendable clock; this keeps tests deterministic.
    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let movie = MetaItem(id: "tt0000001", type: "movie", name: "Film Uno", poster: "p1.jpg", releaseInfo: "2020")
    private let series = MetaItem(id: "tt0000002", type: "series", name: "Serie Due", poster: "p2.jpg",
                                  videos: [Video(id: "tt0000002:1:1", title: "E1", season: 1, episode: 1),
                                           Video(id: "tt0000002:1:2", title: "E2", season: 1, episode: 2),
                                           Video(id: "tt0000002:1:3", title: "E3", season: 1, episode: 3)])

    func testWatchlistAndFavoritesAreIndependentAndTombstoned() async {
        let store = makeStore()
        await store.setWatchlist(true, meta: movie)
        await store.setFavorite(true, meta: movie)
        var watchlist = await store.watchlist()
        var favorites = await store.favorites()
        XCTAssertEqual(watchlist.map { $0.id }, ["tt0000001"])
        XCTAssertEqual(favorites.map { $0.id }, ["tt0000001"])

        await store.setWatchlist(false, meta: movie)
        watchlist = await store.watchlist()
        favorites = await store.favorites()
        XCTAssertTrue(watchlist.isEmpty)
        XCTAssertEqual(favorites.count, 1)

        await store.setFavorite(false, meta: movie)
        let entry = await store.entry(id: "tt0000001")
        XCTAssertNil(entry, "removed entries are hidden")
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.entries["tt0000001"]?.isRemoved, true, "…but kept as a tombstone for merges")
    }

    func testProgressThresholdsResumeAndCompletion() async {
        let store = makeStore()
        let video = series.videos[0]

        let tooEarly = await store.recordProgress(meta: series, video: video, position: 3, duration: 3000)
        XCTAssertFalse(tooEarly)
        var resume = await store.resumePosition(metaID: series.id, videoID: video.id)
        XCTAssertNil(resume, "positions under 10 s are not recorded")

        _ = await store.recordProgress(meta: series, video: video, position: 600, duration: 3000)
        resume = await store.resumePosition(metaID: series.id, videoID: video.id)
        XCTAssertEqual(resume, 600)

        let crossed = await store.recordProgress(meta: series, video: video, position: 2800, duration: 3000)
        XCTAssertTrue(crossed, "93% crosses the default 90% threshold")
        resume = await store.resumePosition(metaID: series.id, videoID: video.id)
        XCTAssertNil(resume, "completed videos do not resume")
        let watched = await store.watchedVideoIDs(metaID: series.id)
        XCTAssertEqual(watched, [video.id])
        let again = await store.recordProgress(meta: series, video: video, position: 2900, duration: 3000)
        XCTAssertFalse(again, "crossing is reported once")
    }

    func testConfigurableWatchedThreshold() async {
        let store = makeStore(policy: LibraryPolicy(watchedThreshold: 0.5))
        let crossed = await store.recordProgress(meta: movie, video: nil, position: 600, duration: 1000)
        XCTAssertTrue(crossed)
    }

    func testRewatchFromTheStartClearsCompletion() async {
        let store = makeStore()
        _ = await store.recordProgress(meta: movie, video: nil, position: 950, duration: 1000)
        _ = await store.recordProgress(meta: movie, video: nil, position: 100, duration: 1000)
        let record = await store.progress(metaID: movie.id, videoID: movie.id)
        XCTAssertEqual(record?.isCompleted, false)
        let resume = await store.resumePosition(metaID: movie.id, videoID: movie.id)
        XCTAssertEqual(resume, 100)
    }

    func testContinueWatchingAndNextUpSeeds() async {
        let box = ClockBox(clock)
        let store = LibraryStore(store: JSONFileStore<LibraryState>(url: directory.appendingPathComponent("l2.json")),
                                 saveDelaySeconds: 0.05, now: { box.now })
        _ = await store.recordProgress(meta: movie, video: nil, position: 500, duration: 6000)
        box.now = box.now.addingTimeInterval(60)
        _ = await store.recordProgress(meta: series, video: series.videos[0], position: 2900, duration: 3000)  // completed E1
        box.now = box.now.addingTimeInterval(60)
        _ = await store.recordProgress(meta: series, video: series.videos[1], position: 400, duration: 3000)   // in progress E2

        var cont = await store.continueWatching()
        XCTAssertEqual(cont.map { $0.metaID }, [series.id, movie.id], "newest first, one entry per title")
        XCTAssertEqual(cont.first?.videoID, "tt0000002:1:2")
        XCTAssertEqual(cont.first?.episodeLabel, "S01E02")

        var seeds = await store.nextUpSeeds()
        XCTAssertTrue(seeds.isEmpty, "the latest record of the series is unfinished, so it belongs to Continue")

        _ = await store.recordProgress(meta: series, video: series.videos[1], position: 2950, duration: 3000)  // E2 completed
        cont = await store.continueWatching()
        XCTAssertEqual(cont.map { $0.metaID }, [movie.id])
        seeds = await store.nextUpSeeds()
        XCTAssertEqual(seeds.map { $0.videoID }, ["tt0000002:1:2"])

        await store.dismissFromContinueWatching(metaID: movie.id)
        cont = await store.continueWatching()
        XCTAssertTrue(cont.isEmpty)
    }

    func testManualWatchedMarksAndSeasons() async {
        let store = makeStore()
        await store.markWatched(true, meta: series, videos: series.videos)
        var watched = await store.watchedVideoIDs(metaID: series.id)
        XCTAssertEqual(watched.count, 3)
        await store.markWatched(false, meta: series, video: series.videos[1])
        watched = await store.watchedVideoIDs(metaID: series.id)
        XCTAssertEqual(watched, ["tt0000002:1:1", "tt0000002:1:3"])
    }

    func testHistoryRestoreAfterRelaunch() async {
        let store = makeStore()
        _ = await store.recordProgress(meta: movie, video: nil, position: 700, duration: 6000)
        await store.setWatchlist(true, meta: series)
        await store.addSearch("blade runner")
        await store.flush()

        let reborn = makeStore()
        let history = await reborn.history()
        XCTAssertEqual(history.map { $0.metaID }, [movie.id])
        let watchlist = await reborn.watchlist()
        XCTAssertEqual(watchlist.map { $0.id }, [series.id])
        let searches = await reborn.searchHistory()
        XCTAssertEqual(searches.map { $0.query }, ["blade runner"])
        let resume = await reborn.resumePosition(metaID: movie.id, videoID: movie.id)
        XCTAssertEqual(resume, 700)
    }

    func testDebouncedSaveEventuallyWritesWithoutFlush() async throws {
        let store = makeStore()
        await store.setWatchlist(true, meta: movie)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.json").path))
    }

    func testPrivacySwitchStopsRecording() async {
        let store = makeStore(policy: LibraryPolicy(recordHistory: false))
        let crossed = await store.recordProgress(meta: movie, video: nil, position: 5000, duration: 6000)
        XCTAssertFalse(crossed)
        await store.addSearch("segreto")
        let history = await store.history()
        let searches = await store.searchHistory()
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(searches.isEmpty)
    }

    func testClearingHistoryAndSearchHistory() async {
        let store = makeStore()
        _ = await store.recordProgress(meta: movie, video: nil, position: 700, duration: 6000)
        await store.addSearch("uno")
        await store.addSearch("due")
        await store.addSearch("UNO")
        var searches = await store.searchHistory()
        XCTAssertEqual(searches.map { $0.query }, ["UNO", "due"], "case-insensitive de-duplication, newest first")
        await store.removeSearch("due")
        searches = await store.searchHistory()
        XCTAssertEqual(searches.count, 1)
        await store.clearHistory()
        await store.clearSearchHistory()
        let history = await store.history()
        searches = await store.searchHistory()
        XCTAssertTrue(history.isEmpty)
        XCTAssertTrue(searches.isEmpty)
    }

    func testLocalSearchAcrossLibraryAndHistory() async {
        let store = makeStore()
        await store.setFavorite(true, meta: MetaItem(id: "tt9", type: "movie", name: "Amélie"))
        _ = await store.recordProgress(meta: movie, video: nil, position: 700, duration: 6000)
        let accent = await store.searchLocal("amelie")
        XCTAssertEqual(accent.map { $0.id }, ["tt9"])
        let history = await store.searchLocal("uno")
        XCTAssertEqual(history.map { $0.id }, [movie.id])
        let none = await store.searchLocal("zzz")
        XCTAssertTrue(none.isEmpty)
    }

    func testUpdatesStreamFiresOnMutation() async throws {
        let store = makeStore()
        let stream = await store.updates()
        let received = Task { () -> Bool in
            for await _ in stream { return true }
            return false
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await store.setWatchlist(true, meta: movie)
        let fired = await received.value
        XCTAssertTrue(fired)
    }

    func testCorruptedFileFallsBackToBackup() async throws {
        let store = makeStore()
        await store.setWatchlist(true, meta: movie)
        await store.flush()
        await store.setWatchlist(true, meta: series)   // creates a .bak of the previous generation on the next flush
        await store.flush()
        let file = directory.appendingPathComponent("library.json")
        try Data("{ this is not json".utf8).write(to: file)
        let reborn = makeStore()
        let watchlist = await reborn.watchlist()
        XCTAssertEqual(watchlist.map { $0.id }, ["tt0000001"], "the previous generation is recovered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path),
                      "the unreadable file is quarantined, not deleted")
    }

    func testLenientDecodingSurvivesMissingFieldsAndBadRecords() throws {
        let json = """
        {"schemaVersion":1,
         "entries":[{"id":"a","name":"A","inWatchlist":true},{"nonsense":true},{"id":"b","type":"movie","name":"B","isFavorite":true,"modifiedAt":"2024-01-01T00:00:00Z"}],
         "progress":[{"metaID":"a","videoID":"a","position":30}, "garbage"],
         "searchHistory":[{"query":"x"},{}],
         "futureField": 42}
        """
        let state = try JSONDecoder.aether().decode(LibraryState.self, from: Data(json.utf8))
        XCTAssertEqual(state.entries.count, 2)
        XCTAssertEqual(state.entries["a"]?.inWatchlist, true)
        XCTAssertEqual(state.entries["b"]?.isFavorite, true)
        XCTAssertEqual(state.progress.count, 1)
        XCTAssertEqual(state.progress["a|a"]?.position, 30)
        XCTAssertEqual(state.searchHistory.map { $0.query }, ["x"])
    }
}

final class BackupMergeTests: XCTestCase {
    private func entry(_ id: String, wl: Bool = true, fav: Bool = false, removed: Bool = false, at seconds: TimeInterval) -> LibraryEntry {
        return LibraryEntry(id: id, type: "movie", name: id, inWatchlist: wl, isFavorite: fav,
                            addedAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: seconds), isRemoved: removed)
    }

    private func progress(_ id: String, pos: Double, completed: Bool = false, at seconds: TimeInterval) -> PlaybackProgress {
        return PlaybackProgress(metaID: id, videoID: id, type: "movie", title: id, position: pos, duration: 1000,
                                updatedAt: Date(timeIntervalSince1970: seconds), isCompleted: completed)
    }

    func testLastWriterWinsPerRecord() {
        var local = LibraryState()
        local.entries["a"] = entry("a", wl: true, at: 100)
        local.entries["only-local"] = entry("only-local", at: 50)
        local.progress["a|a"] = progress("a", pos: 100, at: 100)
        var remote = LibraryState()
        remote.entries["a"] = entry("a", wl: false, fav: true, at: 200)
        remote.entries["only-remote"] = entry("only-remote", at: 60)
        remote.progress["a|a"] = progress("a", pos: 50, at: 90)

        let merged = LibraryMerge.merge(local: local, remote: remote, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(merged.entries["a"]?.isFavorite, true, "newer remote record wins")
        XCTAssertEqual(merged.entries["a"]?.inWatchlist, false)
        XCTAssertNotNil(merged.entries["only-local"])
        XCTAssertNotNil(merged.entries["only-remote"])
        XCTAssertEqual(merged.progress["a|a"]?.position, 100, "newer local progress wins")
    }

    func testTombstonesBeatOlderCopiesAndExpire() {
        var local = LibraryState()
        local.entries["gone"] = entry("gone", wl: false, removed: true, at: 500)
        local.entries["ancient"] = entry("ancient", wl: false, removed: true, at: 10)
        var remote = LibraryState()
        remote.entries["gone"] = entry("gone", wl: true, at: 400)
        let now = Date(timeIntervalSince1970: LibraryMerge.tombstoneRetention + 100)
        let merged = LibraryMerge.merge(local: local, remote: remote, now: now)
        XCTAssertEqual(merged.entries["gone"]?.isRemoved, true, "a newer deletion is not undone by an older copy")
        XCTAssertNil(merged.entries["ancient"], "year-old tombstones are pruned")
    }

    func testCompletionIsNotLostOnEqualTimestamps() {
        var local = LibraryState()
        local.progress["a|a"] = progress("a", pos: 100, completed: false, at: 100)
        var remote = LibraryState()
        remote.progress["a|a"] = progress("a", pos: 950, completed: true, at: 100)
        let merged = LibraryMerge.merge(local: local, remote: remote, now: Date())
        XCTAssertEqual(merged.progress["a|a"]?.isCompleted, true)
    }

    func testSearchHistoryUnionIsCapped() {
        var local = LibraryState()
        local.searchHistory = [SearchHistoryItem(query: "one", date: Date(timeIntervalSince1970: 10))]
        var remote = LibraryState()
        remote.searchHistory = [SearchHistoryItem(query: "ONE", date: Date(timeIntervalSince1970: 20)),
                                SearchHistoryItem(query: "two", date: Date(timeIntervalSince1970: 15))]
        let merged = LibraryMerge.merge(local: local, remote: remote, now: Date(), maxSearchHistory: 30)
        XCTAssertEqual(merged.searchHistory.map { $0.query }, ["ONE", "two"])
        let capped = LibraryMerge.merge(local: local, remote: remote, now: Date(), maxSearchHistory: 1)
        XCTAssertEqual(capped.searchHistory.count, 1)
    }

    func testBackupRoundTripAndValidation() throws {
        var library = LibraryState()
        library.entries["a"] = entry("a", at: 100)
        library.progress["a|a"] = progress("a", pos: 120, at: 100)
        var settings = AppSettings()
        settings.playback.skipForwardSeconds = 30
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_full.json"))
        let addon = InstalledAddon(manifest: manifest, host: "a.test", fingerprint: "fp")
        let backup = AetherBackup(createdAt: Date(timeIntervalSince1970: 1000), appVersion: "1.0", library: library,
                                  settings: settings, addons: [BackupAddon(addon: addon, url: nil)], includesAddonURLs: false)
        let data = try BackupCodec.encode(backup)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(AetherBackup.marker))
        XCTAssertFalse(text.contains("https://a.test"), "URLs are not exported unless asked")

        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded.library.entries.count, 1)
        XCTAssertEqual(decoded.settings?.playback.skipForwardSeconds, 30)
        XCTAssertEqual(decoded.addons.first?.addon.manifest.id, "org.aether.fixture.full")
        XCTAssertFalse(decoded.includesAddonURLs)

        XCTAssertThrowsError(try BackupCodec.decode(Data("{\"hello\":1}".utf8))) { error in
            XCTAssertEqual(error as? BackupError, .notABackup)
        }
        XCTAssertThrowsError(try BackupCodec.decode(Data("nope".utf8))) { error in
            XCTAssertEqual(error as? BackupError, .unreadable)
        }
        let future = "{\"marker\":\"\(AetherBackup.marker)\",\"formatVersion\":99}"
        XCTAssertThrowsError(try BackupCodec.decode(Data(future.utf8))) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(99))
        }
    }

    func testStoreMergeAppliesAndPersists() async throws {
        let directory = try makeTempDirectory()
        let store = LibraryStore(store: JSONFileStore<LibraryState>(url: directory.appendingPathComponent("l.json")), saveDelaySeconds: 0.05)
        await store.setWatchlist(true, meta: MetaItem(id: "local", type: "movie", name: "Local"))
        var remote = LibraryState()
        remote.entries["remote"] = entry("remote", at: Date().timeIntervalSince1970 + 5)
        await store.merge(remote)
        let ids = await store.watchlist().map { $0.id }
        XCTAssertEqual(Set(ids), ["local", "remote"])
    }
}
