import XCTest
@testable import AetherCore

final class AddonServiceTests: XCTestCase {
    private func installFull(_ env: TestEnvironment) async throws -> InstalledAddon {
        let addon = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        try env.server.set("https://a.test/catalog/movie/top.json", fixture: "catalog_movies.json")
        try env.server.set("https://a.test/meta/series/fx-series.json", fixture: "meta_series.json")
        try env.server.set("https://a.test/stream/movie/fx1.json", fixture: "streams_mixed.json")
        try env.server.set("https://a.test/subtitles/movie/fx1.json", fixture: "subtitles.json")
        return addon
    }

    func testPlannerListsOnlyUsableCatalogsAndTypes() async throws {
        let env = try TestEnvironment()
        let addon = try await installFull(env)
        let handles = await env.service.handles()
        let feeds = RequestPlanner.feedCatalogs(handles: handles)
        XCTAssertEqual(feeds.map { $0.catalog.key }, ["movie/top", "series/top"], "search-only catalogs are not feeds")
        XCTAssertEqual(RequestPlanner.availableTypes(handles: handles), ["movie", "series"])
        XCTAssertEqual(RequestPlanner.genreOptions(handles: handles, type: "movie"), ["Azione", "Commedia"])
        XCTAssertEqual(RequestPlanner.searchCatalogs(handles: handles).map { $0.catalog.key }, ["movie/top", "movie/search-only"])
        XCTAssertTrue(RequestPlanner.canProvideStreams(type: "movie", id: "fx1", handles: handles))
        XCTAssertFalse(RequestPlanner.canProvideStreams(type: "channel", id: "x", handles: handles))

        await env.registry.setCatalogVisible(false, catalogKey: "series/top", id: addon.id)
        let hidden = await env.service.handles()
        XCTAssertEqual(RequestPlanner.feedCatalogs(handles: hidden).map { $0.catalog.key }, ["movie/top"])
        XCTAssertEqual(RequestPlanner.availableTypes(handles: hidden), ["movie"])

        await env.registry.setEnabled(false, id: addon.id)
        let disabled = await env.service.handles()
        XCTAssertTrue(RequestPlanner.availableTypes(handles: disabled).isEmpty, "no addon, no categories")
    }

    func testLoadsACatalogThroughTheService() async throws {
        let env = try TestEnvironment()
        _ = try await installFull(env)
        let handles = await env.service.handles()
        let ref = try XCTUnwrap(RequestPlanner.feedCatalogs(handles: handles).first)
        let result = try await env.service.catalog(ref)
        XCTAssertEqual(result.items.count, 4)
        XCTAssertEqual(env.server.requestCount(containing: "/catalog/movie/top.json"), 1)
    }

    func testMetaPrefersUserOrderButMergesFasterAnswers() async throws {
        let env = try TestEnvironment()
        let metaManifest = { (id: String, name: String) -> String in
            return "{\"id\":\"\(id)\",\"version\":\"1.0.0\",\"name\":\"\(name)\",\"types\":[\"series\"],\"resources\":[{\"name\":\"meta\",\"types\":[\"series\"],\"idPrefixes\":[\"fx\"]}],\"catalogs\":[]}"
        }
        env.server.set("https://slow.test/manifest.json", json: metaManifest("slow", "Slow Primary"))
        env.server.set("https://fast.test/manifest.json", json: metaManifest("fast", "Fast Secondary"))
        _ = try await env.registry.install(input: "https://slow.test/manifest.json")
        _ = try await env.registry.install(input: "https://fast.test/manifest.json")
        try env.server.set("https://slow.test/meta/series/fx-series.json", fixture: "meta_series.json", delay: 0.3)
        env.server.set("https://fast.test/meta/series/fx-series.json",
                       json: "{\"meta\":{\"id\":\"fx-series\",\"type\":\"series\",\"name\":\"Other Name\",\"logo\":\"logo-b.png\"}}")

        let resolution = await env.service.meta(type: "series", id: "fx-series")
        XCTAssertEqual(resolution.meta.name, "Serie di Prova", "the first addon in user order wins")
        XCTAssertEqual(resolution.providerName, "Slow Primary")
        XCTAssertEqual(resolution.meta.logo, "logo-b.png", "gaps are filled from other addons that answered")
        XCTAssertEqual(resolution.meta.videos.count, 5)
        XCTAssertTrue(resolution.hadDetailProvider)
    }

