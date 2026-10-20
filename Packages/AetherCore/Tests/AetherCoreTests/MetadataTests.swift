import XCTest
@testable import AetherCore

// MARK: - Test doubles

/// Scripted TMDB / TheTVDB. A route matches on method + path suffix (+ optional query fragment) and replays its replies in
/// order, the last one repeating. The first matching route wins. Unknown routes answer 404.
private final class MetaStubHTTP: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: String = "{}"
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
    }

    private struct Route {
        let method: String
        let pathSuffix: String
        let queryFragment: String?
        let replies: [Reply]
        var served: Int
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var seen: [HTTPRequest] = []

    func on(_ method: String = "GET", _ pathSuffix: String, query: String? = nil, _ replies: Reply...) {
        lock.lock()
        defer { lock.unlock() }
        routes.append(Route(method: method, pathSuffix: pathSuffix, queryFragment: query, replies: replies, served: 0))
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func count(pathSuffix: String) -> Int {
        return requests.filter { $0.url.path.hasSuffix(pathSuffix) }.count
    }

    private func next(for request: HTTPRequest) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        let path = request.url.path
        let query = request.url.query ?? ""
        for index in routes.indices {
            let route = routes[index]
            if route.method != request.method { continue }
            if !path.hasSuffix(route.pathSuffix) { continue }
            if let fragment = route.queryFragment, !query.contains(fragment) { continue }
            let position = min(route.served, route.replies.count - 1)
            routes[index].served += 1
            return route.replies[position]
        }
        return Reply(status: 404, body: "{}")
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply = next(for: request)
        if reply.delay > 0 { try await Task.sleep(nanoseconds: UInt64(reply.delay * 1_000_000_000)) }
        return HTTPResponse(data: Data(reply.body.utf8), statusCode: reply.status, headers: reply.headers, url: request.url)
    }
}

private final class MetaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private enum MetaFixtures {
    static let v3Key = "0123456789abcdef0123456789abcdef"
    static let v4Token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl"
    static let tvdbKey = "11111111-2222-3333-4444-555555555555"
    static let tvdbPIN = "ABCDEF"

    static let configuration = """
    {"images":{"secure_base_url":"https://image.tmdb.org/t/p/","poster_sizes":["w92","w342","w500","w780","original"],
    "backdrop_sizes":["w300","w780","w1280","original"],"logo_sizes":["w45","w185","w300","w500","original"],
    "still_sizes":["w92","w185","w300","original"]}}
    """

    static let findMovie = #"{"movie_results":[{"id":603}],"tv_results":[]}"#
    static let findTV = #"{"movie_results":[],"tv_results":[{"id":1399}]}"#
    static let findNothing = #"{"movie_results":[],"tv_results":[]}"#

    static let movie = """
    {"id":603,"title":"Matrix","overview":"Trama in italiano","tagline":"Benvenuto","poster_path":"/p.jpg","backdrop_path":"/b.jpg",
    "genres":[{"id":1,"name":"Azione"},{"id":2,"name":"Fantascienza"}],"runtime":136,"release_date":"1999-03-30","vote_average":8.2,
    "credits":{"cast":[{"name":"Secondo","order":1},{"name":"Primo","order":0},{"name":"","order":2}],
    "crew":[{"name":"Lana","job":"Director"},{"name":"Lana","job":"Director"},{"name":"Altro","job":"Producer"}]},
    "images":{"logos":[{"file_path":"/l_en.png","iso_639_1":"en","vote_average":5},{"file_path":"/l_it.png","iso_639_1":"it","vote_average":1},
    {"file_path":"/l_vector.svg","iso_639_1":"it","vote_average":9}]},
    "external_ids":{"imdb_id":"tt0133093"}}
    """

    static let show = """
    {"id":1399,"name":"Il Trono","overview":"Trama serie","episode_run_time":[57],"first_air_date":"2011-04-17",
    "genres":[{"id":1,"name":"Dramma"}],"poster_path":"/sp.jpg","external_ids":{"imdb_id":"tt0944947","tvdb_id":121361}}
    """

    static let season1 = """
    {"episodes":[{"episode_number":1,"season_number":1,"name":"L'inverno sta arrivando","overview":"Trama episodio 1","still_path":"/s1.jpg"},
    {"episode_number":2,"season_number":1,"name":"Titolo TMDB 2","overview":"Altra trama","still_path":"/s2.jpg"}]}
    """

    static let tvdbLogin = #"{"status":"success","data":{"token":"tvdb-session-token"}}"#
    static let tvdbRemote = #"{"status":"success","data":[{"series":{"id":121361}}]}"#
    static let tvdbEpisodes = """
    {"status":"success","data":{"episodes":[{"seasonNumber":1,"number":1,"name":"Titolo TVDB","overview":"Trama TVDB",
    "image":"https://artworks.thetvdb.com/e1.jpg"},{"seasonNumber":1,"number":2,"name":"Altro titolo"}]},"links":{"next":null}}
    """

    static func movieMeta(id: String = "tt0133093", poster: String? = nil, description: String? = nil) -> MetaItem {
        return MetaItem(id: id, type: "movie", name: "The Matrix", poster: poster, description: description)
    }

