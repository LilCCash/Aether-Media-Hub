import XCTest
@testable import AetherCore

final class DownloadTests: XCTestCase {
    private func evaluate(_ stream: AddonStream, allowLocal: Bool = false) -> DownloadEligibility {
        return DownloadPlanner.evaluate(stream: stream, info: StreamAnalyzer.analyze(stream), allowLocalNetwork: allowLocal)
    }

    func testOnlyPlainHTTPSFilesAreDownloadable() {
        let ok = AddonStream(source: .url("https://cdn.test/movie.mp4"))
        XCTAssertEqual(evaluate(ok), .allowed(URL(string: "https://cdn.test/movie.mp4")!))
        let unknownContainer = AddonStream(source: .url("https://cdn.test/dl/abc"))
        XCTAssertTrue(evaluate(unknownContainer).isAllowed)
    }

    func testStreamsTorrentsAndArchivesAreRefused() {
        let refused: [AddonStream] = [
            AddonStream(source: .url("https://cdn.test/master.m3u8")),
            AddonStream(source: .url("https://cdn.test/a.mpd")),
            AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: nil, trackers: [])),
            AddonStream(source: .youtube("x")),
            AddonStream(source: .external("https://x.test")),
            AddonStream(source: .archive(kind: "rar")),
            AddonStream(source: .unknown)
        ]
        for stream in refused {
            XCTAssertFalse(evaluate(stream).isAllowed, "\(stream.source)")
        }
    }

    func testFilesThatCouldNotPlayOfflineAreRefused() {
        let mkv = AddonStream(source: .url("https://cdn.test/movie.mkv"))
        guard case .notAllowed(let reason) = evaluate(mkv) else { return XCTFail("expected refusal") }
        XCTAssertTrue(reason.contains("offline"))
    }

    func testHostRules() {
        XCTAssertFalse(evaluate(AddonStream(source: .url("http://cdn.test/a.mp4"))).isAllowed, "ATS blocks plain HTTP downloads")
        XCTAssertFalse(evaluate(AddonStream(source: .url("https://127.0.0.1/a.mp4"))).isAllowed)
        XCTAssertFalse(evaluate(AddonStream(source: .url("http://192.168.1.5/a.mp4"))).isAllowed)
        XCTAssertTrue(evaluate(AddonStream(source: .url("http://192.168.1.5/a.mp4")), allowLocal: true).isAllowed)
    }

    func testDownloadStoreLifecycleAndPersistence() async throws {
        let directory = try makeTempDirectory()
        let file = JSONFileStore<DownloadStoreState>(url: directory.appendingPathComponent("downloads.json"))
        let store = DownloadStore(store: file)
        let item = DownloadItem(metaID: "tt1", videoID: nil, type: "movie", title: "Film", sourceURL: "https://cdn.test/a.mp4")
        await store.add(item)
        let duplicate = await store.existing(metaID: "tt1", videoID: nil)
        XCTAssertEqual(duplicate?.id, item.id)

        await store.update(id: item.id) { $0.state = .downloading; $0.bytesWritten = 250; $0.totalBytes = 1000 }
        let midway = await store.item(id: item.id)
        XCTAssertEqual(midway?.fraction ?? 0, 0.25, accuracy: 0.0001)

        await store.update(id: item.id) { $0.state = .completed; $0.bytesWritten = 1000; $0.localFileName = "a.mp4" }
        let total = await store.totalBytesOnDisk()
        XCTAssertEqual(total, 1000)

        let reborn = DownloadStore(store: file)
        let all = await reborn.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.localFileName, "a.mp4")

        await store.update(id: item.id) { $0.state = .failed }
        let afterFailure = await store.existing(metaID: "tt1", videoID: nil)
        XCTAssertNil(afterFailure, "failed downloads may be retried")
        let removed = await store.remove(id: item.id)
        XCTAssertEqual(removed?.id, item.id)
        let empty = await store.all()
        XCTAssertTrue(empty.isEmpty)
    }
}

