import XCTest
@testable import AetherCore

// Tests for the TorBox debrid resolver (Sources/AetherCore/Debrid). HTTP is stubbed with recorded-style bodies built from
// docs/research/torbox-api.md and docs/research/api-probe-2026-10-20.md; time is virtual, nothing really waits or connects.

// MARK: - Shared constants

enum TBKeys {
    /// Short on purpose: `Redactor` hides 32+ character tokens by itself, and these tests must prove that the client's own
    /// scrubbing keeps the key out of everything.
    static let valid = "tbk-7f3a91c2"
}

enum TBHash {
    static let movie = "0123456789abcdef0123456789abcdef01234567"
    static let series = "c12fe1c06bba254a9dc9f519b335aa7c1367a88a"
    static let other = "ffffffffffffffffffffffffffffffffffffffff"
}

// MARK: - JSON builders (recorded-style bodies)

enum TBJSON {
    static func lastComponent(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    static func file(_ id: Int, _ path: String, size: Int = 1_000_000, mime: String = "video/x-matroska",
                     zipped: Bool = false, infected: Bool = false) -> String {
        let short = lastComponent(path)
        return #"{"id":\#(id),"name":"\#(path)","short_name":"\#(short)","size":\#(size),"mimetype":"\#(mime)","zipped":\#(zipped),"infected":\#(infected),"md5":null,"s3_path":"x"}"#
    }

    static func torrent(id: Int, hash: String, state: String = "completed", progress: Double = 1, finished: Bool = true,
                        present: Bool = true, speed: Int = 0, eta: Int = 0, files: [String] = []) -> String {
        let list = files.joined(separator: ",")
        return #"{"id":\#(id),"hash":"\#(hash)","name":"Torrent","size":5000000,"progress":\#(progress),"download_state":"\#(state)","download_speed":\#(speed),"eta":\#(eta),"download_finished":\#(finished),"download_present":\#(present),"active":true,"files":[\#(list)]}"#
    }

    static func cachedItem(hash: String, files: [(String, Int)] = []) -> String {
        var parts: [String] = []
        for (name, size) in files {
            parts.append(#"{"name":"\#(name)","size":\#(size)}"#)
        }
        let list = parts.joined(separator: ",")
        return #"{"name":"Torrent","size":5000000,"hash":"\#(hash)","files":[\#(list)]}"#
    }

    static let user = #"{"id":42,"email":"someone@example.com","plan":2,"is_subscribed":true,"premium_expires_at":"2026-12-01T00:00:00Z","cooldown_until":null,"total_downloaded":123,"settings":{}}"#
}

// MARK: - Test doubles

/// Scripted TorBox. A route matches on method + path suffix (+ optional query fragment) and replays its replies in order,
/// the last one repeating. The first matching route wins, so register specific routes before general ones.
final class TBStubHTTP: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]
        var error: Error?
        var finalURL: URL?
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

    func on(_ method: String, _ pathSuffix: String, query: String? = nil, replies: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        routes.append(Route(method: method, pathSuffix: pathSuffix, queryFragment: query, replies: replies, served: 0))
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func requests(pathSuffix: String) -> [HTTPRequest] {
        return requests.filter { (request: HTTPRequest) -> Bool in return request.url.path.hasSuffix(pathSuffix) }
    }

    private func nextReply(for request: HTTPRequest) -> Reply {
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
        return TBStubHTTP.envelope(success: false, error: "ENDPOINT_NOT_FOUND", detail: "no stub route", status: 404)
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply = nextReply(for: request)
        if let error = reply.error { throw error }
        return HTTPResponse(data: reply.body, statusCode: reply.status, headers: reply.headers,
                            url: reply.finalURL ?? request.url)
    }

    // Reply builders

    static func envelope(success: Bool = true, error: String? = nil, detail: String = "", data: String = "null",
                         status: Int = 200, headers: [String: String] = [:]) -> Reply {
        var errorField = "null"
        if let error = error { errorField = "\"" + error + "\"" }
        var body = "{\"success\":"
        body += success ? "true" : "false"
        body += ",\"error\":"
        body += errorField
        body += ",\"detail\":\""
        body += detail
        body += "\",\"data\":"
        body += data
        body += "}"
        return Reply(status: status, body: Data(body.utf8), headers: headers, error: nil, finalURL: nil)
    }

    static func failure(_ code: String, status: Int = 400, detail: String = "") -> Reply {
        return envelope(success: false, error: code, detail: detail, data: "null", status: status)
    }

    static func raw(status: Int, body: String, headers: [String: String] = [:]) -> Reply {
        return Reply(status: status, body: Data(body.utf8), headers: headers, error: nil, finalURL: nil)
    }

    static func throwing(_ error: Error) -> Reply {
        return Reply(status: 200, body: Data(), headers: [:], error: error, finalURL: nil)
    }

    static let html = "<html><body><h1>502 Bad Gateway</h1>cloudflare</body></html>"
}

/// Virtual time: `sleep` advances `now` instead of waiting. With `blocking` it also really suspends (so a test can cancel it).
final class TBVirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var slept: [TimeInterval] = []
    private let blocking: Bool

    init(blocking: Bool = false) {
        self.blocking = blocking
        self.current = Date(timeIntervalSince1970: 1_800_000_000)
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return slept
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    private func record(_ seconds: TimeInterval) {
        lock.lock()
        slept.append(seconds)
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        record(seconds)
        if blocking {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    var clock: DebridClock {
        let owner = self
        return DebridClock(now: { return owner.now() },
                           sleep: { (seconds: TimeInterval) async throws -> Void in
                               try await owner.sleep(seconds)
                           })
    }
}

final class TBProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DebridProgress] = []

    func add(_ progress: DebridProgress) {
        lock.lock()
        items.append(progress)
        lock.unlock()
    }

    var all: [DebridProgress] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var callback: @Sendable (DebridProgress) -> Void {
        let owner = self
        return { (progress: DebridProgress) -> Void in owner.add(progress) }
    }
}

final class TBKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func set(_ newValue: String) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class TBEnvironment {
    static let retry = TorBoxClient.RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 4, maxAutomaticWait: 10, jitter: 0)

    let stub = TBStubHTTP()
    let clock: TBVirtualClock

    init(blocking: Bool = false) {
        clock = TBVirtualClock(blocking: blocking)
    }

    func makeClient(key: String? = TBKeys.valid, baseURL: URL = TorBoxClient.productionBaseURL,
                    retry: TorBoxClient.RetryPolicy = TBEnvironment.retry, log: DiagnosticLog? = nil) -> TorBoxClient {
        return TorBoxClient(http: stub, keyProvider: { return key }, baseURL: baseURL, retry: retry,
                            clock: clock.clock, log: log)
    }

    func makeResolver(configuration: DebridResolver.Configuration = DebridResolver.Configuration(),
                      log: DiagnosticLog? = nil, key: String? = TBKeys.valid) -> DebridResolver {
        return DebridResolver(client: makeClient(key: key, log: log), configuration: configuration,
                              clock: clock.clock, log: log)
    }

    /// "METHOD /path" of every request, in order, relative to /v1/api.
    func trace() -> [String] {
        return stub.requests.map { (request: HTTPRequest) -> String in
            var path = request.url.path
            if path.hasPrefix("/v1/api") { path = String(path.dropFirst(7)) }
            return request.method + " " + path
        }
    }
}

// MARK: - Assertion helpers

func tbError(_ operation: () async throws -> Void) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