    func testMetaFallsBackToNextAddonAndReportsFailures() async throws {
        let env = try TestEnvironment()
        let manifest = "{\"id\":\"ID\",\"version\":\"1.0.0\",\"name\":\"NAME\",\"types\":[\"series\"],\"resources\":[\"meta\"],\"catalogs\":[]}"
        env.server.set("https://broken.test/manifest.json", json: manifest.replacingOccurrences(of: "ID", with: "broken").replacingOccurrences(of: "NAME", with: "Broken"))
        env.server.set("https://working.test/manifest.json", json: manifest.replacingOccurrences(of: "ID", with: "working").replacingOccurrences(of: "NAME", with: "Working"))
        _ = try await env.registry.install(input: "https://broken.test/manifest.json")
        _ = try await env.registry.install(input: "https://working.test/manifest.json")
        env.server.set("https://broken.test/meta/series/s1.json", status: 500)
        env.server.set("https://working.test/meta/series/s1.json", json: "{\"meta\":{\"id\":\"s1\",\"type\":\"series\",\"name\":\"Fine\"}}")
        let resolution = await env.service.meta(type: "series", id: "s1")
        XCTAssertEqual(resolution.meta.name, "Fine")
        XCTAssertEqual(resolution.providerName, "Working")
        XCTAssertEqual(resolution.failures, [.http(status: 500)])
    }

    func testMetaWithoutAnyProviderReturnsTheCatalogPreview() async throws {
        let env = try TestEnvironment()
        _ = try await installFull(env)
        let preview = MetaItem(id: "zzz", type: "movie", name: "Solo anteprima", poster: "p.jpg")
        let resolution = await env.service.meta(type: "movie", id: "zzz", fallback: preview)
        XCTAssertFalse(resolution.hadDetailProvider)
        XCTAssertEqual(resolution.meta.name, "Solo anteprima")
        XCTAssertEqual(resolution.meta.poster, "p.jpg")
    }

    func testStreamsAggregateAcrossAddonsAndIsolateFailures() async throws {
        let env = try TestEnvironment(requestTimeout: 0.3)
        _ = try await installFull(env)
        let streamManifest = { (id: String) -> String in
            return "{\"id\":\"\(id)\",\"version\":\"1.0.0\",\"name\":\"\(id)\",\"types\":[\"movie\"],\"resources\":[\"stream\"]}"
        }
        for id in ["second", "offline", "slow", "empty"] {
            env.server.set("https://\(id).test/manifest.json", json: streamManifest(id))
            _ = try await env.registry.install(input: "https://\(id).test/manifest.json")
        }
        try env.server.set("https://second.test/stream/movie/fx1.json", fixture: "streams_mixed.json")
        env.server.set("https://offline.test/stream/movie/fx1.json", error: AddonError.unreachable("offline.test"))
        env.server.set("https://slow.test/stream/movie/fx1.json", json: "{\"streams\":[]}", delay: 20)
        // "empty" has no route at all -> 404 -> "no streams", not an error.

        let started = Date()
        let result = await env.service.allStreams(type: "movie", videoID: "fx1")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a slow addon must not block the others beyond its deadline")
        XCTAssertEqual(result.streams.count, 20, "10 from each healthy addon, kept apart by addon")
        XCTAssertEqual(Set(result.streams.compactMap { $0.addonName }), ["Fixture Full", "second"])
        XCTAssertEqual(result.errors["offline"], .unreachable("offline.test"))
        XCTAssertEqual(result.errors["slow"], .timeout)
        XCTAssertNil(result.errors["empty"], "404 means no streams")
    }

    func testStreamsStopWhenTheConsumerCancels() async throws {
        let env = try TestEnvironment(requestTimeout: 30)
        let manifest = "{\"id\":\"slow\",\"version\":\"1.0.0\",\"name\":\"slow\",\"types\":[\"movie\"],\"resources\":[\"stream\"]}"
        env.server.set("https://slow.test/manifest.json", json: manifest)
        _ = try await env.registry.install(input: "https://slow.test/manifest.json")
        env.server.set("https://slow.test/stream/movie/x.json", json: "{\"streams\":[]}", delay: 30)

        let service = env.service
        let task = Task { () -> Int in
            var batches = 0
            for await _ in service.streams(type: "movie", videoID: "x") { batches += 1 }
            return batches
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        let started = Date()
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "cancelling must abort outstanding requests")
    }