final class RedactorAndLogTests: XCTestCase {
    func testURLsAreReducedToHostAndSecretsMasked() {
        let input = "GET https://addon.example.com:8443/SECRETKEY123/manifest.json?token=abc failed; api_key=ZZZ999 and Authorization: Bearer abcdef"
        let output = Redactor.redact(input)
        XCTAssertFalse(output.contains("SECRETKEY123"))
        XCTAssertFalse(output.contains("token=abc"))
        XCTAssertFalse(output.contains("ZZZ999"))
        XCTAssertFalse(output.contains("abcdef"))
        XCTAssertTrue(output.contains("https://addon.example.com:8443/…"))
    }

    func testEmailsAndLongTokensAreMasked() {
        let output = Redactor.redact("user a.b@example.com hash 0123456789abcdef0123456789abcdef01234567 end")
        XCTAssertFalse(output.contains("a.b@example.com"))
        XCTAssertFalse(output.contains("0123456789abcdef0123456789abcdef01234567"))
        XCTAssertTrue(output.contains("«email»"))
        XCTAssertTrue(output.contains("«token»"))
    }

    func testPlainTextIsUntouched() {
        XCTAssertEqual(Redactor.redact("Catalogo caricato in 120 ms"), "Catalogo caricato in 120 ms")
    }

    func testIPv6HostsAndMultipleURLs() {
        let output = Redactor.redact("a http://[fe80::1]:7000/x/y?z=1 b https://one.test/p c")
        XCTAssertTrue(output.contains("http://[fe80::1]:7000/…"))
        XCTAssertTrue(output.contains("https://one.test/…"))
        XCTAssertFalse(output.contains("x/y"))
    }