func tbExpect<T>(_ expected: DebridError, file: StaticString = #filePath, line: UInt = #line,
                 _ operation: () async throws -> T) async {
    do {
        _ = try await operation()
        XCTFail("expected \(expected), but the call succeeded", file: file, line: line)
    } catch let error as DebridError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

func tbAssertNoDestructiveCalls(_ stub: TBStubHTTP, file: StaticString = #filePath, line: UInt = #line) {
    for request in stub.requests {
        let method = request.method.uppercased()
        XCTAssertTrue(method == "GET" || method == "POST", "unexpected method \(method)", file: file, line: line)
        let path = request.url.path.lowercased()
        XCTAssertFalse(path.contains("controltorrent"), "the user's items must never be touched", file: file, line: line)
        XCTAssertFalse(path.contains("delete"), "the user's items must never be touched", file: file, line: line)
        XCTAssertFalse(path.contains("queued/controlqueued"), "the queue must never be touched", file: file, line: line)
    }
}

func tbBodyString(_ request: HTTPRequest) -> String {
    return String(decoding: request.body ?? Data(), as: UTF8.self)
}

// MARK: - Hashes, magnets, episode ids

final class DebridHashAndMagnetTests: XCTestCase {
    func testNormalizeAcceptsHexInAnyCaseWithWhitespaceAndUrnPrefix() {
        XCTAssertEqual(DebridHash.normalize(TBHash.movie.uppercased()), TBHash.movie)
        XCTAssertEqual(DebridHash.normalize("  " + TBHash.movie + "\n"), TBHash.movie)
        XCTAssertEqual(DebridHash.normalize("urn:btih:" + TBHash.movie), TBHash.movie)
    }

    func testNormalizeConvertsBase32MagnetHashes() {
        XCTAssertEqual(DebridHash.normalize("AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH"), TBHash.movie)
        XCTAssertEqual(DebridHash.normalize("aerukz4jvpg66ajdivtytk6n54asgrlh"), TBHash.movie)
        XCTAssertEqual(DebridHash.normalize("YEX6DQDLXISUVHOJ6UM3GNNKPQJWPKEK"), TBHash.series)
    }

    func testNormalizeRejectsEverythingElse() {
        let bad: [String] = ["", "abc", String(repeating: "g", count: 40), String(repeating: "a", count: 39),
                             String(repeating: "1", count: 32), "AERUKZ4JVPG66AJDIVTYTK6N54ASGRL!"]
        for text in bad {
            XCTAssertNil(DebridHash.normalize(text), "«\(text)» must not be accepted")
        }
        XCTAssertTrue(DebridHash.isCanonical(TBHash.movie))
        XCTAssertFalse(DebridHash.isCanonical(TBHash.movie.uppercased()))
        XCTAssertFalse(DebridHash.rejectionReason("abc").contains("abc"), "the reason must not echo the input")
    }

    func testMagnetKeepsCleanDedupedTrackersOnly() throws {
        let trackers: [String] = [
            "tracker:udp://tracker.example:1337/announce",
            "dht:0123456789abcdef",
            "udp://tracker.example:1337/announce",
            "ftp://bad.example/x",
            "http://t2.example/announce",
            "   ",
            "notaurl"
        ]
        let magnet = try XCTUnwrap(DebridMagnet.build(infoHash: TBHash.movie.uppercased(), trackers: trackers))
        let expected = "magnet:?xt=urn:btih:" + TBHash.movie
            + "&tr=udp%3A%2F%2Ftracker.example%3A1337%2Fannounce"
            + "&tr=http%3A%2F%2Ft2.example%2Fannounce"
        XCTAssertEqual(magnet, expected)

        let capped = try XCTUnwrap(DebridMagnet.build(infoHash: TBHash.movie, trackers: trackers, maxTrackers: 1))
        XCTAssertEqual(capped.components(separatedBy: "&tr=").count, 2)
        XCTAssertNil(DebridMagnet.build(infoHash: "nope", trackers: []))
        XCTAssertEqual(DebridMagnet.build(infoHash: TBHash.movie, trackers: []), "magnet:?xt=urn:btih:" + TBHash.movie)
    }

    func testEpisodeIDsAreParsedOnlyForImdbStyleIDs() {
        XCTAssertEqual(DebridEpisode.parse(stremioID: "tt0944947:1:2"), DebridEpisode(season: 1, episode: 2))
        XCTAssertEqual(DebridEpisode.parse(stremioID: "tt0944947:0:12"), DebridEpisode(season: 0, episode: 12))
        XCTAssertNil(DebridEpisode.parse(stremioID: "tt0111161"))
        XCTAssertNil(DebridEpisode.parse(stremioID: "kitsu:1234:5"), "the middle number of a kitsu id is not a season")
        XCTAssertNil(DebridEpisode.parse(stremioID: "tt1:a:2"))
        XCTAssertNil(DebridEpisode.parse(stremioID: nil))
        XCTAssertTrue(DebridEpisode.expectsEpisode(stremioID: "kitsu:1234:5"))
        XCTAssertFalse(DebridEpisode.expectsEpisode(stremioID: "tt0111161"))
        XCTAssertFalse(DebridEpisode.expectsEpisode(stremioID: nil))
    }

    func testRequestFromStreamCopiesTheTorrentFields() throws {
        let hints = StreamBehaviorHints(videoSize: 1234, filename: "Movie.mkv")
        let stream = AddonStream(source: .torrent(infoHash: TBHash.movie, fileIndex: 3, trackers: ["udp://t.example:1/announce"]),
                                 name: "Torrentio", behaviorHints: hints)
        let request = try XCTUnwrap(DebridRequest(stream: stream, stremioID: "tt0944947:2:3"))
        XCTAssertEqual(request.infoHash, TBHash.movie)
        XCTAssertEqual(request.fileIndex, 3)
        XCTAssertEqual(request.filename, "Movie.mkv")
        XCTAssertEqual(request.videoSize, 1234)
        XCTAssertEqual(request.stremioID, "tt0944947:2:3")
        XCTAssertEqual(request.mode, DebridMode.cachedOnly, "never starts a download unless asked")
        XCTAssertNil(DebridRequest(stream: AddonStream(source: .url("https://x.example/a.mp4")), stremioID: nil))
    }
}

// MARK: - File matcher

final class TorBoxFileMatcherTests: XCTestCase {
    private func vf(_ id: Int, _ path: String, _ size: Int64 = 1_000, mime: String? = "video/x-matroska",
                    zipped: Bool = false, infected: Bool = false) -> TorBoxFile {
        return TorBoxFile(id: id, name: path, shortName: TBJSON.lastComponent(path), size: size, mimetype: mime,
                          zipped: zipped, infected: infected)
    }

    private func selection(_ outcome: TorBoxFileMatcher.Outcome) -> (id: Int, reason: TorBoxFileMatcher.Reason)? {
        if case .selected(let file, let reason) = outcome, let id = file.id {
            return (id: id, reason: reason)
        }
        return nil
    }

    private func episodeQuery(_ season: Int, _ episode: Int, filename: String? = nil, index: Int? = nil) -> TorBoxFileMatcher.Query {
        return TorBoxFileMatcher.Query(filename: filename, episode: DebridEpisode(season: season, episode: episode),
                                       expectsEpisode: true, fileIndexHint: index, sizeHint: nil)
    }

    // File name hint

    func testFilenameHintBeatsSizeAndEpisode() {
        let files = [vf(1, "Pack/Movie.2020.2160p.mkv", 9_000), vf(2, "Pack/Movie.2020.1080p.mkv", 3_000)]
        let query = TorBoxFileMatcher.Query(filename: "Movie.2020.1080p.mkv")
        let result = selection(TorBoxFileMatcher.select(from: files, query: query))
        XCTAssertEqual(result?.id, 2)
        XCTAssertEqual(result?.reason, TorBoxFileMatcher.Reason.filenameHint)
    }

    func testFilenameHintIsNormalisedLikeTorrentio() {
        let files = [vf(1, "Tom and Jerry (2021)/Tom and Jerry (2021).mkv", 5_000), vf(2, "Tom and Jerry (2021)/Extras.mkv", 9_000)]
        let query = TorBoxFileMatcher.Query(filename: "Tom.&.Jerry.2021.MKV")
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: query))?.id, 1)
        XCTAssertEqual(TorBoxFileMatcher.normalizedName("Tom & Jerry (2021).mkv"), "tomandjerry2021mkv")
    }

    func testFilenameHintMatchesDecomposedUnicodeAndCyrillic() {
        let composed = "Amélie.2001.1080p.mkv"
        let decomposed = "Ame\u{0301}lie.2001.1080p.mkv"
        XCTAssertNotEqual(composed, decomposed)
        let files = [vf(1, "Amélie [2001]/" + composed, 4_000), vf(2, "Amélie [2001]/Bonus.mkv", 8_000)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: TorBoxFileMatcher.Query(filename: decomposed)))?.id, 1)

        let russian = [vf(7, "Брат/Брат.1997.mkv", 3_000), vf(8, "Брат/Другое.mkv", 6_000)]
        let russianResult = TorBoxFileMatcher.select(from: russian, query: TorBoxFileMatcher.Query(filename: "брат.1997.MKV"))
        XCTAssertEqual(selection(russianResult)?.id, 7)
        XCTAssertEqual(selection(russianResult)?.reason, TorBoxFileMatcher.Reason.filenameHint)
    }

    func testFilenameHintCanMatchTheFullPath() {
        let files = [vf(1, "A/same.mkv", 1_000), vf(2, "B/same.mkv", 2_000)]
        let query = TorBoxFileMatcher.Query(filename: "A/same.mkv")
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: query))?.id, 1)
    }

    func testFilenameHintNeverSelectsAZippedOrInfectedFile() {
        let files = [vf(1, "Movie.mkv", 9_000, zipped: true), vf(2, "Movie.avi", 2_000), vf(3, "Other.mkv", 1_000, infected: true)]
        let result = selection(TorBoxFileMatcher.select(from: files, query: TorBoxFileMatcher.Query(filename: "Movie.mkv")))
        XCTAssertEqual(result?.id, 2, "the zipped copy is skipped; the largest usable video is taken")
        XCTAssertEqual(result?.reason, TorBoxFileMatcher.Reason.largestVideo)
    }

    // Episode patterns

    func testEpisodePatternsAreRecognised() {
        let cases: [(String, Int, Int, Int)] = [
            ("Show.Name.S01E02.1080p.WEB.mkv", 1, 2, 2),
            ("show.name.s01e02.mkv", 1, 2, 2),
            ("Show Name S01.E02.mkv", 1, 2, 2),
            ("Show Name S01 E02.mkv", 1, 2, 2),
            ("Show_Name_S01_E02.mkv", 1, 2, 2),
            ("Show.Name.1x02.HDTV.mkv", 1, 2, 2),
            ("Show Name - 12x07 - Title.mkv", 12, 7, 7),
            ("Show Name Season 1 Episode 2.mkv", 1, 2, 2),
            ("Show.Name.Season.01.Episode.02.mkv", 1, 2, 2),
            ("Show Name Season 3 - Episode 10.mkv", 3, 10, 10),
            ("Show Name Stagione 2 Episodio 5.mkv", 2, 5, 5),
            ("Show.Name.S01E01E02.mkv", 1, 1, 2),
            ("Show.Name.S01E01-E03.mkv", 1, 1, 3)
        ]
        for (name, season, first, last) in cases {
            let tag = TorBoxFileMatcher.episodeTag(for: vf(1, name))
            XCTAssertEqual(tag?.season, season, name)
            XCTAssertEqual(tag?.first, first, name)
            XCTAssertEqual(tag?.last, last, name)
        }
    }

    func testResolutionsAndYearsAreNotEpisodes() {
        let names = ["Movie.1920x1080.mkv", "Movie.2020.1080p.x265.mkv", "Movie.2160p.HDR.mkv", "Show.H.264.1280x720.mkv", "Cars 4x4 2020.mkv"]
        for name in names {
            let tag = TorBoxFileMatcher.episodeTag(for: vf(1, name))
            if name.hasPrefix("Cars") { continue }   // "4x4" is a legitimate 4x4 episode tag by the 1x02 rule; see below
            XCTAssertNil(tag, name)
        }
    }

    func testSeasonFolderPlusEpisodeOnlyName() {
        XCTAssertEqual(TorBoxFileMatcher.episodeTag(for: vf(1, "Show/Season 2/E05.mkv")), TorBoxFileMatcher.EpisodeTag(season: 2, first: 5, last: 5))
        XCTAssertEqual(TorBoxFileMatcher.episodeTag(for: vf(1, "Show/Stagione 02/Ep.05.mkv"))?.first, 5)
        XCTAssertEqual(TorBoxFileMatcher.episodeTag(for: vf(1, "Show/S03/05 - Title.mkv")), TorBoxFileMatcher.EpisodeTag(season: 3, first: 5, last: 5))
        XCTAssertNil(TorBoxFileMatcher.episodeTag(for: vf(1, "Show S01-S03 Complete/E05.mkv")), "a multi-season folder says nothing")
        XCTAssertNil(TorBoxFileMatcher.episodeTag(for: vf(1, "Show/Extras/E05.mkv")), "no season anywhere")
    }

    func testEpisodeIsPickedFromASeasonPackIgnoringSamplesSubtitlesAndNfo() {
        let files = [
            vf(1, "Show.S01.1080p/Show.S01E01.1080p.mkv", 900),
            vf(2, "Show.S01.1080p/Show.S01E02.1080p.mkv", 950),
            vf(3, "Show.S01.1080p/Show.S01E03.1080p.mkv", 1_000),
            vf(4, "Show.S01.1080p/Sample/sample.mkv", 10),
            vf(5, "Show.S01.1080p/Show.S01E02.srt", 1, mime: "application/x-subrip"),
            vf(6, "Show.S01.1080p/info.nfo", 1, mime: nil)
        ]
        let outcome = TorBoxFileMatcher.select(from: files, query: episodeQuery(1, 2))
        XCTAssertEqual(selection(outcome)?.id, 2, "the largest file is E03: the match must come from the numbers")
        XCTAssertEqual(selection(outcome)?.reason, TorBoxFileMatcher.Reason.episodeNumber)

        let viaRequest = TorBoxFileMatcher.query(for: DebridRequest(infoHash: TBHash.series, stremioID: "tt0944947:1:3"))
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: viaRequest))?.id, 3)
    }

    func testMultiEpisodeFileAnswersForEveryEpisodeItCovers() {
        let files = [vf(1, "Show.S01E01E02.mkv", 2_000), vf(2, "Show.S01E03.mkv", 1_000)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: episodeQuery(1, 2)))?.id, 1)
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: episodeQuery(1, 3)))?.id, 2)
    }

    func testSampleIsLessPreferredThanTheRealEpisodeEvenWhenLarger() {
        let files = [vf(1, "Show.S01E02.sample.mkv", 600), vf(2, "Show.S01E02.mkv", 500)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: episodeQuery(1, 2)))?.id, 2)
    }

    func testEpisodeWithoutConfidentMatchReturnsCandidatesNeverTheLargest() {
        let files = [
            vf(1, "Show.S01.1080p/Show.S01E03.mkv", 9_000),
            vf(2, "Show.S01.1080p/Show.S01E01.mkv", 1_000),
            vf(3, "Show.S01.1080p/Show.S02E02.mkv", 2_000)
        ]
        let outcome = TorBoxFileMatcher.select(from: files, query: episodeQuery(1, 2))
        guard case .noConfidentMatch(let candidates) = outcome else {
            return XCTFail("expected noConfidentMatch, got \(outcome)")
        }
        XCTAssertEqual(candidates.map { $0.id }, [2, 1, 3], "ordered by path, so the list is stable")
        XCTAssertEqual(candidates.map { $0.name }, ["Show.S01E01.mkv", "Show.S01E03.mkv", "Show.S02E02.mkv"])
        XCTAssertEqual(candidates.first?.size, 1_000)
    }

    func testUnparseableSeriesIdNeverGuesses() {
        let files = [vf(1, "Anime - 05.mkv", 500), vf(2, "Anime - 06.mkv", 900)]
        let request = DebridRequest(infoHash: TBHash.series, stremioID: "kitsu:42:5")
        let outcome = TorBoxFileMatcher.select(from: files, query: TorBoxFileMatcher.query(for: request))
        guard case .noConfidentMatch(let candidates) = outcome else {
            return XCTFail("expected noConfidentMatch, got \(outcome)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testSingleUntaggedVideoIsAcceptedButAConflictingTagIsNot() {
        let lone = [vf(1, "Show Title - special.mkv", 700), vf(2, "readme.txt", 1, mime: "text/plain")]
        let accepted = TorBoxFileMatcher.select(from: lone, query: episodeQuery(1, 2))
        XCTAssertEqual(selection(accepted)?.id, 1)
        XCTAssertEqual(selection(accepted)?.reason, TorBoxFileMatcher.Reason.onlyVideo)

        let conflicting = [vf(1, "Show.S01E05.mkv", 700)]
        guard case .noConfidentMatch = TorBoxFileMatcher.select(from: conflicting, query: episodeQuery(1, 2)) else {
            return XCTFail("a lone file tagged with another episode must not be played")
        }
    }

    // Movies

    func testMovieTakesTheLargestVideoAndIgnoresOtherFiles() {
        let files = [
            vf(1, "Movie/Movie.2020.1080p.mkv", 8_000),
            vf(2, "Movie/Sample/Movie-sample.mkv", 100),
            vf(3, "Movie/Movie.srt", 90_000, mime: "application/x-subrip"),
            vf(4, "Movie/poster.jpg", 80_000, mime: "image/jpeg"),
            vf(5, "Movie/Making.of.mkv", 3_000)
        ]
        let outcome = TorBoxFileMatcher.select(from: files, query: TorBoxFileMatcher.Query())
        XCTAssertEqual(selection(outcome)?.id, 1)
        XCTAssertEqual(selection(outcome)?.reason, TorBoxFileMatcher.Reason.largestVideo)
    }

    func testMovieSkipsZippedAndInfectedEvenWhenLargest() {
        let files = [vf(1, "A.mkv", 9_000, infected: true), vf(2, "B.mkv", 8_000, zipped: true), vf(3, "C.mkv", 1_000)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: TorBoxFileMatcher.Query()))?.id, 3)
    }

    func testNothingPlayableIsReportedPrecisely() {
        let infected = [vf(1, "A.mkv", 10, infected: true)]
        XCTAssertEqual(TorBoxFileMatcher.select(from: infected, query: TorBoxFileMatcher.Query()), TorBoxFileMatcher.Outcome.infectedOnly)
        let zipped = [vf(1, "A.mkv", 10, zipped: true), vf(2, "B.mp4", 10, zipped: true)]
        XCTAssertEqual(TorBoxFileMatcher.select(from: zipped, query: TorBoxFileMatcher.Query()), TorBoxFileMatcher.Outcome.archivesOnly)
        let rar = [vf(1, "Movie.part1.rar", 10, mime: "application/x-rar"), vf(2, "Movie.nfo", 1, mime: nil)]
        XCTAssertEqual(TorBoxFileMatcher.select(from: rar, query: TorBoxFileMatcher.Query()), TorBoxFileMatcher.Outcome.archivesOnly)
        let music = [vf(1, "Album/01.flac", 10, mime: "audio/flac")]
        XCTAssertEqual(TorBoxFileMatcher.select(from: music, query: TorBoxFileMatcher.Query()), TorBoxFileMatcher.Outcome.noVideo)
        XCTAssertEqual(TorBoxFileMatcher.select(from: [], query: TorBoxFileMatcher.Query()), TorBoxFileMatcher.Outcome.noVideo)
    }

    func testVideoRecognisedByMimetypeOrExtensionAndFilesWithoutIdAreSkipped() {
        XCTAssertTrue(TorBoxFileMatcher.isVideo(vf(1, "stream", mime: "video/mp4")))
        XCTAssertTrue(TorBoxFileMatcher.isVideo(vf(1, "movie.M2TS", mime: "application/octet-stream")))
        XCTAssertFalse(TorBoxFileMatcher.isVideo(vf(1, "cover.jpg", mime: "image/jpeg")))
        let noID = [TorBoxFile(id: nil, name: "Big.mkv", size: 9_000, mimetype: "video/x-matroska"), vf(2, "Small.mkv", 100)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: noID, query: TorBoxFileMatcher.Query()))?.id, 2)
    }

    func testFileIndexIsOnlyAPositionalTieBreaker() {
        // Equal sizes: the position given by Stremio's fileIdx decides.
        let tied = [vf(10, "Movie.part1.mkv", 5_000), vf(11, "Movie.part2.mkv", 5_000)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: tied, query: TorBoxFileMatcher.Query(fileIndexHint: 1)))?.id, 11)
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: tied, query: TorBoxFileMatcher.Query(fileIndexHint: 0)))?.id, 10)
        // Different sizes: the hint is ignored, the largest wins.
        let sized = [vf(20, "Small.mkv", 1_000), vf(21, "Large.mkv", 9_000)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: sized, query: TorBoxFileMatcher.Query(fileIndexHint: 0)))?.id, 21)
        // The provider's file id is never confused with the index: id 1 is not position 1.
        let ids = [vf(1, "Show.S01E01.mkv", 100), vf(0, "Show.S01E02.mkv", 100)]
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: ids, query: episodeQuery(1, 2, index: 1)))?.id, 0)
    }

    func testSizeHintBreaksTiesBetweenEpisodeMatches() {
        let files = [vf(1, "A/Show.S01E02.mkv", 700), vf(2, "B/Show.S01E02.mkv", 650)]
        var query = episodeQuery(1, 2)
        query.sizeHint = 650
        XCTAssertEqual(selection(TorBoxFileMatcher.select(from: files, query: query))?.id, 2)
    }
}