    static func seriesMeta() -> MetaItem {
        let placeholder = Video(id: "tt0944947:1:1", title: "Episode 1", season: 1, episode: 1)
        let complete = Video(id: "tt0944947:1:2", title: "Titolo dell'addon", season: 1, episode: 2,
                             thumbnail: "https://addon.example/e2.jpg", overview: "Trama dell'addon")
        return MetaItem(id: "tt0944947", type: "series", name: "Game of Thrones", videos: [placeholder, complete])
    }

    static func tmdbMovieRoutes(_ http: MetaStubHTTP) {
        http.on("GET", "/configuration", .init(body: configuration))
        http.on("GET", "/find/tt0133093", .init(body: findMovie))
        http.on("GET", "/movie/603", .init(body: movie))
    }

    static func tmdbShowRoutes(_ http: MetaStubHTTP) {
        http.on("GET", "/configuration", .init(body: configuration))
        http.on("GET", "/find/tt0944947", .init(body: findTV))
        http.on("GET", "/tv/1399", .init(body: show))
        http.on("GET", "/tv/1399/season/1", .init(body: season1))
    }

    static func tvdbRoutes(_ http: MetaStubHTTP) {
        http.on("POST", "/login", .init(body: tvdbLogin))
        http.on("GET", "/search/remoteid/tt0944947", .init(body: tvdbRemote))
        http.on("GET", "/series/121361/episodes/default/ita", .init(body: tvdbEpisodes))
    }

    static func tmdbClient(_ http: HTTPClient, key: String? = v3Key, baseURL: URL = TMDBClient.productionBaseURL) -> TMDBClient {
        return TMDBClient(http: http, credentials: { key }, baseURL: baseURL)
    }

    static func tvdbClient(_ http: HTTPClient, key: String? = tvdbKey, pin: String? = nil) -> TVDBClient {
        return TVDBClient(http: http, apiKey: { key }, pin: { pin })
    }
}

// MARK: - Tests

final class MetadataTests: XCTestCase {
    // MARK: Credentials and hosts

    func testCredentialKindIsRecognisedFromItsShape() {
        XCTAssertEqual(TMDBClient.classify(MetaFixtures.v4Token), .bearer(MetaFixtures.v4Token))
        XCTAssertEqual(TMDBClient.classify("  \(MetaFixtures.v3Key)\n"), .apiKey(MetaFixtures.v3Key))
        XCTAssertNil(TMDBClient.classify("   "))
        XCTAssertNil(TMDBClient.classify("key with\u{7}control"))
        XCTAssertNil(TMDBClient.classify(String(repeating: "a", count: 3000)))
    }

    func testOnlyTheProductionHostsAndLocalFixturesAreTrusted() {
        XCTAssertTrue(MetadataHTTP.isTrusted(URL(string: "https://api.themoviedb.org/3")!, productionHost: "api.themoviedb.org"))
        XCTAssertFalse(MetadataHTTP.isTrusted(URL(string: "http://api.themoviedb.org/3")!, productionHost: "api.themoviedb.org"))
        XCTAssertFalse(MetadataHTTP.isTrusted(URL(string: "https://api.themoviedb.org.evil.example/3")!, productionHost: "api.themoviedb.org"))
        XCTAssertFalse(MetadataHTTP.isTrusted(URL(string: "https://evil.example/3")!, productionHost: "api.themoviedb.org"))
        XCTAssertFalse(MetadataHTTP.isTrusted(URL(string: "http://8.8.8.8/3")!, productionHost: "api.themoviedb.org"))
        XCTAssertTrue(MetadataHTTP.isTrusted(URL(string: "http://127.0.0.1:8099/3")!, productionHost: "api.themoviedb.org"))
        XCTAssertTrue(MetadataHTTP.isTrusted(URL(string: "http://192.168.1.20:8099/3")!, productionHost: "api.themoviedb.org"))
    }