    func testLogRingBufferLevelsAndExportRedaction() async {
        let log = DiagnosticLog(capacity: 10, minimumLevel: .info)
        for i in 0..<25 { await log.log(.info, "test", "line \(i)") }
        await log.log(.debug, "test", "hidden debug")
        await log.log(.error, "net", "failed https://x.test/secret/path?key=abc")
        let entries = await log.entries()
        XCTAssertEqual(entries.count, 10, "ring buffer keeps the newest entries")
        XCTAssertFalse(entries.contains(where: { $0.message.contains("hidden debug") }))
        let text = await log.exportText(header: ["Aether test"])
        XCTAssertTrue(text.hasPrefix("Aether test"))
        XCTAssertFalse(text.contains("secret/path"))
        XCTAssertFalse(text.contains("key=abc"))
        XCTAssertTrue(text.contains("https://x.test/…"))

        await log.configure(enabled: true, verbose: true)
        await log.log(.debug, "test", "now visible")
        let verbose = await log.entries()
        XCTAssertTrue(verbose.contains(where: { $0.message == "now visible" }))
        await log.configure(enabled: false, verbose: false)
        let disabled = await log.entries()
        XCTAssertTrue(disabled.isEmpty, "disabling logging clears the buffer")
        await log.log(.error, "test", "ignored")
        let stillEmpty = await log.entries()
        XCTAssertTrue(stillEmpty.isEmpty)
    }
}

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.appearance.theme, .system)
        XCTAssertEqual(settings.playback.skipForwardSeconds, 10)
        XCTAssertTrue(settings.playback.autoplayNextEpisode)
        XCTAssertFalse(settings.privacy.allowLocalNetwork, "local network access is opt-in")
        XCTAssertTrue(settings.privacy.recordHistory)
        XCTAssertFalse(settings.advanced.useExternalStreamingServer)
        XCTAssertEqual(settings.appearance.homeSections.map { $0.id },
                       ["hero", "continue", "nextUp", "watchlist", "catalogs"])
    }

    func testRoundTripPreservesEverything() throws {
        var settings = AppSettings()
        settings.appearance.theme = .dark
        settings.appearance.accent = .jade
        settings.appearance.posterSize = .large
        settings.playback.skipBackSeconds = 15
        settings.playback.subtitleStyle.sizePercent = 140
        settings.playback.subtitleStyle.textColor = "#FFD60A"
        settings.playback.qualityCap = .p1080
        settings.content.searchSort = .ratingDescending
        settings.casting.manualDLNAHosts = ["192.168.1.50:8080"]
        settings.privacy.allowLocalNetwork = true
        settings.appearance.homeSections[1].isVisible = false
        let data = try JSONEncoder.aether().encode(settings)
        let decoded = try JSONDecoder.aether().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    func testLenientDecodingFallsBackToDefaults() throws {
        let json = """
        {"appearance":{"theme":"neon","posterSize":"large","homeSections":[{"id":"catalogs","isVisible":false},{"id":"bogus"}]},
         "playback":{"skipForwardSeconds":9999,"skipBackSeconds":-3,"subtitleStyle":{"sizePercent":9000,"backgroundOpacity":4}},
         "unknownGroup":{"x":1},
         "privacy":"corrupted"}
        """
        let settings = try JSONDecoder.aether().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.appearance.theme, .system, "unknown enum value falls back")
        XCTAssertEqual(settings.appearance.posterSize, .large, "valid siblings are kept")
        XCTAssertEqual(settings.playback.skipForwardSeconds, 120, "values are clamped")
        XCTAssertEqual(settings.playback.skipBackSeconds, 5)
        XCTAssertEqual(settings.playback.subtitleStyle.sizePercent, 200)
        XCTAssertEqual(settings.playback.subtitleStyle.backgroundOpacity, 1)
        XCTAssertEqual(settings.privacy, PrivacySettings(), "a corrupted group resets to defaults")
        XCTAssertEqual(settings.appearance.homeSections.map { $0.id }, ["catalogs", "hero", "continue", "nextUp", "watchlist"],
                       "known sections keep their order, unknown ones vanish, missing ones are appended")
        XCTAssertEqual(settings.appearance.homeSections.first?.isVisible, false)
    }

    func testEmptyObjectYieldsDefaults() throws {
        let settings = try JSONDecoder.aether().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, AppSettings())
    }

    func testDerivedPolicies() {
        var settings = AppSettings()
        settings.privacy.recordHistory = false
        settings.playback.watchedThreshold = 0.8
        settings.privacy.allowLocalNetwork = true
        XCTAssertEqual(settings.libraryPolicy.recordHistory, false)
        XCTAssertEqual(settings.libraryPolicy.watchedThreshold, 0.8)
        XCTAssertTrue(settings.networkPolicy().allowLocalNetwork)
        XCTAssertFalse(settings.networkPolicy().allowLoopback)
        XCTAssertEqual(PosterSize.large.rowWidth, 156)
        XCTAssertEqual(VideoQualityCap.p1080.maxHeight, 1080)
    }
}

final class ResponseCacheTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    func testFreshStaleAndExpired() async {
        let clock = Clock()
        let cache = ResponseCache(directory: nil, now: { clock.now })
        await cache.store(key: "k", data: Data("v".utf8), kind: .catalog, hints: CacheHints(maxAge: 60, staleError: 120))