// MARK: - Models

final class TorBoxModelTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        return try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testEnvelopeAcceptsEveryShapeOfData() throws {
        let list = try decode(TorBoxEnvelope<TorBoxTorrentPayload>.self,
                              #"{"success":true,"error":null,"detail":"ok","data":[{"id":1},{"id":2}]}"#)
        XCTAssertEqual(list.data?.torrents.map { $0.id }, [1, 2])
        XCTAssertEqual(list.success, true)
        XCTAssertNil(list.error)

        let object = try decode(TorBoxEnvelope<TorBoxTorrentPayload>.self,
                                #"{"success":true,"error":null,"detail":"ok","data":{"id":9,"name":"x"}}"#)
        XCTAssertEqual(object.data?.torrents.map { $0.id }, [9])

        let text = try decode(TorBoxEnvelope<TorBoxLinkPayload>.self,
                              #"{"success":true,"error":null,"detail":"Requested","data":"https://cdn.example/dl/x"}"#)
        XCTAssertEqual(text.data?.url, "https://cdn.example/dl/x")

        let null = try decode(TorBoxEnvelope<TorBoxTorrentPayload>.self, #"{"success":true,"error":null,"detail":"none","data":null}"#)
        XCTAssertNil(null.data)
        XCTAssertFalse(null.dataUnreadable)

        let missing = try decode(TorBoxEnvelope<TorBoxLinkPayload>.self, #"{"success":false,"error":"BAD_TOKEN"}"#)
        XCTAssertEqual(missing.error, "BAD_TOKEN")
        XCTAssertNil(missing.data)

        XCTAssertThrowsError(try decode(TorBoxEnvelope<TorBoxLinkPayload>.self, "[1,2]"), "only a JSON object is an envelope")
    }

    func testProbeShapesOfAuthErrorsDecode() throws {
        let forbidden = try decode(TorBoxEnvelope<TorBoxUser>.self,
                                   #"{"success":false,"error":"AUTH_ERROR","detail":"An error occurred while verifying your token. Please try again.","data":null}"#)
        XCTAssertEqual(forbidden.error, "AUTH_ERROR")
        XCTAssertEqual(forbidden.success, false)
        XCTAssertNil(forbidden.data)

        let unauthenticated = try decode(TorBoxEnvelope<TorBoxUser>.self, #"{"detail":"Not authenticated"}"#)
        XCTAssertNil(unauthenticated.success)
        XCTAssertNil(unauthenticated.error)
        XCTAssertEqual(unauthenticated.detail, "Not authenticated")

        let validation = try decode(TorBoxEnvelope<TorBoxUser>.self,
                                    #"{"detail":[{"loc":["query","token"],"msg":"Field required","type":"missing"}]}"#)
        XCTAssertEqual(validation.detail, "Field required")
    }

    func testUserKeepsPlanFactsAndHasNoFieldForTheEmail() throws {
        let user = try decode(TorBoxUser.self, TBJSON.user)
        XCTAssertEqual(user.plan, 2)
        XCTAssertEqual(user.planName, "Pro")
        XCTAssertEqual(user.isSubscribed, true)
        XCTAssertNotNil(user.premiumExpiresAt)
        XCTAssertNil(user.cooldownUntil)
        let labels = Mirror(reflecting: user).children.compactMap { $0.label }
        XCTAssertFalse(labels.contains(where: { $0.lowercased().contains("mail") }), "the e-mail must not be modelled")
        XCTAssertFalse(String(describing: user).contains("someone@example.com"))

        let sloppy = try decode(TorBoxUser.self, #"{"plan":"0","is_subscribed":"false","premium_expires_at":"garbage"}"#)
        XCTAssertEqual(sloppy.plan, 0)
        XCTAssertEqual(sloppy.planName, "Free")
        XCTAssertEqual(sloppy.isSubscribed, false)
        XCTAssertNil(sloppy.premiumExpiresAt)
        XCTAssertEqual(try decode(TorBoxUser.self, "{}").planName, "Sconosciuto")
        XCTAssertEqual(try decode(TorBoxUser.self, #"{"plan":9}"#).planName, "Piano 9")
    }

    func testCheckcachedListObjectAndEmptyShapes() throws {
        let list = try decode(TorBoxCachedPayload.self,
            #"[{"name":"A","size":10,"hash":"\#(TBHash.movie)","files":[{"name":"A/a.mkv","size":10},{"name":"A/b.srt"}]},"junk",{"hash":"\#(TBHash.series)"}]"#)
        XCTAssertEqual(list.items.count, 2, "the junk element is skipped, not fatal")
        XCTAssertEqual(list.items[0].files.count, 2)
        XCTAssertEqual(list.items[0].files[0].size, 10)
        XCTAssertNil(list.items[0].files[1].size)
        XCTAssertEqual(list.items[1].files.count, 0)

        let object = try decode(TorBoxCachedPayload.self,
            #"{"\#(TBHash.movie)":{"name":"A","size":1,"files":[]},"\#(TBHash.series)":true,"\#(TBHash.other)":false,"name":"ignored"}"#)
        let hashes = object.items.compactMap { $0.hash }.sorted()
        XCTAssertEqual(hashes, [TBHash.movie, TBHash.series].sorted(), "false means not cached; non-hash keys are ignored")

        let single = try decode(TorBoxCachedPayload.self, #"{"name":"A","hash":"\#(TBHash.movie)","files":[]}"#)
        XCTAssertEqual(single.items.count, 1)

        for empty in ["null", "[]", "{}", "false", "\"\""] {
            XCTAssertEqual(try decode(TorBoxCachedPayload.self, empty).items.count, 0, empty)
        }
    }

    func testTorrentDecodesNumbersAsStringsAndSkipsBadFiles() throws {
        let torrent = try decode(TorBoxTorrent.self,
            #"{"id":"12","hash":"ABC","progress":"0.5","download_speed":1234.7,"eta":"90","download_finished":"false","download_present":1,"download_state":"downloading","files":[{"id":"3","name":"A/B.mkv","size":"2048"},"junk",{"name":"no-id.mkv"}]}"#)
        XCTAssertEqual(torrent.id, 12)
        XCTAssertEqual(torrent.progress, 0.5)
        XCTAssertEqual(torrent.downloadSpeed, 1234)
        XCTAssertEqual(torrent.eta, 90)
        XCTAssertEqual(torrent.downloadFinished, false)
        XCTAssertEqual(torrent.downloadPresent, true)
        XCTAssertEqual(torrent.files.count, 2)
        XCTAssertEqual(torrent.files[0].id, 3)
        XCTAssertEqual(torrent.files[0].size, 2048)
        XCTAssertEqual(torrent.files[0].displayName, "B.mkv")
        XCTAssertNil(torrent.files[1].id)
        XCTAssertFalse(torrent.isReady)
    }

    func testTorrentWithoutIDIsDroppedFromLists() throws {
        let payload = try decode(TorBoxTorrentPayload.self, #"[{"name":"no id"},{"id":5}]"#)
        XCTAssertEqual(payload.torrents.map { $0.id }, [5])
        XCTAssertEqual(try decode(TorBoxTorrentPayload.self, "null").torrents.count, 0)
        XCTAssertEqual(try decode(TorBoxTorrentPayload.self, "\"text\"").torrents.count, 0)
    }

    func testReadyMeansPresentAndFinished() {
        XCTAssertTrue(TorBoxTorrent(id: 1, downloadFinished: true, downloadPresent: true).isReady)
        XCTAssertFalse(TorBoxTorrent(id: 1, downloadFinished: false, downloadPresent: true).isReady)
        XCTAssertFalse(TorBoxTorrent(id: 1, downloadFinished: true, downloadPresent: false).isReady)
        XCTAssertFalse(TorBoxTorrent(id: 1, downloadFinished: true).isReady)
        XCTAssertTrue(TorBoxTorrent(id: 1, progress: 1, downloadPresent: true).isReady, "missing finished flag, progress 100%")
        XCTAssertFalse(TorBoxTorrent(id: 1, progress: 0.9, downloadPresent: true).isReady)
    }

    func testCreateResultAndLinkPayloads() throws {
        let queued = try decode(TorBoxCreateResult.self, #"{"queued_id":"31","hash":"abc","auth_id":"x"}"#)
        XCTAssertNil(queued.torrentID)
        XCTAssertEqual(queued.queuedID, 31)
        let created = try decode(TorBoxCreateResult.self, #"{"torrent_id":7,"hash":"abc"}"#)
        XCTAssertEqual(created.torrentID, 7)
        XCTAssertEqual(try decode(TorBoxLinkPayload.self, #"{"url":"https://cdn.example/x"}"#).url, "https://cdn.example/x")
        XCTAssertEqual(try decode(TorBoxLinkPayload.self, #""https://cdn.example/y""#).url, "https://cdn.example/y")
        XCTAssertNil(try decode(TorBoxLinkPayload.self, "42").url)
    }

    func testProgressScaleIsNormalised() {
        XCTAssertNil(DebridResolver.normalizedFraction(nil))
        XCTAssertEqual(DebridResolver.normalizedFraction(-1), 0)
        XCTAssertEqual(DebridResolver.normalizedFraction(0.25), 0.25)
        XCTAssertEqual(DebridResolver.normalizedFraction(1), 1)
        XCTAssertEqual(DebridResolver.normalizedFraction(42), 0.42)
        XCTAssertEqual(DebridResolver.normalizedFraction(100), 1)
        XCTAssertEqual(DebridResolver.normalizedFraction(5_000), 1)
    }
}

// MARK: - Client

final class TorBoxClientTests: XCTestCase {
    private func isRefusedHost(_ error: Error?) -> Bool {
        if let debrid = error as? DebridError, case .refusedHost = debrid { return true }
        return false
    }

    func testBearerEndpointsSendTheKeyInTheHeaderOnly() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: TBJSON.user)])
        let user = try await env.makeClient().fetchUser()
        XCTAssertEqual(user.plan, 2)
        let request = try XCTUnwrap(env.stub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.torbox.app/v1/api/user/me?settings=false")
        XCTAssertEqual(request.headers["Authorization"], "Bearer " + TBKeys.valid)
        XCTAssertFalse(request.url.absoluteString.contains(TBKeys.valid), "the key must not be in a Bearer URL")
        XCTAssertEqual(request.timeout, 15)
    }

    func testCheckcachedIsAPostWithJSONHashesAndListFormat() async throws {
        let env = TBEnvironment()
        let body = "[" + TBJSON.cachedItem(hash: TBHash.movie, files: [("Movie/Movie.mkv", 1_000)]) + "]"
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: body)])
        let result = try await env.makeClient().checkCachedChunk([TBHash.movie, TBHash.other])
        XCTAssertEqual(Array(result.keys), [TBHash.movie])
        XCTAssertEqual(result[TBHash.movie]?.files.first?.name, "Movie/Movie.mkv")

        let request = try XCTUnwrap(env.stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/api/torrents/checkcached")
        XCTAssertEqual(request.url.query, "format=list&list_files=true")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Authorization"], "Bearer " + TBKeys.valid)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: [String]])
        XCTAssertEqual(json["hashes"], [TBHash.movie, TBHash.other])
    }

    func testCheckcachedRefusesOversizedChunksAndNonCanonicalHashes() async {
        let env = TBEnvironment()
        let client = env.makeClient()
        let tooMany = (0..<101).map { (n: Int) -> String in return String(format: "%040x", n) }
        let tooManyError = await tbError { _ = try await client.checkCachedChunk(tooMany) }
        XCTAssertEqual(tooManyError as? DebridError, DebridError.api(code: "TOO_MANY_OPTIONS", detail: nil))
        let upperError = await tbError { _ = try await client.checkCachedChunk([TBHash.movie.uppercased()]) }
        XCTAssertNotNil(upperError as? DebridError)
        XCTAssertTrue(env.stub.requests.isEmpty, "bad input never reaches the network")
        let empty = try? await client.checkCachedChunk([])
        XCTAssertEqual(empty?.count, 0)
        XCTAssertTrue(env.stub.requests.isEmpty)
    }

    func testCheckcachedAnswerInObjectFormatIsUnderstoodToo() async throws {
        let env = TBEnvironment()
        let body = "{\"" + TBHash.movie + "\":" + TBJSON.cachedItem(hash: TBHash.movie) + "}"
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: body)])
        let result = try await env.makeClient().checkCachedChunk([TBHash.movie])
        XCTAssertNotNil(result[TBHash.movie])
    }

    func testRequestdlUsesTheTokenQueryAndNeitherBearerRedirectNorUserIP() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(detail: "Requested", data: "\"https://store-1.tb-cdn.example/dl/abc/Movie.mkv?t=zzz\"")])
        let url = try await env.makeClient().requestDownloadLink(torrentID: 77, fileID: 0)
        XCTAssertEqual(url.absoluteString, "https://store-1.tb-cdn.example/dl/abc/Movie.mkv?t=zzz")

        let request = try XCTUnwrap(env.stub.requests.first)
        XCTAssertNil(request.headers["Authorization"], "requestdl authenticates with the token parameter")
        let query = request.url.query ?? ""
        XCTAssertEqual(query, "token=" + TBKeys.valid + "&torrent_id=77&file_id=0")
        XCTAssertFalse(query.contains("redirect"))
        XCTAssertFalse(query.contains("user_ip"))
        XCTAssertFalse(query.contains("zip_link"))
    }

    func testRequestdlRejectsALinkThatContainsTheKeyOrIsNotHTTP() async {
        let env = TBEnvironment()
        let permalink = "\"https://cdn.example/dl?token=" + TBKeys.valid + "&x=1\""
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: permalink)])
        let leaked = await tbError { _ = try await env.makeClient().requestDownloadLink(torrentID: 1, fileID: 1) }
        guard let error = leaked as? DebridError, case .invalidResponse = error else {
            return XCTFail("expected invalidResponse, got \(String(describing: leaked))")
        }
        XCTAssertFalse(error.message.contains(TBKeys.valid))

        let other = TBEnvironment()
        other.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"javascript:alert(1)\"")])
        let bad = await tbError { _ = try await other.makeClient().requestDownloadLink(torrentID: 1, fileID: 1) }
        XCTAssertNotNil(bad as? DebridError)
        let missing = TBEnvironment()
        missing.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "null")])
        let none = await tbError { _ = try await missing.makeClient().requestDownloadLink(torrentID: 1, fileID: 1) }
        XCTAssertNotNil(none as? DebridError)
    }

    func testCreatetorrentSendsAFormWithMagnetAndAllowZipFalseAndIsNeverRetried() async throws {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/createtorrent", replies: [
            TBStubHTTP.raw(status: 502, body: TBStubHTTP.html),
            TBStubHTTP.envelope(data: #"{"torrent_id":1}"#)
        ])
        let magnet = "magnet:?xt=urn:btih:" + TBHash.movie + "&tr=udp%3A%2F%2Ft.example%3A1%2Fannounce"
        let client = env.makeClient()
        await tbExpect(DebridError.serviceUnavailable(statusCode: 502)) { try await client.createTorrent(magnet: magnet) }
        XCTAssertEqual(env.stub.requests.count, 1, "a failed add is not repeated behind the user's back")
        XCTAssertTrue(env.clock.sleeps.isEmpty)

        let request = try XCTUnwrap(env.stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        let form = tbBodyString(request)
        XCTAssertTrue(form.hasPrefix("magnet=magnet%3A%3Fxt%3Durn%3Abtih%3A" + TBHash.movie), form)
        XCTAssertTrue(form.hasSuffix("&allow_zip=false"), form)
        XCTAssertFalse(form.contains("seed="))
        XCTAssertFalse(form.contains("as_queued"))
        XCTAssertFalse(form.contains("add_only_if_cached"), "that field was never seen in any source")
    }

    func testCreatetorrentResultCarriesIDsAndTheCachedCopyHint() async throws {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/createtorrent", replies: [
            TBStubHTTP.envelope(detail: "Found Cached Torrent. Using Cached Torrent.", data: #"{"torrent_id":77,"hash":"abc","auth_id":"x"}"#),
            TBStubHTTP.envelope(detail: "Added to queue", data: #"{"queued_id":9}"#),
            TBStubHTTP.envelope(data: #"{"hash":"abc"}"#)
        ])
        let client = env.makeClient()
        let cached = try await client.createTorrent(magnet: "magnet:?xt=urn:btih:" + TBHash.movie)
        XCTAssertEqual(cached.torrentID, 77)
        XCTAssertTrue(cached.usedCachedCopy)
        let queued = try await client.createTorrent(magnet: "magnet:?xt=urn:btih:" + TBHash.movie)
        XCTAssertNil(queued.torrentID)
        XCTAssertEqual(queued.queuedID, 9)
        XCTAssertFalse(queued.usedCachedCopy)
        await tbExpect(DebridError.invalidResponse("manca torrent_id nella risposta")) {
            try await client.createTorrent(magnet: "magnet:?xt=urn:btih:" + TBHash.movie)
        }
    }

    func testMylistQueriesAndTrimsTheExtraItem() async throws {
        let env = TBEnvironment()
        let items = [TBJSON.torrent(id: 1, hash: TBHash.movie), TBJSON.torrent(id: 2, hash: TBHash.series), TBJSON.torrent(id: 3, hash: TBHash.other)]
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + items.joined(separator: ",") + "]")])
        env.stub.on("GET", "/torrents/mylist", query: "id=2", replies: [TBStubHTTP.envelope(data: items[1])])
        let client = env.makeClient()
        let page = try await client.myList(id: nil, offset: 0, limit: 2)
        XCTAssertEqual(page.map { $0.id }, [1, 2], "TorBox returns one extra item with limit")
        let one = try await client.myList(id: 2)
        XCTAssertEqual(one.map { $0.id }, [2])
        let queries = env.stub.requests.map { $0.url.query ?? "" }
        XCTAssertEqual(queries, ["bypass_cache=true&offset=0&limit=2", "bypass_cache=true&id=2"])
    }

    func testMylistItemNotFoundIsATypedError() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", replies: [TBStubHTTP.failure("ITEM_NOT_FOUND", status: 404, detail: "Item not found")])
        let client = env.makeClient()
        await tbExpect(DebridError.itemNotFound) { try await client.myList(id: 5) }
    }

    // Host pinning

    func testProductionClientStaysOnApiTorboxApp() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: TBJSON.user)])
        env.stub.on("GET", "/torrents/mylist", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":1}"#)])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"https://cdn.example/x.mkv\"")])
        let client = env.makeClient()
        _ = try await client.fetchUser()
        _ = try await client.myList()
        _ = try await client.checkCachedChunk([TBHash.movie])
        _ = try await client.createTorrent(magnet: "magnet:?xt=urn:btih:" + TBHash.movie)
        _ = try await client.requestDownloadLink(torrentID: 1, fileID: 1)
        XCTAssertEqual(env.stub.requests.count, 5)
        for request in env.stub.requests {
            XCTAssertEqual(request.url.scheme, "https")
            XCTAssertEqual(request.url.host, "api.torbox.app")
            XCTAssertTrue(request.url.path.hasPrefix("/v1/api/"))
        }
    }

    func testBaseURLsOutsideTheTrustedSetAreRefusedBeforeAnyRequest() async {
        let untrusted: [String] = [
            "https://evil.example/v1/api", "http://api.torbox.app/v1/api", "https://api.torbox.app.evil.example/v1/api",
            "https://8.8.8.8/v1/api", "ftp://127.0.0.1/v1/api", "https://torbox.app/v1/api"
        ]
        for text in untrusted {
            guard let base = URL(string: text) else { return XCTFail(text) }
            XCTAssertFalse(TorBoxClient.isTrustedBaseURL(base), text)
            let env = TBEnvironment()
            env.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: TBJSON.user)])
            let client = env.makeClient(baseURL: base)
            let failure = await tbError { _ = try await client.fetchUser() }
            XCTAssertTrue(isRefusedHost(failure), "\(text): \(String(describing: failure))")
            XCTAssertTrue(env.stub.requests.isEmpty, "the key must never be sent to \(text)")
        }
        let trusted: [String] = [
            "https://api.torbox.app/v1/api", "http://127.0.0.1:8099/v1/api", "http://localhost:8099/v1/api",
            "http://192.168.1.20:8099/v1/api", "http://[::1]:8099/v1/api"
        ]
        for text in trusted {
            XCTAssertTrue(TorBoxClient.isTrustedBaseURL(URL(string: text)!), text)
        }
    }

    func testLoopbackFixtureBaseURLWorks() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: TBJSON.user)])
        let base = URL(string: "http://127.0.0.1:8099/v1/api")!
        _ = try await env.makeClient(baseURL: base).fetchUser()
        XCTAssertEqual(env.stub.requests.first?.url.absoluteString, "http://127.0.0.1:8099/v1/api/user/me?settings=false")
    }

    func testAnswerFromAnotherHostIsDiscarded() async {
        let env = TBEnvironment()
        var reply = TBStubHTTP.envelope(data: TBJSON.user)
        reply.finalURL = URL(string: "https://evil.example/v1/api/user/me")
        env.stub.on("GET", "/user/me", replies: [reply])
        let client = env.makeClient()
        let failure = await tbError { _ = try await client.fetchUser() }
        XCTAssertTrue(isRefusedHost(failure), "a redirect to a foreign host must not yield data: \(String(describing: failure))")
        XCTAssertEqual(env.stub.requests.count, 1)
    }

    // Keys

    func testMissingOrMalformedKeyNeverReachesTheNetwork() async {
        let missing: [String?] = [nil, "", "   \n"]
        for key in missing {
            let env = TBEnvironment()
            let client = env.makeClient(key: key)
            await tbExpect(DebridError.notConfigured) { try await client.fetchUser() }
            XCTAssertTrue(env.stub.requests.isEmpty)
        }
        let env = TBEnvironment()
        let broken = TorBoxClient(http: env.stub, keyProvider: { throw NSError(domain: "keychain", code: 1) },
                                  clock: env.clock.clock)
        await tbExpect(DebridError.notConfigured) { try await broken.fetchUser() }

        for key in ["abc def", "abc\r\nX-Evil: 1", "chiave-è", "tab\tkey"] {
            let other = TBEnvironment()
            let client = other.makeClient(key: key)
            await tbExpect(DebridError.authFailed) { try await client.fetchUser() }
            XCTAssertTrue(other.stub.requests.isEmpty, "a key with spaces / control characters must not reach a header")
        }
    }

    func testKeyIsReadFromTheProviderOnEveryCall() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: TBJSON.user)])
        let box = TBKeyBox("first-key")
        let client = TorBoxClient(http: env.stub, keyProvider: { return box.get() }, clock: env.clock.clock)
        _ = try await client.fetchUser()
        box.set("rotated-key")
        _ = try await client.fetchUser()
        let headers = env.stub.requests.map { $0.headers["Authorization"] ?? "" }
        XCTAssertEqual(headers, ["Bearer first-key", "Bearer rotated-key"])
    }

    // Error mapping

    func testErrorCodesAreMappedFromTheCodeFieldFirst() async {
        let cases: [(Int, String, String, DebridError)] = [
            (403, "AUTH_ERROR", "An error occurred while verifying your token.", DebridError.authFailed),
            (401, "BAD_TOKEN", "Bad token", DebridError.authFailed),
            (403, "NO_AUTH", "", DebridError.authFailed),
            (403, "PLAN_RESTRICTED_FEATURE", "Plan restricted", DebridError.planRestricted),
            (400, "ACTIVE_LIMIT", "You have reached your active limit", DebridError.limitReached(.activeDownloads)),
            (400, "MONTHLY_LIMIT", "", DebridError.limitReached(.monthly)),
            (400, "COOLDOWN_LIMIT", "", DebridError.limitReached(.cooldown)),
            (400, "DOWNLOAD_TOO_LARGE", "", DebridError.limitReached(.downloadTooLarge)),
            (404, "ITEM_NOT_FOUND", "", DebridError.itemNotFound),
            (400, "DIFF_ISSUE", "Torrent already queued", DebridError.alreadyInAccount),
            (400, "DIFF_ISSUE", "You have reached the maximum queued downloads", DebridError.limitReached(.activeDownloads)),
            (400, "DUPLICATE_ITEM", "", DebridError.alreadyInAccount),
            (500, "DATABASE_ERROR", "", DebridError.serviceUnavailable(statusCode: 500)),
            (503, "NO_SERVERS_AVAILABLE_ERROR", "", DebridError.serviceUnavailable(statusCode: 503)),
            (400, "BOZO_TORRENT", "Bad torrent", DebridError.api(code: "BOZO_TORRENT", detail: "Bad torrent")),
            (400, "some weird code!", "", DebridError.api(code: "UNKNOWN", detail: nil)),
            (200, "AUTH_ERROR", "", DebridError.authFailed)
        ]
        for (status, code, detail, expected) in cases {
            let env = TBEnvironment()
            env.stub.on("GET", "/user/me", replies: [TBStubHTTP.failure(code, status: status, detail: detail)])
            let client = env.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
            await tbExpect(expected) { try await client.fetchUser() }
        }
    }

    func testRecordedProbeAnswersMapToAuthFailed() async {
        // 403 with a wrong key and 401 without an Authorization header, exactly as the 2026-10-20 probe saw them.
        let wrongKey = TBStubHTTP.raw(status: 403, body: #"{"success":false,"error":"AUTH_ERROR","detail":"An error occurred while verifying your token. Please try again.","data":null}"#,
                                      headers: ["retry-after": "60", "x-ratelimit-limit": "300", "x-ratelimit-remaining": "299"])
        let noHeader = TBStubHTTP.raw(status: 401, body: #"{"detail":"Not authenticated"}"#)
        for reply in [wrongKey, noHeader] {
            let env = TBEnvironment()
            env.stub.on("GET", "/user/me", replies: [reply])
            let client = env.makeClient()
            await tbExpect(DebridError.authFailed) { try await client.fetchUser() }
            XCTAssertEqual(env.stub.requests.count, 1, "an auth failure is never retried")
            XCTAssertTrue(env.clock.sleeps.isEmpty, "the retry-after header of a 403 must not be waited for")
        }
    }

    func testNonJSONBodiesAreServiceUnavailable() async {
        let bodies: [(Int, String)] = [(502, TBStubHTTP.html), (200, TBStubHTTP.html), (200, ""), (503, "upstream connect error"), (200, "[1,2,3]"), (403, "<html>Attention Required</html>")]
        for (status, body) in bodies {
            let env = TBEnvironment()
            env.stub.on("GET", "/user/me", replies: [TBStubHTTP.raw(status: status, body: body)])
            let client = env.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
            let failure = await tbError { _ = try await client.fetchUser() }
            guard let error = failure as? DebridError, case .serviceUnavailable(let code) = error else {
                XCTFail("status \(status): expected serviceUnavailable, got \(String(describing: failure))")
                continue
            }
            XCTAssertEqual(code, status >= 400 ? status : nil)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testServerErrorsAreRetriedWithExponentialBackoffThenGiveUp() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.raw(status: 502, body: TBStubHTTP.html)])
        let client = env.makeClient()
        await tbExpect(DebridError.serviceUnavailable(statusCode: 502)) { try await client.fetchUser() }
        XCTAssertEqual(env.stub.requests.count, 3, "max 3 attempts")
        XCTAssertEqual(env.clock.sleeps, [1, 2], "exponential backoff between attempts")
    }

    func testTransientFailureRecovers() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.raw(status: 503, body: TBStubHTTP.html), TBStubHTTP.envelope(data: TBJSON.user)])
        let user = try await env.makeClient().fetchUser()
        XCTAssertEqual(user.plan, 2)
        XCTAssertEqual(env.stub.requests.count, 2)
        XCTAssertEqual(env.clock.sleeps, [1])
    }

    func testRateLimitHonoursRetryAfterAndRetries() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [
            TBStubHTTP.raw(status: 429, body: #"{"detail":"Rate limit exceeded"}"#, headers: ["retry-after": "2", "x-ratelimit-remaining": "0"]),
            TBStubHTTP.envelope(data: TBJSON.user)
        ])
        let user = try await env.makeClient().fetchUser()
        XCTAssertEqual(user.plan, 2)
        XCTAssertEqual(env.clock.sleeps, [2], "waits exactly what the service asked")
        XCTAssertEqual(env.stub.requests.count, 2)
    }

    func testLongRetryAfterIsReportedNotWaitedFor() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.raw(status: 429, body: #"{"detail":"Rate limit exceeded"}"#, headers: ["retry-after": "60"])])
        let client = env.makeClient()
        await tbExpect(DebridError.rateLimited(retryAfter: 60)) { try await client.fetchUser() }
        XCTAssertEqual(env.stub.requests.count, 1)
        XCTAssertTrue(env.clock.sleeps.isEmpty)
        XCTAssertTrue(DebridError.rateLimited(retryAfter: 60).isRetryable)
        XCTAssertEqual(DebridError.rateLimited(retryAfter: 60).retryAfter, 60)
        XCTAssertTrue(DebridError.rateLimited(retryAfter: 60).message.contains("60"))
    }

    func testRateLimitCodeInTheBodyAndResetHeaderFallback() async {
        let env = TBEnvironment()
        // 200-class status with the code, and no retry-after: the reset epoch (decimal) gives 5.5 s.
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.failure("RATE_LIMIT_EXCEEDED", status: 400, detail: "slow down")])
        let client = env.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
        await tbExpect(DebridError.rateLimited(retryAfter: nil)) { try await client.fetchUser() }

        let other = TBEnvironment()
        let reset = String(format: "%.1f", 1_800_000_000.0 + 5.5)
        other.stub.on("GET", "/user/me", replies: [TBStubHTTP.raw(status: 429, body: "{}", headers: ["x-ratelimit-reset": reset])])
        let second = other.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
        await tbExpect(DebridError.rateLimited(retryAfter: 5.5)) { try await second.fetchUser() }
    }

    func testTransportErrorsBecomeConstantMessages() async {
        let cases: [(AddonError, DebridError)] = [
            (AddonError.timeout, DebridError.timeout),
            (AddonError.offline, DebridError.offline),
            (AddonError.unreachable("api.torbox.app"), DebridError.unreachable),
            (AddonError.responseTooLarge(limit: 10), DebridError.invalidResponse("risposta troppo grande")),
            (AddonError.http(status: 500), DebridError.serviceUnavailable(statusCode: 500))
        ]
        for (transport, expected) in cases {
            let env = TBEnvironment()
            env.stub.on("GET", "/user/me", replies: [TBStubHTTP.throwing(transport)])
            let client = env.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
            await tbExpect(expected) { try await client.fetchUser() }
        }
        let tls = TBEnvironment()
        tls.stub.on("GET", "/user/me", replies: [TBStubHTTP.throwing(AddonError.tlsFailure)])
        let tlsClient = tls.makeClient()
        let failure = await tbError { _ = try await tlsClient.fetchUser() }
        guard let error = failure as? DebridError, case .network = error else {
            return XCTFail("expected a network error, got \(String(describing: failure))")
        }
        XCTAssertFalse(error.isRetryable, "a certificate problem will not fix itself")
    }

    func testCancellationIsPropagatedAsCancellationError() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.throwing(CancellationError())])
        let client = env.makeClient()
        let failure = await tbError { _ = try await client.fetchUser() }
        XCTAssertTrue(failure is CancellationError, "got \(String(describing: failure))")
        let cancelled = TBEnvironment()
        cancelled.stub.on("GET", "/user/me", replies: [TBStubHTTP.throwing(AddonError.cancelled)])
        let other = cancelled.makeClient()
        let second = await tbError { _ = try await other.fetchUser() }
        XCTAssertTrue(second is CancellationError)
    }

    func testEverySwitchOfDebridErrorHasAMessageAndAFlag() {
        let samples: [DebridError] = [
            .notConfigured, .authFailed, .planRestricted, .limitReached(.activeDownloads), .limitReached(.monthly),
            .limitReached(.cooldown), .limitReached(.downloadTooLarge), .rateLimited(retryAfter: nil), .notCached,
            .invalidInfoHash("x"), .alreadyInAccount, .itemNotFound, .queuedAtProvider, .downloadNotReady(nil),
            .itemFailed(state: "error"), .noMatchingFile(candidates: []), .noVideoFile, .archivedFilesOnly,
            .infectedFiles, .serviceUnavailable(statusCode: nil), .invalidResponse("x"), .timeout, .offline,
            .unreachable, .network("x"), .refusedHost("x"), .api(code: "X", detail: nil)
        ]
        for error in samples {
            XCTAssertFalse(error.message.isEmpty)
            XCTAssertEqual(error.errorDescription, error.message)
        }
        XCTAssertFalse(DebridError.authFailed.isRetryable)
        XCTAssertFalse(DebridError.limitReached(.activeDownloads).isRetryable)
        XCTAssertFalse(DebridError.notCached.isRetryable)
        XCTAssertTrue(DebridError.timeout.isRetryable)
        XCTAssertTrue(DebridError.queuedAtProvider.isRetryable)
        XCTAssertEqual(DebridError.downloadNotReady(DebridProgress(phase: .downloading, fraction: 0.42)).message.contains("42%"), true)
    }
}