    func testAKeyIsNeverSentToAnUntrustedHost() async {
        let http = MetaStubHTTP()
        let tmdb = MetaFixtures.tmdbClient(http, baseURL: URL(string: "https://evil.example/3")!)
        let tvdb = TVDBClient(http: http, apiKey: { MetaFixtures.tvdbKey }, baseURL: URL(string: "https://evil.example/v4")!)
        let first = await tmdb.check()
        let second = await tvdb.check()
        XCTAssertEqual(first, .failed(.untrustedHost))
        XCTAssertEqual(second, .failed(.untrustedHost))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testV4TokenGoesInTheAuthorizationHeaderAndV3KeyInTheQuery() async {
        let bearerHTTP = MetaStubHTTP()
        bearerHTTP.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        let bearer = await MetaFixtures.tmdbClient(bearerHTTP, key: MetaFixtures.v4Token).check()
        XCTAssertEqual(bearer, .ok)
        XCTAssertEqual(bearerHTTP.requests.first?.headers["Authorization"], "Bearer \(MetaFixtures.v4Token)")
        XCTAssertFalse(bearerHTTP.requests.first?.url.absoluteString.contains("api_key") ?? true)

        let keyHTTP = MetaStubHTTP()
        keyHTTP.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        let keyed = await MetaFixtures.tmdbClient(keyHTTP, key: MetaFixtures.v3Key).check()
        XCTAssertEqual(keyed, .ok)
        XCTAssertNil(keyHTTP.requests.first?.headers["Authorization"])
        XCTAssertTrue(keyHTTP.requests.first?.url.query?.contains("api_key=\(MetaFixtures.v3Key)") ?? false)
    }

    func testTMDBRejectsAnInvalidKeyWithItsStatusCode() async {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(status: 401, body: #"{"status_code":7,"status_message":"Invalid API key: You must be granted a valid key.","success":false}"#))
        let result = await MetaFixtures.tmdbClient(http).check()
        XCTAssertEqual(result, .failed(.invalidCredentials))
    }

    func testAMissingKeyIsNotConfiguredAndMakesNoRequest() async {
        let http = MetaStubHTTP()
        let tmdb = MetaFixtures.tmdbClient(http, key: nil)
        XCTAssertFalse(tmdb.isConfigured)
        let result = await tmdb.check()
        XCTAssertEqual(result, .failed(.notConfigured))
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertFalse(MetaFixtures.tvdbClient(http, key: "  ").isConfigured)
        XCTAssertTrue(MetaFixtures.tvdbClient(http).isConfigured)
    }

    func testNoKeyAppearsInAnErrorOrItsText() async {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(status: 403, body: "{\"error\":\"\(MetaFixtures.v3Key)\"}"))
        http.on("POST", "/login", .init(status: 401, body: "{\"status\":\"failure\",\"message\":\"InvalidAPIKey: \(MetaFixtures.tvdbKey)\"}"))
        let tmdb = await MetaFixtures.tmdbClient(http).check()
        let tvdb = await MetaFixtures.tvdbClient(http, pin: MetaFixtures.tvdbPIN).check()
        for result in [tmdb, tvdb] {
            guard case .failed(let error) = result else { return XCTFail("expected a failure") }
            let text = String(describing: result) + error.message + String(describing: error)
            XCTAssertFalse(text.contains(MetaFixtures.v3Key))
            XCTAssertFalse(text.contains(MetaFixtures.tvdbKey))
            XCTAssertFalse(text.contains(MetaFixtures.tvdbPIN))
        }
    }

    // MARK: TheTVDB

    func testTVDBLogsInWithKeyAndPINAndReusesTheToken() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tvdbRoutes(http)
        let client = MetaFixtures.tvdbClient(http, pin: MetaFixtures.tvdbPIN)
        let first = try await client.seriesID(forIMDbID: "tt0944947")
        let second = try await client.episodes(seriesID: 121361, language: "ita")
        XCTAssertEqual(first, 121361)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(http.count(pathSuffix: "/login"), 1)
        let login = try XCTUnwrap(http.requests.first(where: { $0.url.path.hasSuffix("/login") }))
        let body = try XCTUnwrap(login.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains(MetaFixtures.tvdbKey))
        XCTAssertTrue(body.contains(MetaFixtures.tvdbPIN))
        let data = try XCTUnwrap(http.requests.last)
        XCTAssertEqual(data.headers["Authorization"], "Bearer tvdb-session-token")
    }