        var hit = await cache.lookup("k")
        XCTAssertEqual(hit?.isFresh, true)
        clock.now = clock.now.addingTimeInterval(61)
        hit = await cache.lookup("k")
        XCTAssertEqual(hit?.isFresh, false)
        XCTAssertEqual(hit?.usableAsStale, true, "within stale-if-error window")
        clock.now = clock.now.addingTimeInterval(200)
        hit = await cache.lookup("k")
        XCTAssertEqual(hit?.usableAsStale, false)
        let miss = await cache.lookup("other")
        XCTAssertNil(miss)
    }

    func testDefaultsPerKind() {
        XCTAssertEqual(CacheKind.forResource("catalog"), .catalog)
        XCTAssertEqual(CacheKind.forResource("stream"), .stream)
        XCTAssertFalse(CacheKind.stream.persistsToDisk, "stream URLs may carry tokens")
        XCTAssertTrue(CacheKind.meta.persistsToDisk)
        XCTAssertEqual(CacheKind.stream.defaultStaleError, 0)
    }

    func testDiskPersistenceDoesNotLeakTheKeyAndSurvivesRelaunch() async throws {
        let directory = try makeTempDirectory()
        let secretKey = "https://addon.test/SECRET-TOKEN/catalog/movie/top.json"
        let cache = ResponseCache(directory: directory)
        await cache.store(key: secretKey, data: Data("{\"metas\":[]}".utf8), kind: .catalog)
        let streamKey = "https://addon.test/SECRET-TOKEN/stream/movie/x.json"
        await cache.store(key: streamKey, data: Data("{}".utf8), kind: .stream)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1, "stream responses are memory-only")
        for file in files {
            XCTAssertFalse(file.lastPathComponent.contains("SECRET"))
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("SECRET-TOKEN"), "the key is stored hashed")
        }
        let reborn = ResponseCache(directory: directory)
        let hit = await reborn.lookup(secretKey)
        XCTAssertEqual(hit.map { String(decoding: $0.data, as: UTF8.self) }, "{\"metas\":[]}")
        let usage = await reborn.diskUsage()
        XCTAssertGreaterThan(usage, 0)
    }

    func testSelectiveClearAndMemoryCap() async throws {
        let directory = try makeTempDirectory()
        let cache = ResponseCache(directory: directory, maxMemoryEntries: 3)
        await cache.store(key: "c", data: Data("c".utf8), kind: .catalog)
        await cache.store(key: "m", data: Data("m".utf8), kind: .meta)
        await cache.clear(kinds: [.catalog])
        var catalog = await cache.lookup("c")
        var meta = await cache.lookup("m")
        XCTAssertNil(catalog)
        XCTAssertNotNil(meta)
        await cache.clear()
        meta = await cache.lookup("m")
        XCTAssertNil(meta)

        for i in 0..<10 { await cache.store(key: "k\(i)", data: Data("x".utf8), kind: .stream) }
        let count = await cache.memoryEntryCount
        XCTAssertEqual(count, 3, "least recently used entries are evicted")
        catalog = await cache.lookup("k0")
        XCTAssertNil(catalog)
    }

    func testAddonClientUsesCacheAndServesStaleOnFailure() async throws {
        let clock = Clock()
        let cache = ResponseCache(directory: nil, now: { clock.now })
        let server = FakeServer()
        try server.set("https://a.test/catalog/movie/top.json", fixture: "catalog_movies.json")
        let client = AddonClient(http: server, cache: cache)
        let transport = URL(string: "https://a.test/manifest.json")!
        let path = ResourcePath(resource: "catalog", type: "movie", id: "top")

        let first = try await client.fetch(transport: transport, path: path)
        XCTAssertFalse(first.isStale)
        _ = try await client.fetch(transport: transport, path: path)
        XCTAssertEqual(server.requestCount(containing: "/catalog/"), 1, "second call served from the fresh cache (cacheMaxAge 120)")

        _ = try await client.fetch(transport: transport, path: path, mode: .reload)
        XCTAssertEqual(server.requestCount(containing: "/catalog/"), 2, "reload bypasses the cache")

        clock.now = clock.now.addingTimeInterval(500)    // past maxAge (120), within default staleError (1 day)
        server.set("https://a.test/catalog/movie/top.json", error: AddonError.offline)
        let stale = try await client.fetch(transport: transport, path: path)
        XCTAssertTrue(stale.isStale, "network failure falls back to the stale copy")
        guard case .metas(let items) = stale.payload else { return XCTFail("expected metas") }
        XCTAssertEqual(items.count, 4)

        server.set("https://a.test/catalog/movie/top.json", status: 404)
        do {
            _ = try await client.fetch(transport: transport, path: path, mode: .noCache)
            XCTFail("expected notFound")
        } catch let error as AddonError {
            XCTAssertEqual(error, .notFound)
        }
    }
}