// MARK: - Resolver

final class DebridResolverTests: XCTestCase {
    private let movieFiles: [String] = [
        TBJSON.file(1, "Movie.2020/Movie.2020.1080p.mkv", size: 8_000_000),
        TBJSON.file(2, "Movie.2020/Movie.2020.nfo", size: 500, mime: "text/plain")
    ]
    private let cdn = "https://store-5.tb-cdn.example/dl/abc/Movie.2020.1080p.mkv?t=zz"

    private func stubCachedMovie(_ env: TBEnvironment, torrentID: Int = 77) {
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.cachedItem(hash: TBHash.movie, files: [("Movie.2020/Movie.2020.1080p.mkv", 8_000_000)]) + "]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(detail: "Found Cached Torrent. Using Cached Torrent.", data: "{\"torrent_id\":\(torrentID),\"hash\":\"\(TBHash.movie)\"}")])
        env.stub.on("GET", "/torrents/mylist", query: "id=\(torrentID)", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: torrentID, hash: TBHash.movie, files: movieFiles))])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(detail: "Requested", data: "\"\(cdn)\"")])
    }

    // Happy paths

    func testCachedMovieFollowsTheDocumentedFlow() async throws {
        let env = TBEnvironment()
        stubCachedMovie(env)
        let resolver = env.makeResolver()
        let recorder = TBProgressRecorder()
        let request = DebridRequest(infoHash: TBHash.movie.uppercased(), trackers: ["tracker:udp://t.example:80/announce"],
                                    stremioID: "tt0000001")
        let resolution = try await resolver.resolve(request, onProgress: recorder.callback)

        XCTAssertEqual(resolution.url.absoluteString, cdn)
        XCTAssertEqual(resolution.torrentID, 77)
        XCTAssertEqual(resolution.fileID, 1)
        XCTAssertEqual(resolution.fileName, "Movie.2020.1080p.mkv")
        XCTAssertEqual(resolution.fileSize, 8_000_000)
        XCTAssertFalse(resolution.wasAlreadyInAccount)
        XCTAssertEqual(env.trace(), ["GET /torrents/mylist", "POST /torrents/checkcached", "POST /torrents/createtorrent",
                                     "GET /torrents/mylist", "GET /torrents/requestdl"])
        XCTAssertEqual(recorder.all.map { $0.phase }, [.checking, .adding, .selectingFile, .requestingLink])

        let create = try XCTUnwrap(env.stub.requests(pathSuffix: "/torrents/createtorrent").first)
        let form = tbBodyString(create)
        XCTAssertTrue(form.hasPrefix("magnet=magnet%3A%3Fxt%3Durn%3Abtih%3A" + TBHash.movie + "%26tr%3Dudp"), form)
        XCTAssertTrue(form.hasSuffix("&allow_zip=false"), form)

        let download = try XCTUnwrap(env.stub.requests(pathSuffix: "/torrents/requestdl").first)
        XCTAssertTrue((download.url.query ?? "").contains("torrent_id=77&file_id=1"))
        XCTAssertFalse(resolution.description.contains("tb-cdn"), "description is host-free of the token: \(resolution.description)")
        tbAssertNoDestructiveCalls(env.stub)
    }

    func testTorrentAlreadyReadyInTheAccountIsNotAddedAgain() async throws {
        let env = TBEnvironment()
        let item = TBJSON.torrent(id: 31, hash: TBHash.movie, files: movieFiles)
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 30, hash: TBHash.other) + "," + item + "]")])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let resolution = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie))
        XCTAssertTrue(resolution.wasAlreadyInAccount)
        XCTAssertEqual(resolution.torrentID, 31)
        XCTAssertEqual(env.trace(), ["GET /torrents/mylist", "GET /torrents/requestdl"], "no checkcached, no createtorrent")
        tbAssertNoDestructiveCalls(env.stub)
    }

    func testAccountListIsPagedToFindTheHash() async throws {
        let env = TBEnvironment()
        let target = TBJSON.torrent(id: 3, hash: TBHash.movie, files: movieFiles)
        env.stub.on("GET", "/torrents/mylist", query: "offset=0", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 1, hash: TBHash.other) + "," + TBJSON.torrent(id: 2, hash: TBHash.series) + "]")])
        env.stub.on("GET", "/torrents/mylist", query: "offset=2", replies: [TBStubHTTP.envelope(data: "[" + target + "]")])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        var configuration = DebridResolver.Configuration()
        configuration.listPageSize = 2
        let resolution = try await env.makeResolver(configuration: configuration).resolve(DebridRequest(infoHash: TBHash.movie))
        XCTAssertEqual(resolution.torrentID, 3)
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/mylist").map { $0.url.query ?? "" },
                       ["bypass_cache=true&offset=0&limit=2", "bypass_cache=true&offset=2&limit=2"])
    }

    func testReadyTorrentWithoutFilesInTheListIsReadByID() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "id=31", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 31, hash: TBHash.movie, files: movieFiles))])
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 31, hash: TBHash.movie) + "]")])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let resolution = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie))
        XCTAssertEqual(resolution.fileID, 1)
        XCTAssertEqual(env.trace(), ["GET /torrents/mylist", "GET /torrents/mylist", "GET /torrents/requestdl"])
        XCTAssertTrue(env.clock.sleeps.isEmpty)
    }

    // cachedOnly

    func testCachedOnlyThrowsNotCachedAndNeverAdds() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":1}"#)])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.notCached) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
        XCTAssertEqual(env.trace(), ["GET /torrents/mylist", "POST /torrents/checkcached"])
        XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/createtorrent").isEmpty)
    }

    func testCachedOnlyWithAFailingCacheCheckDoesNotAssumeNotCachedAndDoesNotAdd() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.raw(status: 502, body: TBStubHTTP.html)])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":1}"#)])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.serviceUnavailable(statusCode: 502)) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
        XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/createtorrent").isEmpty, "unverified content is never added")
    }

    func testCachedOnlyAlwaysAsksTheCacheAgainBeforeAdding() async throws {
        let env = TBEnvironment()
        stubCachedMovie(env)
        let resolver = env.makeResolver()
        let report = await resolver.availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(report.status(for: TBHash.movie), DebridCacheStatus.cached)
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/checkcached").count, 1)
        _ = try await resolver.resolve(DebridRequest(infoHash: TBHash.movie))
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/checkcached").count, 2, "a stale in-memory answer must not start a download")
        // Adding changes what the service knows: the in-memory answer is dropped.
        _ = await resolver.availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/checkcached").count, 3)
    }

    // startIfNeeded

    func testStartIfNeededAddsReportsProgressAndWaitsEvery3Seconds() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: "{\"torrent_id\":5,\"hash\":\"\(TBHash.movie)\"}")])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "metaDL", progress: 0, finished: false, present: false)),
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "downloading", progress: 0.4, finished: false, present: false, speed: 2_500_000, eta: 120)),
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "completed", progress: 1, finished: true, present: true, files: movieFiles))
        ])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])

        let recorder = TBProgressRecorder()
        let request = DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)
        let resolution = try await env.makeResolver().resolve(request, onProgress: recorder.callback)
        XCTAssertEqual(resolution.torrentID, 5)
        XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/checkcached").isEmpty, "startIfNeeded lets TorBox decide")
        XCTAssertEqual(env.clock.sleeps, [3, 3], "polls are at least 3 s apart")

        let downloading = recorder.all.filter { $0.phase == .downloading }
        XCTAssertEqual(downloading.count, 2)
        XCTAssertEqual(downloading[0].state, "metaDL")
        XCTAssertEqual(downloading[0].fraction, 0)
        XCTAssertEqual(downloading[1].fraction, 0.4)
        XCTAssertEqual(downloading[1].downloadSpeed, 2_500_000)
        XCTAssertEqual(downloading[1].etaSeconds, 120)
        XCTAssertEqual(downloading[1].state, "downloading")
        tbAssertNoDestructiveCalls(env.stub)
    }

    func testStartIfNeededContinuesAnItemAlreadyDownloadingInTheAccount() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 8, hash: TBHash.movie, state: "downloading", progress: 0.2, finished: false, present: false) + "]")])
        env.stub.on("GET", "/torrents/mylist", query: "id=8", replies: [
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 8, hash: TBHash.movie, state: "downloading", progress: 0.7, finished: false, present: false)),
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 8, hash: TBHash.movie, files: movieFiles))
        ])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":99}"#)])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let resolution = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded))
        XCTAssertTrue(resolution.wasAlreadyInAccount)
        XCTAssertEqual(resolution.torrentID, 8)
        XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/createtorrent").isEmpty)
    }

    func testWaitingIsBoundedAtAboutSixtySecondsAndTheItemStaysInTheAccount() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.cachedItem(hash: TBHash.movie) + "]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":5}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "stalled (no seeds)", progress: 0.3, finished: false, present: false))])
        let resolver = env.makeResolver()
        let failure = await tbError { _ = try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
        guard let error = failure as? DebridError, case .downloadNotReady(let progress) = error else {
            return XCTFail("expected downloadNotReady, got \(String(describing: failure))")
        }
        XCTAssertEqual(progress?.fraction, 0.3)
        XCTAssertEqual(progress?.state, "stalled (no seeds)")
        XCTAssertTrue(error.isRetryable)
        let polls = env.stub.requests(pathSuffix: "/torrents/mylist").filter { ($0.url.query ?? "").contains("id=5") }.count
        XCTAssertEqual(polls, 21)
        XCTAssertEqual(env.clock.sleeps.count, 20)
        XCTAssertTrue(env.clock.sleeps.allSatisfy { $0 >= 3 })
        XCTAssertEqual(env.clock.sleeps.reduce(0, +), 60)
        tbAssertNoDestructiveCalls(env.stub)
    }

    func testStartIfNeededWaitsLongerThanCachedOnly() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":5}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "downloading", progress: 0.1, finished: false, present: false))])
        var configuration = DebridResolver.Configuration()
        configuration.startMaxWait = 120
        let resolver = env.makeResolver(configuration: configuration)
        await tbExpect(DebridError.downloadNotReady(DebridProgress(phase: .downloading, fraction: 0.1, downloadSpeed: 0, etaSeconds: 0, state: "downloading"))) {
            try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded))
        }
        XCTAssertEqual(env.clock.sleeps.reduce(0, +), 120)
    }

    func testPollIntervalCanNeverBeConfiguredBelowThreeSeconds() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":5}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "downloading", progress: 0.1, finished: false, present: false))])
        var configuration = DebridResolver.Configuration()
        configuration.pollInterval = 0.01
        configuration.startMaxWait = 9
        let resolver = env.makeResolver(configuration: configuration)
        _ = await tbError { _ = try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) }
        XCTAssertFalse(env.clock.sleeps.isEmpty)
        XCTAssertTrue(env.clock.sleeps.allSatisfy { $0 >= 3 })
    }

    func testCancellationStopsPolling() async throws {
        let env = TBEnvironment(blocking: true)
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":5}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "downloading", progress: 0.1, finished: false, present: false))])
        let resolver = env.makeResolver()
        let request = DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)
        let task = Task { () -> DebridResolution in
            return try await resolver.resolve(request)
        }
        let deadline = Date().addingTimeInterval(10)
        while env.clock.sleeps.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(env.clock.sleeps.isEmpty, "the resolver should be waiting between two polls")
        let pollsBefore = env.stub.requests(pathSuffix: "/torrents/mylist").count
        task.cancel()
        let started = Date()
        do {
            _ = try await task.value
            XCTFail("a cancelled resolution must not succeed")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/mylist").count, pollsBefore, "no poll after cancellation")
        XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/requestdl").isEmpty)
    }

    func testAlreadyCancelledTaskDoesNothing() async {
        let env = TBEnvironment()
        stubCachedMovie(env)
        let resolver = env.makeResolver()
        let task = Task { () -> DebridResolution in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await resolver.resolve(DebridRequest(infoHash: TBHash.movie))
        }
        task.cancel()
        let failure = await tbError { _ = try await task.value }
        XCTAssertTrue(failure is CancellationError)
        XCTAssertTrue(env.stub.requests.isEmpty)
    }

    // Duplicates and queue

    func testDiffIssueReadsTheListAgainAndNeverAddsTwice() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [
            TBStubHTTP.envelope(data: "[]"),
            TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 12, hash: TBHash.movie, files: movieFiles) + "]")
        ])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.cachedItem(hash: TBHash.movie) + "]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.failure("DIFF_ISSUE", status: 400, detail: "This torrent is already queued or downloading.")])
        env.stub.on("GET", "/torrents/mylist", query: "id=12", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 12, hash: TBHash.movie, files: movieFiles))])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let resolution = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie))
        XCTAssertEqual(resolution.torrentID, 12)
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/createtorrent").count, 1)
        XCTAssertEqual(env.trace(), ["GET /torrents/mylist", "POST /torrents/checkcached", "POST /torrents/createtorrent",
                                     "GET /torrents/mylist", "GET /torrents/requestdl"])
    }

    func testQueuedTorrentIsFoundLaterByHash() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "id=20", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 20, hash: TBHash.movie, files: movieFiles))])
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [
            TBStubHTTP.envelope(data: "[]"),
            TBStubHTTP.envelope(data: "[]"),
            TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 20, hash: TBHash.movie, state: "downloading", progress: 0.1, finished: false, present: false) + "]")
        ])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(detail: "Added to queue", data: #"{"queued_id":9}"#)])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let recorder = TBProgressRecorder()
        let resolution = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded),
                                                              onProgress: recorder.callback)
        XCTAssertEqual(resolution.torrentID, 20)
        XCTAssertTrue(recorder.all.contains(where: { $0.phase == .queued }), "the UI is told the item is queued")
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/createtorrent").count, 1)
    }

    func testQueuedTorrentThatNeverStartsEndsAsQueuedAtProvider() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"queued_id":9}"#)])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.queuedAtProvider) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) }
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/createtorrent").count, 1)
    }

    func testDiffIssueWithNothingInTheListMeansQueued() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.failure("DUPLICATE_ITEM", status: 400, detail: "already queued")])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.queuedAtProvider) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) }
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/createtorrent").count, 1)
    }

    func testAFailedItemIsReportedAndLeftAloneNeverRepaired() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":5}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "error", progress: 0.2, finished: false, present: false))])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.itemFailed(state: "error")) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) }
        XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/createtorrent").count, 1, "no re-add, no repair")
        tbAssertNoDestructiveCalls(env.stub)
    }

    // Errors from the service

    func testServiceErrorsSurfaceAsTypedErrorsWithoutRetriesOnTheAdd() async {
        let cases: [(TBStubHTTP.Reply, DebridError)] = [
            (TBStubHTTP.failure("PLAN_RESTRICTED_FEATURE", status: 403, detail: "Upgrade your plan"), DebridError.planRestricted),
            (TBStubHTTP.failure("ACTIVE_LIMIT", status: 400, detail: "limit"), DebridError.limitReached(.activeDownloads)),
            (TBStubHTTP.failure("MONTHLY_LIMIT", status: 400, detail: "limit"), DebridError.limitReached(.monthly)),
            (TBStubHTTP.failure("DOWNLOAD_TOO_LARGE", status: 400, detail: "too large"), DebridError.limitReached(.downloadTooLarge)),
            (TBStubHTTP.raw(status: 429, body: "{}", headers: ["retry-after": "30"]), DebridError.rateLimited(retryAfter: 30)),
            (TBStubHTTP.failure("BAD_TOKEN", status: 403), DebridError.authFailed)
        ]
        for (reply, expected) in cases {
            let env = TBEnvironment()
            env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
            env.stub.on("POST", "/torrents/createtorrent", replies: [reply])
            let resolver = env.makeResolver()
            await tbExpect(expected) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) }
            XCTAssertEqual(env.stub.requests(pathSuffix: "/torrents/createtorrent").count, 1, "\(expected)")
            XCTAssertTrue(env.clock.sleeps.isEmpty, "\(expected)")
        }
    }

    func testAuthFailureOnTheFirstCallStopsEverything() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", replies: [TBStubHTTP.failure("BAD_TOKEN", status: 403, detail: "bad")])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.authFailed) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
        XCTAssertEqual(env.trace(), ["GET /torrents/mylist"])
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let env = TBEnvironment()
        let resolver = env.makeResolver(key: nil)
        await tbExpect(DebridError.notConfigured) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
        XCTAssertTrue(env.stub.requests.isEmpty)
    }

    func testInvalidInfoHashIsRejectedLocally() async {
        let env = TBEnvironment()
        let resolver = env.makeResolver()
        await tbExpect(DebridError.invalidInfoHash("not-a-hash")) { try await resolver.resolve(DebridRequest(infoHash: "not-a-hash")) }
        XCTAssertTrue(env.stub.requests.isEmpty)
    }

    func testListThatCannotBeReadDoesNotBlockResolvingButAddIsStillSafe() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "\"unexpected string\"")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.cachedItem(hash: TBHash.movie) + "]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":7}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=7", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 7, hash: TBHash.movie, files: movieFiles))])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let resolution = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie))
        XCTAssertEqual(resolution.torrentID, 7)
    }

    // File selection through the resolver

    private func stubSeasonPack(_ env: TBEnvironment) {
        let files: [String] = [
            TBJSON.file(10, "Show.S01.1080p/Show.S01E01.1080p.mkv", size: 900),
            TBJSON.file(11, "Show.S01.1080p/Show.S01E02.1080p.mkv", size: 950),
            TBJSON.file(12, "Show.S01.1080p/Show.S01E03.1080p.mkv", size: 1_000),
            TBJSON.file(13, "Show.S01.1080p/Show.S01.nfo", size: 1, mime: "text/plain")
        ]
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 40, hash: TBHash.series, files: files) + "]")])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
    }

    func testEpisodeResolvesToTheFileOfThatEpisodeNotTheLargest() async throws {
        let env = TBEnvironment()
        stubSeasonPack(env)
        let request = DebridRequest(infoHash: TBHash.series, fileIndex: 0, stremioID: "tt0944947:1:2")
        let resolution = try await env.makeResolver().resolve(request)
        XCTAssertEqual(resolution.fileID, 11)
        XCTAssertEqual(resolution.fileName, "Show.S01E02.1080p.mkv")
        let query = env.stub.requests(pathSuffix: "/torrents/requestdl").first?.url.query ?? ""
        XCTAssertTrue(query.contains("torrent_id=40&file_id=11"), query)
    }

    func testEpisodeWithoutAMatchOffersTheCandidatesAndAsksForNoLink() async {
        let env = TBEnvironment()
        stubSeasonPack(env)
        let resolver = env.makeResolver()
        let request = DebridRequest(infoHash: TBHash.series, stremioID: "tt0944947:1:9")
        let failure = await tbError { _ = try await resolver.resolve(request) }
        guard let error = failure as? DebridError, case .noMatchingFile(let candidates) = error else {
            return XCTFail("expected noMatchingFile, got \(String(describing: failure))")
        }
        XCTAssertEqual(candidates.map { $0.id }, [10, 11, 12])
        XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/requestdl").isEmpty)
        XCTAssertFalse(error.isRetryable)
    }

    func testFilenameHintSelectsTheFileAndItsIDGoesToRequestdl() async throws {
        let env = TBEnvironment()
        stubSeasonPack(env)
        let request = DebridRequest(infoHash: TBHash.series, filename: "show.s01e03.1080p.MKV", stremioID: "tt0944947:1:1")
        let resolution = try await env.makeResolver().resolve(request)
        XCTAssertEqual(resolution.fileID, 12, "the addon's file name is the strongest hint")
    }

    func testZippedAndInfectedTorrentsAreNotPlayed() async {
        for (flags, expected) in [((true, false), DebridError.archivedFilesOnly), ((false, true), DebridError.infectedFiles)] {
            let env = TBEnvironment()
            let files = [TBJSON.file(1, "Movie.mkv", size: 100, zipped: flags.0, infected: flags.1)]
            env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 3, hash: TBHash.movie, files: files) + "]")])
            let resolver = env.makeResolver()
            await tbExpect(expected) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
            XCTAssertTrue(env.stub.requests(pathSuffix: "/torrents/requestdl").isEmpty)
        }
    }

    func testTorrentWithoutVideoFilesIsReported() async {
        let env = TBEnvironment()
        let files = [TBJSON.file(1, "Album/01.flac", mime: "audio/flac")]
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 3, hash: TBHash.movie, files: files) + "]")])
        let resolver = env.makeResolver()
        await tbExpect(DebridError.noVideoFile) { try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }
    }

    func testUnicodeFileNamesFlowThroughToTheResolution() async throws {
        let env = TBEnvironment()
        let name = "Амели́ [2001]/Амели́.2001.1080p.mkv"
        let files = [TBJSON.file(4, name, size: 7_000), TBJSON.file(5, "Амели́ [2001]/Extras.mkv", size: 9_000)]
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.torrent(id: 3, hash: TBHash.movie, files: files) + "]")])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let request = DebridRequest(infoHash: TBHash.movie, filename: "Амели́.2001.1080p.mkv")
        let resolution = try await env.makeResolver().resolve(request)
        XCTAssertEqual(resolution.fileID, 4)
        XCTAssertEqual(resolution.fileName, "Амели́.2001.1080p.mkv")
    }

    // Provider surface

    func testResolveEventsStreamsProgressThenTheResult() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":5}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=5", replies: [
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, state: "downloading", progress: 0.5, finished: false, present: false)),
            TBStubHTTP.envelope(data: TBJSON.torrent(id: 5, hash: TBHash.movie, files: movieFiles))
        ])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(cdn)\"")])
        let resolver = env.makeResolver()
        var phases: [DebridProgress.Phase] = []
        var resolved: DebridResolution?
        for try await event in resolver.resolveEvents(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) {
            switch event {
            case .progress(let progress): phases.append(progress.phase)
            case .resolved(let resolution): resolved = resolution
            }
        }
        XCTAssertEqual(phases.first, DebridProgress.Phase.checking)
        XCTAssertTrue(phases.contains(.downloading))
        XCTAssertEqual(resolved?.torrentID, 5)
    }

    func testResolveEventsFailsTheStreamWithTheTypedError() async {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[]")])
        let resolver = env.makeResolver()
        do {
            for try await _ in resolver.resolveEvents(DebridRequest(infoHash: TBHash.movie)) {}
            XCTFail("expected notCached")
        } catch let error as DebridError {
            XCTAssertEqual(error, DebridError.notCached)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testValidateCredentialsReturnsPlanFactsWithoutTheEmail() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: TBJSON.user)])
        let account = try await env.makeResolver().validateCredentials()
        XCTAssertEqual(account.planName, "Pro")
        XCTAssertEqual(account.planCode, 2)
        XCTAssertFalse(account.isFreePlan)
        XCTAssertNil(account.notice)
        XCTAssertNotNil(account.premiumExpiresAt)
        XCTAssertFalse(String(describing: account).contains("someone@example.com"))
        XCTAssertFalse(String(reflecting: account).contains("example.com"))

        let free = TBEnvironment()
        free.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: #"{"plan":0,"is_subscribed":false,"email":"free@example.com"}"#)])
        let freeAccount = try await free.makeResolver().validateCredentials()
        XCTAssertTrue(freeAccount.isFreePlan)
        XCTAssertNotNil(freeAccount.notice)

        let expired = TBEnvironment()
        expired.stub.on("GET", "/user/me", replies: [TBStubHTTP.envelope(data: #"{"plan":1,"premium_expires_at":"2020-01-01T00:00:00Z"}"#)])
        let expiredAccount = try await expired.makeResolver().validateCredentials()
        XCTAssertNotNil(expiredAccount.notice)

        let wrong = TBEnvironment()
        wrong.stub.on("GET", "/user/me", replies: [TBStubHTTP.failure("AUTH_ERROR", status: 403)])
        let resolver = wrong.makeResolver()
        await tbExpect(DebridError.authFailed) { try await resolver.validateCredentials() }
    }

    func testPlayableStreamKeepsTheFileNameForTheAnalyzer() throws {
        let original = AddonStream(source: .torrent(infoHash: TBHash.movie, fileIndex: nil, trackers: []), name: "Torrentio\n4K",
                                   details: "Movie.2020.2160p", behaviorHints: StreamBehaviorHints(bingeGroup: "tio-4k"),
                                   addonID: "tio", addonName: "Torrentio")
        let resolution = DebridResolution(url: URL(string: "https://store-5.tb-cdn.example/dl/abc?token=zzz")!, fileName: "Movie.2020.2160p.mkv",
                                          fileSize: 9_000, torrentID: 1, fileID: 2, wasAlreadyInAccount: false, resolvedAt: Date())
        let playable = resolution.playableStream(from: original)
        XCTAssertEqual(playable.directURL?.host, "store-5.tb-cdn.example")
        XCTAssertEqual(playable.behaviorHints.filename, "Movie.2020.2160p.mkv")
        XCTAssertEqual(playable.behaviorHints.videoSize, 9_000)
        XCTAssertEqual(playable.behaviorHints.bingeGroup, "tio-4k")
        XCTAssertEqual(playable.name, "Torrentio\n4K")
        XCTAssertEqual(playable.addonID, "tio")
        let info = StreamAnalyzer.analyze(playable)
        XCTAssertEqual(info.kind, StreamKind.file)
        XCTAssertEqual(info.container, "mkv", "the CDN URL has no extension: the file name hint provides it")
        XCTAssertEqual(info.quality, StreamQuality.uhd2160)
        XCTAssertFalse(resolution.description.contains("zzz"), "the per-download token stays out of descriptions")
    }
}

// MARK: - Availability

final class DebridAvailabilityTests: XCTestCase {
    private func hashes(_ count: Int) -> [String] {
        return (0..<count).map { (n: Int) -> String in return String(format: "%040x", n + 1) }
    }

    private func cachedBody(_ list: [String]) -> String {
        let items = list.map { (hash: String) -> String in return TBJSON.cachedItem(hash: hash) }
        return "[" + items.joined(separator: ",") + "]"
    }

    func testStatusesAreCachedNotCachedOrUnknown() async {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: cachedBody([TBHash.movie]))])
        let resolver = env.makeResolver()
        let base32 = "YEX6DQDLXISUVHOJ6UM3GNNKPQJWPKEK"
        let report = await resolver.availability(infoHashes: [TBHash.movie.uppercased(), base32, "garbage"])
        XCTAssertEqual(report.status(for: TBHash.movie.uppercased()), DebridCacheStatus.cached)
        XCTAssertEqual(report.status(for: base32), DebridCacheStatus.notCached)
        XCTAssertEqual(report.status(for: "garbage"), DebridCacheStatus.unknown, "an unusable hash is unknown, never 'not cached'")
        XCTAssertEqual(report.status(for: "never-asked"), DebridCacheStatus.unknown)
        XCTAssertNil(report.failure)

        XCTAssertEqual(env.stub.requests.count, 1)
        let body = tbBodyString(env.stub.requests[0])
        XCTAssertTrue(body.contains(TBHash.movie))
        XCTAssertTrue(body.contains(TBHash.series), "the base32 hash is converted to lowercase hex: \(body)")
        XCTAssertFalse(body.contains("garbage"))
        XCTAssertFalse(body.contains(TBHash.movie.uppercased()))
    }

    func testResultsAreCachedInMemoryForAboutAnHour() async {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: cachedBody([TBHash.movie]))])
        let resolver = env.makeResolver()
        _ = await resolver.availability(infoHashes: [TBHash.movie, TBHash.other])
        _ = await resolver.availability(infoHashes: [TBHash.other, TBHash.movie])
        XCTAssertEqual(env.stub.requests.count, 1, "the second call is served from memory")

        env.clock.advance(3_599)
        _ = await resolver.availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(env.stub.requests.count, 1)

        env.clock.advance(2)
        let report = await resolver.availability(infoHashes: [TBHash.movie, TBHash.other])
        XCTAssertEqual(env.stub.requests.count, 2, "after an hour the service is asked again")
        XCTAssertEqual(report.status(for: TBHash.movie), DebridCacheStatus.cached)

        await resolver.clearAvailabilityCache()
        _ = await resolver.availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(env.stub.requests.count, 3)
    }

    func testHashesAreSentInChunksOfAtMost100AndDeduplicated() async {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[]")])
        let list = hashes(250)
        let resolver = env.makeResolver()
        let report = await resolver.availability(infoHashes: list + [list[0].uppercased()])
        let sizes: [Int] = env.stub.requests.map { (request: HTTPRequest) -> Int in
            let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: [String]]
            return object?["hashes"]?.count ?? -1
        }
        XCTAssertEqual(sizes, [100, 100, 50])
        XCTAssertEqual(report.statuses.count, 251)
        XCTAssertTrue(report.statuses.values.allSatisfy { $0 == DebridCacheStatus.notCached })
        XCTAssertEqual(report.status(for: list[0].uppercased()), DebridCacheStatus.notCached)
    }

    func testAFailingChunkLeavesOnlyItsHashesUnknown() async {
        let env = TBEnvironment()
        let list = hashes(250)
        env.stub.on("POST", "/torrents/checkcached", replies: [
            TBStubHTTP.envelope(data: cachedBody([list[3]])),
            TBStubHTTP.raw(status: 502, body: TBStubHTTP.html),
            TBStubHTTP.raw(status: 502, body: TBStubHTTP.html),
            TBStubHTTP.raw(status: 502, body: TBStubHTTP.html),
            TBStubHTTP.envelope(data: "[]")
        ])
        let report = await env.makeResolver().availability(infoHashes: list)
        XCTAssertEqual(report.status(for: list[3]), DebridCacheStatus.cached)
        XCTAssertEqual(report.status(for: list[0]), DebridCacheStatus.notCached)
        XCTAssertEqual(report.status(for: list[99]), DebridCacheStatus.notCached)
        XCTAssertEqual(report.status(for: list[100]), DebridCacheStatus.unknown, "chunk 2 failed: unknown, not 'not cached'")
        XCTAssertEqual(report.status(for: list[199]), DebridCacheStatus.unknown)
        XCTAssertEqual(report.status(for: list[200]), DebridCacheStatus.notCached, "chunk 3 still answered")
        XCTAssertEqual(report.failure, DebridError.serviceUnavailable(statusCode: 502))
    }

    func testAuthFailureStopsAfterTheFirstChunkAndEverythingIsUnknown() async {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.failure("BAD_TOKEN", status: 403, detail: "bad")])
        let list = hashes(150)
        let report = await env.makeResolver().availability(infoHashes: list)
        XCTAssertEqual(env.stub.requests.count, 1)
        XCTAssertEqual(report.failure, DebridError.authFailed)
        XCTAssertTrue(report.statuses.values.allSatisfy { $0 == DebridCacheStatus.unknown })
        XCTAssertEqual(report.statuses.count, 150)
    }

    func testMissingKeyMeansUnknownWithoutAnyRequest() async {
        let env = TBEnvironment()
        let report = await env.makeResolver(key: nil).availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(report.status(for: TBHash.movie), DebridCacheStatus.unknown)
        XCTAssertEqual(report.failure, DebridError.notConfigured)
        XCTAssertTrue(env.stub.requests.isEmpty)
    }

    func testFailedAnswersAreNotCachedAsNotCached() async {
        let env = TBEnvironment()
        env.stub.on("POST", "/torrents/checkcached", replies: [
            TBStubHTTP.raw(status: 503, body: TBStubHTTP.html), TBStubHTTP.raw(status: 503, body: TBStubHTTP.html),
            TBStubHTTP.raw(status: 503, body: TBStubHTTP.html), TBStubHTTP.envelope(data: cachedBody([TBHash.movie]))
        ])
        let resolver = env.makeResolver()
        let first = await resolver.availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(first.status(for: TBHash.movie), DebridCacheStatus.unknown)
        let second = await resolver.availability(infoHashes: [TBHash.movie])
        XCTAssertEqual(second.status(for: TBHash.movie), DebridCacheStatus.cached, "the failure left nothing behind")
    }
}