    func testSubtitlesAreCollectedAndAnnotated() async throws {
        let env = try TestEnvironment()
        _ = try await installFull(env)
        let subs = await env.service.subtitles(type: "movie", videoID: "fx1")
        XCTAssertEqual(subs.count, 3)
        XCTAssertEqual(subs.first?.addonName, "Fixture Full")
    }

    func testSubtitleRequestCarriesVideoHashSizeAndFilename() async throws {
        let env = try TestEnvironment()
        _ = try await installFull(env)
        _ = await env.service.subtitles(type: "movie", videoID: "fx1", videoHash: "abc123", videoSize: 1000, filename: "a b.mkv")
        let urls = env.server.requests.map { $0.url.absoluteString }
        XCTAssertTrue(urls.contains("https://a.test/subtitles/movie/fx1/videoHash=abc123&videoSize=1000&filename=a%20b.mkv.json"), "\(urls)")
    }

    func testHealthIsRecordedAndCleared() async throws {
        let env = try TestEnvironment()
        let addon = try await installFull(env)
        let handles = await env.service.handles()
        let ref = try XCTUnwrap(RequestPlanner.feedCatalogs(handles: handles).first)
        env.server.set("https://a.test/catalog/movie/top.json", status: 500)
        do {
            _ = try await env.service.catalog(ref)
            XCTFail("expected failure")
        } catch {}
        var current = await env.registry.addon(id: addon.id)
        XCTAssertNotNil(current?.lastError)
        try env.server.set("https://a.test/catalog/movie/top.json", fixture: "catalog_movies.json")
        _ = try await env.service.catalog(ref)
        current = await env.registry.addon(id: addon.id)
        XCTAssertNil(current?.lastError)
    }

    func testConcurrencyLimiterNeverExceedsItsLimit() async throws {
        actor Counter {
            var current = 0
            var peak = 0
            func enter() { current += 1; peak = max(peak, current) }
            func leave() { current -= 1 }
        }
        let limiter = ConcurrencyLimiter(limit: 3)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try? await limiter.withPermit {
                        await counter.enter()
                        try await Task.sleep(nanoseconds: 20_000_000)
                        await counter.leave()
                    }
                }
            }
        }
        let peak = await counter.peak
        let active = await limiter.activeCount
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "work should actually run in parallel")
        XCTAssertEqual(active, 0)
    }
}

final class CatalogPagerTests: XCTestCase {
    private func setup(skipSupported: Bool = true) async throws -> (TestEnvironment, CatalogRef) {
        let env = try TestEnvironment()
        let extra = skipSupported ? "[{\"name\":\"skip\"},{\"name\":\"genre\",\"options\":[\"A\"]}]" : "[]"
        let manifest = "{\"id\":\"pg\",\"version\":\"1.0.0\",\"name\":\"Pager\",\"types\":[\"movie\"],\"resources\":[\"catalog\"],\"catalogs\":[{\"type\":\"movie\",\"id\":\"c\",\"name\":\"C\",\"extra\":\(extra)}]}"
        env.server.set("https://pg.test/manifest.json", json: manifest)
        _ = try await env.registry.install(input: "https://pg.test/manifest.json")
        let handles = await env.service.handles()
        return (env, try XCTUnwrap(RequestPlanner.feedCatalogs(handles: handles).first))
    }

    private func page(_ ids: [Int]) -> String {
        let metas = ids.map { "{\"id\":\"m\($0)\",\"type\":\"movie\",\"name\":\"M\($0)\"}" }.joined(separator: ",")
        return "{\"metas\":[\(metas)]}"
    }