    func testTVDBRejectsAnInvalidKey() async {
        let http = MetaStubHTTP()
        http.on("POST", "/login", .init(status: 401, body: #"{"status":"failure","message":"InvalidAPIKey: Invalid API key","data":null}"#))
        let result = await MetaFixtures.tvdbClient(http).check()
        XCTAssertEqual(result, .failed(.invalidCredentials))
    }

    func testTVDBLogsInAgainOnceWhenTheTokenExpires() async throws {
        let http = MetaStubHTTP()
        http.on("POST", "/login", .init(body: MetaFixtures.tvdbLogin))
        http.on("GET", "/search/remoteid/tt0944947", .init(status: 401, body: #"{"status":"failure","message":"Unauthorized"}"#), .init(body: MetaFixtures.tvdbRemote))
        let client = MetaFixtures.tvdbClient(http)
        let id = try await client.seriesID(forIMDbID: "tt0944947")
        XCTAssertEqual(id, 121361)
        XCTAssertEqual(http.count(pathSuffix: "/login"), 2)
        XCTAssertEqual(http.count(pathSuffix: "/search/remoteid/tt0944947"), 2)
    }

    func testTVDBStopsAfterOneRetryWhenTheTokenKeepsBeingRefused() async {
        let http = MetaStubHTTP()
        http.on("POST", "/login", .init(body: MetaFixtures.tvdbLogin))
        http.on("GET", "/search/remoteid/tt0944947", .init(status: 401, body: "{}"))
        do {
            _ = try await MetaFixtures.tvdbClient(http).seriesID(forIMDbID: "tt0944947")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MetadataError, .invalidCredentials)
        }
        XCTAssertEqual(http.count(pathSuffix: "/search/remoteid/tt0944947"), 2)
    }

    // MARK: Enrichment: movies

    func testMovieIsEnrichedFromTMDBByItsIMDbID() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbMovieRoutes(http)
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil)
        let result = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        let enrichment = try XCTUnwrap(result)

        XCTAssertEqual(enrichment.sources, [.tmdb])
        XCTAssertEqual(enrichment.ids, ExternalIDs(imdb: "tt0133093", tmdb: 603, tvdb: nil))
        XCTAssertEqual(enrichment.overview, "Trama in italiano")
        XCTAssertEqual(enrichment.tagline, "Benvenuto")
        XCTAssertEqual(enrichment.poster, "https://image.tmdb.org/t/p/w500/p.jpg")
        XCTAssertEqual(enrichment.backdrop, "https://image.tmdb.org/t/p/w1280/b.jpg")
        XCTAssertEqual(enrichment.logo, "https://image.tmdb.org/t/p/w500/l_it.png")
        XCTAssertEqual(enrichment.genres, ["Azione", "Fantascienza"])
        XCTAssertEqual(enrichment.cast, ["Primo", "Secondo"])
        XCTAssertEqual(enrichment.directors, ["Lana"])
        XCTAssertEqual(enrichment.runtimeMinutes, 136)
        XCTAssertEqual(enrichment.year, "1999")
        XCTAssertEqual(http.count(pathSuffix: "/find/tt0133093"), 1)
        XCTAssertEqual(http.requests.first(where: { $0.url.path.hasSuffix("/movie/603") })?.url.query?.contains("language=it-IT"), true)
    }

    func testKnownTMDBIDSkipsTheLookup() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbMovieRoutes(http)
        var meta = MetaFixtures.movieMeta()
        meta.externalIDs = ExternalIDs(imdb: "tt0133093", tmdb: 603, tvdb: nil)
        let result = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(meta, language: "it-IT")
        XCTAssertNotNil(result)
        XCTAssertEqual(http.count(pathSuffix: "/find/tt0133093"), 0)
        XCTAssertEqual(http.count(pathSuffix: "/movie/603"), 1)
    }

    func testMergingNeverOverwritesWhatTheAddonProvided() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbMovieRoutes(http)
        let meta = MetaFixtures.movieMeta(poster: "https://addon.example/poster.jpg", description: "Trama dell'addon")
        let enrichmentResult = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(meta, language: "it-IT")
        let enrichment = try XCTUnwrap(enrichmentResult)
        let merged = meta.merging(enrichment: enrichment)