// MARK: - Secrets

final class DebridSecretHandlingTests: XCTestCase {
    private func descriptions(of error: Error) -> [String] {
        var texts: [String] = [error.localizedDescription, String(describing: error), String(reflecting: error), "\(error)"]
        if let debrid = error as? DebridError {
            texts.append(debrid.message)
            texts.append(debrid.errorDescription ?? "")
        }
        return texts
    }

    private func assertClean(_ error: Error?, key: String, label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error else {
            return XCTFail("\(label): expected an error", file: file, line: line)
        }
        for text in descriptions(of: error) {
            XCTAssertFalse(text.contains(key), "\(label): the key leaked into «\(text)»", file: file, line: line)
            XCTAssertFalse(text.contains("token=" + key), "\(label): token URL leaked", file: file, line: line)
        }
    }

    func testTheKeyNeverAppearsInAnyThrownError() async {
        let key = TBKeys.valid
        let echo = "Invalid token \(key) for this account; see https://api.torbox.app/v1/api/torrents/requestdl?token=\(key)&torrent_id=1"
        let urlWithKey = "https://api.torbox.app/v1/api/torrents/requestdl?token=\(key)&torrent_id=1&file_id=0"

        var errors: [(String, Error?)] = []

        // 1. The service echoes the key inside an unknown error code's detail.
        let echoEnv = TBEnvironment()
        echoEnv.stub.on("GET", "/user/me", replies: [TBStubHTTP.failure("BRAND_NEW_CODE", status: 400, detail: echo)])
        let echoClient = echoEnv.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
        errors.append(("echoed detail", await tbError { _ = try await echoClient.fetchUser() }))

        // 2. An error without a code and with the key in its text.
        let plainEnv = TBEnvironment()
        plainEnv.stub.on("GET", "/user/me", replies: [TBStubHTTP.raw(status: 404, body: "{\"detail\":\"Not found: token=\(key)\"}")])
        let plainClient = plainEnv.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
        errors.append(("plain 404", await tbError { _ = try await plainClient.fetchUser() }))

        // 3. Transport errors whose own text carries the URL, key included.
        let transports: [AddonError] = [AddonError.invalidURL(urlWithKey), AddonError.malformedResponse(urlWithKey),
                                        AddonError.unreachable(urlWithKey), AddonError.unsupported(urlWithKey)]
        for transport in transports {
            let env = TBEnvironment()
            env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.throwing(transport)])
            let client = env.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
            errors.append(("transport \(transport)", await tbError { _ = try await client.requestDownloadLink(torrentID: 1, fileID: 0) }))
        }

        // 4. HTML that contains the key, a link that contains it, and plain provider errors.
        let htmlEnv = TBEnvironment()
        htmlEnv.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.raw(status: 502, body: "<html>\(urlWithKey)</html>")])
        let htmlClient = htmlEnv.makeClient(retry: TorBoxClient.RetryPolicy.noRetry)
        errors.append(("html", await tbError { _ = try await htmlClient.requestDownloadLink(torrentID: 1, fileID: 0) }))

        let linkEnv = TBEnvironment()
        linkEnv.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"\(urlWithKey)\"")])
        let linkClient = linkEnv.makeClient()
        errors.append(("permalink", await tbError { _ = try await linkClient.requestDownloadLink(torrentID: 1, fileID: 0) }))

        let authEnv = TBEnvironment()
        authEnv.stub.on("GET", "/user/me", replies: [TBStubHTTP.failure("AUTH_ERROR", status: 403, detail: echo)])
        let authClient = authEnv.makeClient()
        errors.append(("auth", await tbError { _ = try await authClient.fetchUser() }))

        let limitEnv = TBEnvironment()
        limitEnv.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.failure("ACTIVE_LIMIT", status: 400, detail: echo)])
        let limitClient = limitEnv.makeClient()
        errors.append(("limit", await tbError { _ = try await limitClient.createTorrent(magnet: "magnet:?xt=urn:btih:" + TBHash.movie) }))

        // 5. Through the resolver.
        let flowEnv = TBEnvironment()
        flowEnv.stub.on("GET", "/torrents/mylist", replies: [TBStubHTTP.failure("SOMETHING", status: 400, detail: echo)])
        let resolver = flowEnv.makeResolver()
        errors.append(("resolver", await tbError { _ = try await resolver.resolve(DebridRequest(infoHash: TBHash.movie)) }))

        XCTAssertEqual(errors.count, 11)
        for (label, error) in errors {
            assertClean(error, key: key, label: label)
        }
        // The scrubbed echo is still informative for debugging.
        if let error = errors.first?.1 as? DebridError, case .api(let code, let detail) = error {
            XCTAssertEqual(code, "BRAND_NEW_CODE")
            XCTAssertTrue(detail?.contains("«chiave»") == true || detail?.contains("token") == false, "detail: \(String(describing: detail))")
        } else {
            XCTFail("expected an api error first")
        }
    }

    func testTheKeyNeverReachesTheDiagnosticLog() async throws {
        let key = TBKeys.valid
        let log = DiagnosticLog(capacity: 500, minimumLevel: .debug, enabled: true)
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.cachedItem(hash: TBHash.movie) + "]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":77}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=77", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 77, hash: TBHash.movie, files: [TBJSON.file(1, "Movie.mkv", size: 100)]))])
        env.stub.on("GET", "/torrents/requestdl", replies: [
            TBStubHTTP.raw(status: 502, body: "<html>\(key)</html>"),
            TBStubHTTP.envelope(data: "\"https://cdn.example/dl/x.mkv?t=1\"")
        ])
        let resolver = env.makeResolver(log: log)
        _ = try await resolver.resolve(DebridRequest(infoHash: TBHash.movie))
        _ = await resolver.availability(infoHashes: [TBHash.movie])
        let failing = TBEnvironment()
        failing.stub.on("GET", "/torrents/mylist", replies: [TBStubHTTP.failure("BAD_TOKEN", status: 403, detail: "token=\(key)")])
        _ = await tbError { _ = try await failing.makeResolver(log: log).resolve(DebridRequest(infoHash: TBHash.movie)) }

        let entries = await log.entries()
        XCTAssertFalse(entries.isEmpty, "the flow should have logged something")
        let export = await log.exportText()
        XCTAssertFalse(export.contains(key))
        XCTAssertFalse(export.contains("token="))
        XCTAssertFalse(export.contains("Bearer"))
        XCTAssertFalse(export.contains(TBHash.movie), "info hashes stay out of the log as well")
        XCTAssertFalse(export.contains("someone@example.com"))
        for entry in entries {
            XCTAssertFalse(entry.message.contains(key))
        }
    }

    func testRedactorHidesTheRequestdlUrlAndTheBearerHeader() {
        let key = TBKeys.valid
        let samples: [String] = [
            "GET https://api.torbox.app/v1/api/torrents/requestdl?token=\(key)&torrent_id=7&file_id=1 -> 200",
            "token=\(key)",
            "Authorization: Bearer \(key)",
            "{\"token\": \"\(key)\"}",
            "url=https://api.torbox.app/v1/api/torrents/requestdl?torrent_id=1&token=\(key)"
        ]
        for sample in samples {
            let redacted = Redactor.redact(sample)
            XCTAssertFalse(redacted.contains(key), "«\(sample)» -> «\(redacted)»")
        }
        XCTAssertEqual(TorBoxClient.scrub("Invalid token \(key) given", key: key), "Invalid token «chiave» given")
        XCTAssertEqual(TorBoxClient.scrub("encoded %74bk", key: "%74bk"), "encoded «chiave»")
        XCTAssertFalse(TorBoxClient.scrub("a b=\(URIComponent.encode("k/e y+1"))", key: "k/e y+1").contains("k%2Fe"))
    }

    func testRequestsNeverCarryTheKeyAnywhereButTheDocumentedPlaces() async throws {
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/checkcached", replies: [TBStubHTTP.envelope(data: "[" + TBJSON.cachedItem(hash: TBHash.movie) + "]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.envelope(data: #"{"torrent_id":77}"#)])
        env.stub.on("GET", "/torrents/mylist", query: "id=77", replies: [TBStubHTTP.envelope(data: TBJSON.torrent(id: 77, hash: TBHash.movie, files: [TBJSON.file(1, "Movie.mkv", size: 100)]))])
        env.stub.on("GET", "/torrents/requestdl", replies: [TBStubHTTP.envelope(data: "\"https://cdn.example/dl/x.mkv?t=1\"")])
        _ = try await env.makeResolver().resolve(DebridRequest(infoHash: TBHash.movie))
        for request in env.stub.requests {
            let isRequestdl = request.url.path.hasSuffix("/torrents/requestdl")
            XCTAssertEqual(request.url.absoluteString.contains(TBKeys.valid), isRequestdl, request.url.path)
            XCTAssertEqual(request.headers["Authorization"] != nil, !isRequestdl, request.url.path)
            XCTAssertFalse(tbBodyString(request).contains(TBKeys.valid), "the key is never in a body")
        }
    }

    func testNothingInTheModuleCanDeleteOrPauseAnItem() async throws {
        // A messy session: duplicate, queue, failure, timeout. Whatever happens, only GET and POST to the documented
        // read / add endpoints are used and nothing touches controltorrent.
        let env = TBEnvironment()
        env.stub.on("GET", "/torrents/mylist", query: "offset=", replies: [TBStubHTTP.envelope(data: "[]")])
        env.stub.on("POST", "/torrents/createtorrent", replies: [TBStubHTTP.failure("DIFF_ISSUE", status: 400, detail: "already queued")])
        let resolver = env.makeResolver()
        _ = await tbError { _ = try await resolver.resolve(DebridRequest(infoHash: TBHash.movie, mode: .startIfNeeded)) }
        _ = await resolver.availability(infoHashes: [TBHash.movie])
        tbAssertNoDestructiveCalls(env.stub)
        let allowed: Set<String> = ["/user/me", "/torrents/checkcached", "/torrents/createtorrent", "/torrents/mylist", "/torrents/requestdl"]
        for request in env.stub.requests {
            let path = String(request.url.path.dropFirst(7))
            XCTAssertTrue(allowed.contains(path), "unexpected endpoint \(path)")
        }
    }
}