    func testPaginatesWithSkipAndStopsOnEmptyPage() async throws {
        let (env, ref) = try await setup()
        env.server.set("https://pg.test/catalog/movie/c.json", json: page([1, 2, 3]))
        env.server.set("https://pg.test/catalog/movie/c/skip=3.json", json: page([4, 5]))
        env.server.set("https://pg.test/catalog/movie/c/skip=5.json", json: page([]))
        let pager = CatalogPager(ref: ref, service: env.service)

        let first = try await pager.loadNext()
        XCTAssertEqual(first.newItems.map { $0.id }, ["m1", "m2", "m3"])
        XCTAssertTrue(first.hasMore)
        let second = try await pager.loadNext()
        XCTAssertEqual(second.newItems.map { $0.id }, ["m4", "m5"])
        XCTAssertTrue(second.hasMore)
        let third = try await pager.loadNext()
        XCTAssertTrue(third.newItems.isEmpty)
        XCTAssertFalse(third.hasMore)
        let fourth = try await pager.loadNext()
        XCTAssertTrue(fourth.newItems.isEmpty)
        let items = await pager.items
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(env.server.requestCount(containing: "skip=5"), 1)
        XCTAssertEqual(env.server.requests.filter { $0.url.absoluteString.contains("/catalog/") }.count, 3, "no request after the end")
    }

    func testAddonsThatIgnoreSkipDoNotLoopForever() async throws {
        let (env, ref) = try await setup()
        env.server.set("https://pg.test/catalog/movie/c.json", json: page([1, 2]))
        env.server.set("https://pg.test/catalog/movie/c/skip=2.json", json: page([1, 2]))
        let pager = CatalogPager(ref: ref, service: env.service)
        _ = try await pager.loadNext()
        let second = try await pager.loadNext()
        XCTAssertTrue(second.newItems.isEmpty)
        XCTAssertFalse(second.hasMore)
    }

    func testCatalogsWithoutSkipHaveASinglePage() async throws {
        let (env, ref) = try await setup(skipSupported: false)
        env.server.set("https://pg.test/catalog/movie/c.json", json: page([1, 2, 3]))
        let pager = CatalogPager(ref: ref, service: env.service)
        let first = try await pager.loadNext()
        XCTAssertEqual(first.newItems.count, 3)
        XCTAssertFalse(first.hasMore)
    }

    func testFiltersAreSentAndResetStartsOver() async throws {
        let (env, ref) = try await setup()
        env.server.set("https://pg.test/catalog/movie/c/genre=A.json", json: page([7, 8]))
        env.server.set("https://pg.test/catalog/movie/c/genre=A&skip=2.json", json: page([9]))
        let pager = CatalogPager(ref: ref, service: env.service, extra: [ExtraValue(name: "genre", value: "A")])
        let first = try await pager.loadNext()
        XCTAssertEqual(first.newItems.map { $0.id }, ["m7", "m8"])
        let second = try await pager.loadNext()
        XCTAssertEqual(second.newItems.map { $0.id }, ["m9"])

        env.server.set("https://pg.test/catalog/movie/c.json", json: page([1]))
        await pager.reset(extra: [])
        let afterReset = try await pager.loadNext()
        XCTAssertEqual(afterReset.newItems.map { $0.id }, ["m1"])
    }

    func testFailuresSurfaceAndCanBeRetried() async throws {
        let (env, ref) = try await setup()
        env.server.set("https://pg.test/catalog/movie/c.json", status: 500)
        let pager = CatalogPager(ref: ref, service: env.service)
        do {
            _ = try await pager.loadNext(mode: .reload)
            XCTFail("expected failure")
        } catch {}
        env.server.set("https://pg.test/catalog/movie/c.json", json: page([1]))
        let retry = try await pager.loadNext(mode: .reload)
        XCTAssertEqual(retry.newItems.count, 1)
    }
}

final class SearchServiceTests: XCTestCase {
    private func setup() async throws -> (TestEnvironment, SearchService) {
        let env = try TestEnvironment()
        _ = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        _ = try await env.install(manifestFixture: "manifest_legacy_extra.json", at: "https://legacy.test/manifest.json")
        _ = try await env.install(manifestFixture: "manifest_minimal_short.json", at: "https://nosearch.test/manifest.json")
        return (env, SearchService(service: env.service))
    }

    func testOnlyCatalogsDeclaringSearchAreQueried() async throws {
        let (env, search) = try await setup()
        let catalogs = await search.searchableCatalogs()
        XCTAssertEqual(catalogs.map { "\($0.addonName):\($0.catalog.key)" },
                       ["Fixture Full:movie/top", "Fixture Full:movie/search-only", "Legacy Extra:movie/l"])
        _ = env
    }