        XCTAssertEqual(merged.poster, "https://addon.example/poster.jpg")
        XCTAssertEqual(merged.description, "Trama dell'addon")
        XCTAssertEqual(merged.id, meta.id)
        XCTAssertEqual(merged.name, meta.name)
        // The gaps are filled.
        XCTAssertEqual(merged.background, "https://image.tmdb.org/t/p/w1280/b.jpg")
        XCTAssertEqual(merged.logo, "https://image.tmdb.org/t/p/w500/l_it.png")
        XCTAssertEqual(merged.genres, ["Azione", "Fantascienza"])
        XCTAssertEqual(merged.cast, ["Primo", "Secondo"])
        XCTAssertEqual(merged.runtime, "136 min")
        XCTAssertEqual(merged.releaseInfo, "1999")
        XCTAssertEqual(merged.externalIDs.tmdb, 603)
        // TMDB's average is not an IMDb rating and is never put in that field.
        XCTAssertNil(merged.imdbRating)
    }

    func testAnAddonValueIsNotReplacedEvenWhenItIsShorter() {
        var meta = MetaFixtures.movieMeta(description: "x")
        meta.genres = ["Horror"]
        let enrichment = MetadataEnrichment(overview: "Una trama molto più lunga e dettagliata", genres: ["Azione"], sources: [.tmdb])
        let merged = meta.merging(enrichment: enrichment)
        XCTAssertEqual(merged.description, "x")
        XCTAssertEqual(merged.genres, ["Horror"])
    }

    func testAttributionOnlyAppearsWhenSomethingWasAdded() {
        let full = MetaItem(id: "tt1", type: "movie", name: "X", poster: "p", background: "b", logo: "l", description: "d",
                            releaseInfo: "2000", runtime: "90 min", genres: ["a"], cast: ["c"], directors: ["d"])
        let enrichment = MetadataEnrichment(ids: ExternalIDs(imdb: "tt1", tmdb: 5, tvdb: nil), poster: "other", overview: "other",
                                            genres: ["z"], sources: [.tmdb])
        XCTAssertEqual(enrichment.creditLines(whenMergedInto: full), [])
        let sparse = MetaItem(id: "tt1", type: "movie", name: "X")
        XCTAssertEqual(enrichment.creditLines(whenMergedInto: sparse), [MetadataService.tmdb.attribution])
        XCTAssertTrue(MetadataService.tmdb.attribution.contains("not endorsed or certified by TMDB"))
    }

    // MARK: Enrichment: series

    func testPlaceholderEpisodesAreFilledFromTMDBSeasons() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbShowRoutes(http)
        let meta = MetaFixtures.seriesMeta()
        let enrichmentResult = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(meta, language: "it-IT")
        let enrichment = try XCTUnwrap(enrichmentResult)
        let merged = meta.merging(enrichment: enrichment)

        let first = try XCTUnwrap(merged.videos.first(where: { $0.episode == 1 }))
        XCTAssertEqual(first.title, "L'inverno sta arrivando")
        XCTAssertEqual(first.overview, "Trama episodio 1")
        XCTAssertEqual(first.thumbnail, "https://image.tmdb.org/t/p/w300/s1.jpg")
        let second = try XCTUnwrap(merged.videos.first(where: { $0.episode == 2 }))
        XCTAssertEqual(second.title, "Titolo dell'addon")
        XCTAssertEqual(second.overview, "Trama dell'addon")
        XCTAssertEqual(second.thumbnail, "https://addon.example/e2.jpg")
        XCTAssertEqual(merged.runtime, "57 min")
        XCTAssertEqual(merged.externalIDs, ExternalIDs(imdb: "tt0944947", tmdb: 1399, tvdb: 121361))
        XCTAssertEqual(http.count(pathSuffix: "/tv/1399/season/1"), 1)
    }

    func testSeasonsAreNotRequestedWhenTheAddonHasEverythingForTheEpisodes() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbShowRoutes(http)
        let complete = Video(id: "tt0944947:1:1", title: "Pilot", season: 1, episode: 1, thumbnail: "https://a.example/1.jpg", overview: "Trama")
        let meta = MetaItem(id: "tt0944947", type: "series", name: "Show", videos: [complete])
        _ = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(meta, language: "it-IT")
        XCTAssertEqual(http.count(pathSuffix: "/tv/1399/season/1"), 0)
        XCTAssertEqual(http.count(pathSuffix: "/tv/1399"), 1)
    }

    func testTVDBFillsEpisodesThatTMDBDoesNotKnow() async throws {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        http.on("GET", "/find/tt0944947", .init(body: MetaFixtures.findNothing))
        MetaFixtures.tvdbRoutes(http)
        let meta = MetaFixtures.seriesMeta()
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: MetaFixtures.tvdbClient(http))
        let enrichmentResult = await enricher.enrich(meta, language: "it-IT")
        let enrichment = try XCTUnwrap(enrichmentResult)
        XCTAssertEqual(enrichment.sources, [.tvdb])

        let merged = meta.merging(enrichment: enrichment)
        let first = try XCTUnwrap(merged.videos.first(where: { $0.episode == 1 }))
        XCTAssertEqual(first.title, "Titolo TVDB")
        XCTAssertEqual(first.overview, "Trama TVDB")
        XCTAssertEqual(first.thumbnail, "https://artworks.thetvdb.com/e1.jpg")
        // Episode 2 was complete in the addon: not asked for, not touched.
        let second = try XCTUnwrap(merged.videos.first(where: { $0.episode == 2 }))
        XCTAssertEqual(second.title, "Titolo dell'addon")
    }

    func testTVDBIsNotAskedWhenTMDBAlreadyCoversTheEpisodes() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbShowRoutes(http)
        MetaFixtures.tvdbRoutes(http)
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: MetaFixtures.tvdbClient(http))
        let enrichmentResult = await enricher.enrich(MetaFixtures.seriesMeta(), language: "it-IT")
        let enrichment = try XCTUnwrap(enrichmentResult)
        XCTAssertEqual(enrichment.sources, [.tmdb])
        XCTAssertEqual(http.count(pathSuffix: "/login"), 0)
    }

    func testTVDBAloneWorksWithoutATMDBKey() async throws {
        let http = MetaStubHTTP()
        MetaFixtures.tvdbRoutes(http)
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http, key: nil), tvdb: MetaFixtures.tvdbClient(http))
        let enrichmentResult = await enricher.enrich(MetaFixtures.seriesMeta(), language: "it")
        let enrichment = try XCTUnwrap(enrichmentResult)
        XCTAssertEqual(enrichment.sources, [.tvdb])
        XCTAssertTrue(http.requests.allSatisfy { !($0.url.host ?? "").contains("themoviedb") })
    }

    // MARK: Enrichment: guards

    func testUnsupportedTypesAndUnknownIDsMakeNoRequest() async {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbMovieRoutes(http)
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: MetaFixtures.tvdbClient(http))
        let channel = MetaItem(id: "tt0133093", type: "tv", name: "Canale")
        let kitsu = MetaItem(id: "kitsu:1", type: "series", name: "Anime")
        let noKeys = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http, key: nil), tvdb: MetaFixtures.tvdbClient(http, key: nil))
        let channelResult = await enricher.enrich(channel, language: "it-IT")
        let kitsuResult = await enricher.enrich(kitsu, language: "it-IT")
        let noKeyResult = await noKeys.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(channelResult)
        XCTAssertNil(kitsuResult)
        XCTAssertNil(noKeyResult)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testAnUnknownTitleYieldsNothing() async {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        http.on("GET", "/find/tt0133093", .init(body: MetaFixtures.findNothing))
        let result = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(result)
    }

    func testMalformedAnswersAreSurvived() async {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: "not json at all"))
        http.on("GET", "/find/tt0133093", .init(body: MetaFixtures.findMovie))
        http.on("GET", "/movie/603", .init(body: "<html>maintenance</html>"))
        let result = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(result)
    }

    func testImagesOnlyComeFromTMDBsImageHost() async throws {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration.replacingOccurrences(of: "https://image.tmdb.org/t/p/", with: "https://evil.example/img/")))
        http.on("GET", "/find/tt0133093", .init(body: MetaFixtures.findMovie))
        http.on("GET", "/movie/603", .init(body: MetaFixtures.movie))
        let result = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(MetaFixtures.movieMeta(), language: "it-IT")
        let enrichment = try XCTUnwrap(result)
        XCTAssertEqual(enrichment.poster, "https://image.tmdb.org/t/p/w500/p.jpg", "the answer's own host is ignored")
        XCTAssertEqual(enrichment.logo, "https://image.tmdb.org/t/p/w500/l_it.png")
    }

    func testTolerantDecodingOfOddFields() async throws {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        http.on("GET", "/find/tt0133093", .init(body: MetaFixtures.findMovie))
        http.on("GET", "/movie/603", .init(body: #"{"id":"603","title":null,"overview":"","poster_path":null,"runtime":"136","genres":[{"name":null},{"name":"Azione"}],"credits":{"cast":"oops","crew":[]},"release_date":""}"#))
        let enrichmentResult = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(MetaFixtures.movieMeta(), language: "it-IT")
        let enrichment = try XCTUnwrap(enrichmentResult)
        XCTAssertEqual(enrichment.genres, ["Azione"])
        XCTAssertEqual(enrichment.runtimeMinutes, 136)
        XCTAssertNil(enrichment.overview)
        XCTAssertNil(enrichment.poster)
        XCTAssertNil(enrichment.year)
        XCTAssertTrue(enrichment.cast.isEmpty)
    }

    // MARK: Failure memory, coalescing, cache

    func testRateLimitPausesTheServiceUntilItsRetryAfterPasses() async {
        let http = MetaStubHTTP()
        http.on("GET", "/find/tt0133093", .init(status: 429, body: "{}", headers: ["retry-after": "120"]))
        let clock = MetaClock()
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil, now: { clock.now() })

        let first = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(first)
        let afterFirst = http.requests.count
        XCTAssertGreaterThan(afterFirst, 0)

        clock.advance(30)
        let second = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(second)
        XCTAssertEqual(http.requests.count, afterFirst, "no request while the service asked to wait")

        clock.advance(200)
        _ = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertGreaterThan(http.requests.count, afterFirst)
    }

    func testAWrongKeyIsNotRetriedForEveryTitleAndSavingANewKeyResetsIt() async {
        let http = MetaStubHTTP()
        http.on("GET", "/find/tt0133093", .init(status: 401, body: #"{"status_code":7,"status_message":"Invalid API key"}"#))
        let clock = MetaClock()
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil, now: { clock.now() })

        _ = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        let afterFirst = http.requests.count
        _ = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertEqual(http.requests.count, afterFirst)

        await enricher.reset()
        _ = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertGreaterThan(http.requests.count, afterFirst)
    }

    func testConcurrentRequestsForTheSameTitleShareOneFetch() async {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        http.on("GET", "/find/tt0133093", .init(body: MetaFixtures.findMovie, delay: 0.2))
        http.on("GET", "/movie/603", .init(body: MetaFixtures.movie))
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil)

        async let a = enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        async let b = enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        async let c = enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        let results = await [a, b, c]
        XCTAssertTrue(results.allSatisfy { $0 != nil })
        XCTAssertEqual(http.count(pathSuffix: "/find/tt0133093"), 1)
        XCTAssertEqual(http.count(pathSuffix: "/movie/603"), 1)
    }

    func testAnswersAreCachedUntilTheyExpire() async {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbMovieRoutes(http)
        let clock = MetaClock()
        let cache = ResponseCache(directory: nil, now: { clock.now() })
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil, cache: cache, ttl: 24 * 3600, now: { clock.now() })

        let first = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        let requestsAfterFirst = http.requests.count
        let second = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertEqual(first, second)
        XCTAssertEqual(http.requests.count, requestsAfterFirst, "served from the cache")

        clock.advance(25 * 3600)
        _ = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertGreaterThan(http.requests.count, requestsAfterFirst)
    }

    func testAFailureIsNeverCached() async {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        http.on("GET", "/find/tt0133093", .init(status: 503, body: "{}"), .init(body: MetaFixtures.findMovie))
        http.on("GET", "/movie/603", .init(body: MetaFixtures.movie))
        let clock = MetaClock()
        let cache = ResponseCache(directory: nil, now: { clock.now() })
        let enricher = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil, cache: cache, now: { clock.now() })

        let failed = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(failed)
        clock.advance(60)
        let recovered = await enricher.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNotNil(recovered)
    }

    func testRemovingAKeyStopsCachedDataFromBeingUsed() async {
        let http = MetaStubHTTP()
        MetaFixtures.tmdbMovieRoutes(http)
        let cache = ResponseCache(directory: nil)
        let withKey = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil, cache: cache)
        let first = await withKey.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNotNil(first)
        let withoutKey = MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http, key: nil), tvdb: nil, cache: cache)
        let second = await withoutKey.enrich(MetaFixtures.movieMeta(), language: "it-IT")
        XCTAssertNil(second)
    }

    // MARK: Pure helpers

    func testIMDbIDExtractionFromStremioIDs() {
        XCTAssertEqual(ExternalIDs.imdbID(fromMetaID: "tt0944947"), "tt0944947")
        XCTAssertEqual(ExternalIDs.imdbID(fromMetaID: "tt0944947:1:2"), "tt0944947")
        XCTAssertNil(ExternalIDs.imdbID(fromMetaID: "kitsu:1"))
        XCTAssertNil(ExternalIDs.imdbID(fromMetaID: "tmdb:603"))
        XCTAssertNil(ExternalIDs.imdbID(fromMetaID: "tt"))
        XCTAssertNil(ExternalIDs.imdbID(fromMetaID: "tt12ab"))
    }

    func testOtherCatalogIDsCarryTheirOwnExternalIDs() {
        XCTAssertEqual(ExternalIDs.fromMetaID("tt0944947:1:2"), ExternalIDs(imdb: "tt0944947", tmdb: nil, tvdb: nil))
        XCTAssertEqual(ExternalIDs.fromMetaID("tmdb:603"), ExternalIDs(imdb: nil, tmdb: 603, tvdb: nil))
        XCTAssertEqual(ExternalIDs.fromMetaID("tvdb:121361:1:2"), ExternalIDs(imdb: nil, tmdb: nil, tvdb: 121361))
        XCTAssertTrue(ExternalIDs.fromMetaID("kitsu:7442").isEmpty)
        XCTAssertTrue(ExternalIDs.fromMetaID("tmdb:abc").isEmpty)
        XCTAssertTrue(ExternalIDs.fromMetaID("tmdb:0").isEmpty)
        XCTAssertTrue(ExternalIDs.fromMetaID("").isEmpty)
    }

    func testATMDBIDInTheStremioIDIsEnoughToEnrich() async throws {
        let http = MetaStubHTTP()
        http.on("GET", "/configuration", .init(body: MetaFixtures.configuration))
        http.on("GET", "/movie/603", .init(body: MetaFixtures.movie))
        let meta = MetaItem(id: "tmdb:603", type: "movie", name: "The Matrix")
        let result = await MetadataEnricher(tmdb: MetaFixtures.tmdbClient(http), tvdb: nil).enrich(meta, language: "it-IT")
        let enrichment = try XCTUnwrap(result)
        XCTAssertEqual(enrichment.overview, "Trama in italiano")
        XCTAssertEqual(http.requests.filter { $0.url.path.contains("/find/") }.count, 0, "no lookup is needed when the id is known")
    }

    func testLogoChoicePrefersTheUsersLanguageThenEnglishAndSkipsVectors() throws {
        func logo(_ path: String, _ language: String?, _ vote: Double) throws -> TMDBLogo {
            let lang = language.map { "\"\($0)\"" } ?? "null"
            return try JSONDecoder().decode(TMDBLogo.self, from: Data(#"{"file_path":"\#(path)","iso_639_1":\#(lang),"vote_average":\#(vote)}"#.utf8))
        }
        let logos = [try logo("/none.png", nil, 9), try logo("/fr.png", "fr", 9), try logo("/en.png", "en", 2),
                     try logo("/it_low.png", "it", 1), try logo("/it_high.png", "it", 6), try logo("/it.svg", "it", 10)]
        XCTAssertEqual(MetadataEnricher.bestLogo(logos, language: "it-IT")?.filePath, "/it_high.png")
        XCTAssertEqual(MetadataEnricher.bestLogo(logos, language: "en-US")?.filePath, "/en.png")
        XCTAssertEqual(MetadataEnricher.bestLogo(logos, language: "de-DE")?.filePath, "/en.png")
        XCTAssertEqual(MetadataEnricher.bestLogo([try logo("/none.png", nil, 1), try logo("/fr.png", "fr", 9)], language: "it")?.filePath, "/none.png")
        XCTAssertNil(MetadataEnricher.bestLogo([try logo("/only.svg", "it", 1)], language: "it"))
    }

    func testImageSizesAndURLs() {
        let config = TMDBImageConfiguration()
        XCTAssertEqual(TMDBImageConfiguration.pick(["w92", "w342", "w500", "original"], atLeast: 400), "w500")
        XCTAssertEqual(TMDBImageConfiguration.pick(["w92", "w342", "original"], atLeast: 5000), "w342")
        XCTAssertEqual(TMDBImageConfiguration.pick(["original"], atLeast: 100), "original")
        XCTAssertEqual(MetadataEnricher.imageURL(config, sizes: config.posterSizes, minimum: 500, path: "/p.jpg"), "https://image.tmdb.org/t/p/w500/p.jpg")
        XCTAssertNil(MetadataEnricher.imageURL(config, sizes: config.posterSizes, minimum: 500, path: nil))
        XCTAssertNil(MetadataEnricher.imageURL(config, sizes: config.posterSizes, minimum: 500, path: "no-slash.jpg"))
        XCTAssertNil(MetadataEnricher.imageURL(config, sizes: config.posterSizes, minimum: 500, path: "/../secret"))
        XCTAssertEqual(MetadataEnricher.secureImageURL("https://artworks.thetvdb.com/a.jpg"), "https://artworks.thetvdb.com/a.jpg")
        XCTAssertNil(MetadataEnricher.secureImageURL("http://artworks.thetvdb.com/a.jpg"))
        XCTAssertNil(MetadataEnricher.secureImageURL("/banners/a.jpg"))
    }

    func testYearAndLanguageMapping() {
        XCTAssertEqual(MetadataEnricher.year(from: "1999-03-30"), "1999")
        XCTAssertNil(MetadataEnricher.year(from: ""))
        XCTAssertNil(MetadataEnricher.year(from: "0000-00-00"))
        XCTAssertNil(MetadataEnricher.year(from: "abcd-01-01"))
        XCTAssertEqual(MetadataEnricher.tvdbLanguage(from: "it-IT"), "ita")
        XCTAssertEqual(MetadataEnricher.tvdbLanguage(from: "pt-BR"), "por")
        XCTAssertEqual(MetadataEnricher.tvdbLanguage(from: "xx"), "eng")
    }

    func testTMDBLanguageTagFollowsTheSettingOrTheDevice() {
        XCTAssertEqual(MetadataEnricher.tmdbLanguage(preferred: "system", systemLanguages: ["it-IT", "en-US"]), "it-IT")
        XCTAssertEqual(MetadataEnricher.tmdbLanguage(preferred: "system", systemLanguages: ["zh-Hans-CN"]), "zh-CN")
        XCTAssertEqual(MetadataEnricher.tmdbLanguage(preferred: "fr", systemLanguages: ["it-IT"]), "fr")
        XCTAssertEqual(MetadataEnricher.tmdbLanguage(preferred: "pt_BR", systemLanguages: []), "pt-BR")
        XCTAssertEqual(MetadataEnricher.tmdbLanguage(preferred: "system", systemLanguages: []), "en")
        XCTAssertEqual(MetadataEnricher.tmdbLanguage(preferred: "12", systemLanguages: ["it-IT"]), "en-US")
    }

    func testEpisodesNeedingDataAreFoundAcrossPlaceholdersAndGaps() {
        let videos = [
            Video(id: "a", title: "Episode 1", season: 1, episode: 1, thumbnail: "t", overview: "o"),
            Video(id: "b", title: "Episodio 2", season: 1, episode: 2, thumbnail: "t", overview: "o"),
            Video(id: "c", title: "Vero titolo", season: 1, episode: 3, thumbnail: "t", overview: "o"),
            Video(id: "d", title: "Vero titolo", season: 1, episode: 4, thumbnail: nil, overview: "o"),
            Video(id: "e", title: "Vero titolo", season: 2, episode: 1, thumbnail: "t", overview: ""),
            Video(id: "f", title: "Senza numeri"),
        ]
        let meta = MetaItem(id: "tt1", type: "series", name: "S", videos: videos)
        let keys = MetadataEnricher.episodesNeedingData(in: meta).map { $0.token }
        XCTAssertEqual(keys, ["1:1", "1:2", "1:4", "2:1"])
    }

    func testExternalIDsSurviveEncodingAndComeFromCinemetaStyleMetas() throws {
        let json = #"{"id":"tt0133093","type":"movie","name":"The Matrix","imdb_id":"tt0133093","moviedb_id":603,"tvdb_id":"78901"}"#
        let meta = try JSONDecoder().decode(MetaItem.self, from: Data(json.utf8))
        XCTAssertEqual(meta.externalIDs, ExternalIDs(imdb: "tt0133093", tmdb: 603, tvdb: 78901))
        let again = try JSONDecoder().decode(MetaItem.self, from: try JSONEncoder().encode(meta))
        XCTAssertEqual(again.externalIDs, meta.externalIDs)

        let bare = try JSONDecoder().decode(MetaItem.self, from: Data(#"{"id":"kitsu:1","type":"series","name":"Old"}"#.utf8))
        XCTAssertTrue(bare.externalIDs.isEmpty, "nothing is invented for ids that are not IMDb ids")
        let imdbOnly = try JSONDecoder().decode(MetaItem.self, from: Data(#"{"id":"tt1","type":"movie","name":"Old"}"#.utf8))
        XCTAssertEqual(imdbOnly.externalIDs, ExternalIDs(imdb: "tt1", tmdb: nil, tvdb: nil), "a tt… id is an IMDb id by definition")
    }

    func testErrorMessagesAreItalianAndCarryNoDetail() {
        let errors: [MetadataError] = [.notConfigured, .invalidCredentials, .notFound, .rateLimited(retryAfter: 30),
                                       .rateLimited(retryAfter: nil), .unavailable("https://secret.example/?token=abc"), .malformed, .untrustedHost]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertFalse(error.message.contains("http"))
            XCTAssertFalse(error.message.contains("token"))
        }
        XCTAssertTrue(MetadataError.rateLimited(retryAfter: 30).message.contains("30"))
    }
}