    func testSearchStreamsOneRowPerCatalogAndIsolatesErrors() async throws {
        let (env, search) = try await setup()
        try env.server.set("https://a.test/catalog/movie/top/search=big%20buck.json", fixture: "catalog_movies.json")
        env.server.set("https://a.test/catalog/movie/search-only/search=big%20buck.json", json: "{\"metas\":[{\"id\":\"x1\",\"type\":\"movie\",\"name\":\"Big Buck Bunny\",\"releaseInfo\":\"2008\"}]}")
        env.server.set("https://legacy.test/catalog/movie/l/search=big%20buck.json", status: 500)

        var rows: [SearchRow] = []
        var lastProgress = 0
        for await update in search.search(query: "  big   buck ") {
            rows.append(update.row)
            XCTAssertEqual(update.total, 3)
            lastProgress = update.completed
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(lastProgress, 3)
        XCTAssertEqual(rows.filter { $0.error != nil }.count, 1)
        let top = try XCTUnwrap(rows.first(where: { $0.ref.catalog.id == "top" }))
        XCTAssertEqual(top.items.count, 4)
    }

    func testEmptyQueryProducesNoRequests() async throws {
        let (env, search) = try await setup()
        var count = 0
        for await _ in search.search(query: "   ") { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(env.server.requestCount(containing: "/catalog/"), 0)
    }

    func testNormalisationAndDeduplicationAcrossIdSchemes() {
        XCTAssertEqual(SearchService.normalisedQuery("  a   b\tc "), "a b c")
        XCTAssertEqual(MetaDeduper.normalise("Amélie: Le Fabuleux Destin!"), "amelie le fabuleux destin")

        let imdb = MetaItem(id: "tt0000001", type: "movie", name: "Big Buck Bunny", releaseInfo: "2008")
        let kitsuLike = MetaItem(id: "other:77", type: "movie", name: "BIG BUCK BUNNY", poster: "p.jpg", releaseInfo: "2008")
        let differentYear = MetaItem(id: "other:78", type: "movie", name: "Big Buck Bunny", releaseInfo: "2024")
        let sameImdb = MetaItem(id: "tt0000001", type: "movie", name: "Renamed", background: "bg.jpg")
        let merged = MetaDeduper.dedupe([imdb, kitsuLike, differentYear, sameImdb])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].id, "tt0000001", "the first occurrence wins")
        XCTAssertEqual(merged[0].background, "bg.jpg", "gaps are filled from duplicates")
        XCTAssertEqual(merged[0].poster, "p.jpg", "an item with another id scheme merges by title+year")
        XCTAssertEqual(merged[1].id, "other:78", "same title with another year is a different work")

        let remakeA = MetaItem(id: "tt0000010", type: "movie", name: "Same Title", releaseInfo: "2001")
        let remakeB = MetaItem(id: "tt0000011", type: "movie", name: "Same Title", releaseInfo: "2001")
        XCTAssertEqual(MetaDeduper.dedupe([remakeA, remakeB]).count, 2, "different IMDb ids are never merged")
    }

    func testInterleaveBalancesSourcesAndSortingOptions() {
        let rowA = (1...3).map { MetaItem(id: "a\($0)", type: "movie", name: "A\($0)", releaseInfo: "200\($0)", imdbRating: "\($0).0") }
        let rowB = (1...2).map { MetaItem(id: "b\($0)", type: "movie", name: "B\($0)", releaseInfo: "201\($0)", imdbRating: "9.\($0)") }
        let merged = MetaDeduper.interleave([rowA, rowB])
        XCTAssertEqual(merged.map { $0.id }, ["a1", "b1", "a2", "b2", "a3"])
        XCTAssertEqual(SearchSort.title.apply(to: merged).first?.id, "a1")
        XCTAssertEqual(SearchSort.yearDescending.apply(to: merged).first?.id, "b2")
        XCTAssertEqual(SearchSort.ratingDescending.apply(to: merged).first?.id, "b2")
        XCTAssertEqual(SearchSort.relevance.apply(to: merged).map { $0.id }, merged.map { $0.id })
    }
}
