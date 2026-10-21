import XCTest
@testable import AetherCore

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 1_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

final class SkipSegmentsTests: XCTestCase {
    /// The answer api.introdb.app gave for Game of Thrones S1E1 (read from a GitHub runner on 2026-10-21, no credential).
    private let realAnswer = #"{"imdb_id":"tt0944947","media_type":"tv","is_movie":false,"season":1,"episode":1,"intro":{"start_sec":437,"end_sec":531,"start_ms":437000,"end_ms":531000,"confidence":1,"submission_count":2,"updated_at":"2026-06-16T02:49:39.823Z"},"recap":null,"outro":{"start_sec":3631.5,"end_sec":3699.5,"start_ms":3631500,"end_ms":3699500,"confidence":1,"submission_count":2,"updated_at":"2026-04-08T18:48:22.562Z"},"post_credits":null,"no_intro":false,"no_recap":true,"no_outro":false}"#
    private let url = "https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=1"

    private func service(_ server: FakeServer, clock: TestClock = TestClock()) -> SkipSegmentsService {
        return SkipSegmentsService(client: IntroDBClient(http: server), now: { clock.now })
    }

    // MARK: Client

    func testReadsTheRealAnswerAndAsksTheDocumentedAddress() async throws {
        let server = FakeServer()
        server.set(url, json: realAnswer)
        let found = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertEqual(found.intro, SkipSegment(kind: .intro, start: 437, end: 531))
        XCTAssertNil(found.recap, "the answer has no recap")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url.absoluteString, url)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertNil(request.headers["Authorization"], "no credential is involved")
    }

    func testReadsARecapAndMillisecondsWhenSecondsAreMissing() async throws {
        let server = FakeServer()
        server.set(url, json: #"{"intro":{"start_ms":100000,"end_ms":190500},"recap":{"start_sec":0,"end_sec":62.5},"outro":null}"#)
        let found = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertEqual(found.recap, SkipSegment(kind: .recap, start: 0, end: 62.5))
        XCTAssertEqual(found.intro, SkipSegment(kind: .intro, start: 100, end: 190.5))
    }

    func testNonsenseSegmentsAreDropped() async throws {
        let server = FakeServer()
        server.set(url, json: #"{"intro":{"start_sec":50,"end_sec":40},"recap":{"start_sec":10,"end_sec":11}}"#)
        var found = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertTrue(found.isEmpty, "an end before the start and a one second recap are not offered")
        server.set(url, json: #"{"intro":{"start_sec":0,"end_sec":700},"recap":{"start_sec":-5,"end_sec":60}}"#)
        found = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertTrue(found.isEmpty, "a 700 s intro and a negative start are not offered")
        server.set(url, json: #"{"intro":null,"recap":null,"no_intro":true}"#)
        found = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertTrue(found.isEmpty)
    }

    func testAnUnreadableAnswerIsMalformedAndAServerErrorIsUnavailable() async {
        let server = FakeServer()
        server.set(url, body: Data("<html>oops</html>".utf8))
        do {
            _ = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SkipSegmentsError, .malformed)
        }
        server.set(url, json: "{}", status: 503)
        do {
            _ = try await IntroDBClient(http: server).segments(imdbID: "tt0944947", season: 1, episode: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SkipSegmentsError, .unavailable)
        }
    }

    func testRequestsThatCouldNotBeRightAreNotSent() async {
        let server = FakeServer()
        let client = IntroDBClient(http: server)
        for (id, season, episode) in [("kitsu:1", 1, 1), ("tt12", 1, 1), ("tt0944947\n", 1, 1), ("tt0944947", -1, 1), ("tt0944947", 1, -2)] {
            do {
                _ = try await client.segments(imdbID: id, season: season, episode: episode)
                XCTFail("«\(id)» \(season)x\(episode) should be refused")
            } catch {
                XCTAssertEqual(error as? SkipSegmentsError, .invalidRequest)
            }
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testOnlyTheProductionHostOrALoopbackFixtureIsAsked() async throws {
        let server = FakeServer()
        for base in ["http://api.introdb.app", "https://evil.example", "ftp://api.introdb.app"] {
            do {
                _ = try await IntroDBClient(http: server, baseURL: URL(string: base)!).segments(imdbID: "tt0944947", season: 1, episode: 1)
                XCTFail("\(base) must be refused")
            } catch {
                XCTAssertEqual(error as? SkipSegmentsError, .untrustedHost, base)
            }
        }
        XCTAssertTrue(server.requests.isEmpty)
        server.set("http://127.0.0.1:7777/segments?imdb_id=tt0944947&season=1&episode=1", json: realAnswer)
        let found = try await IntroDBClient(http: server, baseURL: URL(string: "http://127.0.0.1:7777")!)
            .segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertNotNil(found.intro, "a loopback fixture server is accepted (UI tests)")
    }

    // MARK: Service

    func testWhatIsFoundIsRememberedForADayAndThenAskedAgain() async {
        let server = FakeServer(), clock = TestClock()
        server.set(url, json: realAnswer)
        let service = self.service(server, clock: clock)
        let first = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        let second = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertEqual(first, second)
        XCTAssertEqual(server.requests.count, 1)
        clock.advance(25 * 3600)
        _ = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAnEpisodeTheServiceDoesNotKnowIsNotAskedAgainSoon() async {
        let server = FakeServer(), clock = TestClock()   // unknown address: 404
        let service = self.service(server, clock: clock)
        let first = await service.segments(imdbID: "tt0944947", season: 9, episode: 9)
        XCTAssertEqual(first, EpisodeSkipSegments.none, "404 means: nothing known")
        _ = await service.segments(imdbID: "tt0944947", season: 9, episode: 9)
        XCTAssertEqual(server.requests.count, 1)
        clock.advance(7 * 3600)
        _ = await service.segments(imdbID: "tt0944947", season: 9, episode: 9)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testConcurrentLookupsOfTheSameEpisodeAskOnce() async {
        let server = FakeServer()
        server.set(url, json: realAnswer, delay: 0.15)
        let service = self.service(server)
        await withTaskGroup(of: EpisodeSkipSegments?.self) { group in
            for _ in 0..<6 {
                group.addTask { await service.segments(imdbID: "tt0944947", season: 1, episode: 1) }
            }
            for await result in group { XCTAssertNotNil(result?.intro) }
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testARateLimitPausesEveryLookupForAWhile() async {
        let server = FakeServer(), clock = TestClock()
        server.set(url, json: "{}", status: 429)
        server.set("https://api.introdb.app/segments?imdb_id=tt0944947&season=1&episode=2", json: realAnswer)
        let service = self.service(server, clock: clock)
        let limited = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertNil(limited)
        let other = await service.segments(imdbID: "tt0944947", season: 1, episode: 2)
        XCTAssertNil(other, "paused: the next episode is not asked either")
        XCTAssertEqual(server.requests.count, 1)
        clock.advance(121)
        let later = await service.segments(imdbID: "tt0944947", season: 1, episode: 2)
        XCTAssertNotNil(later?.intro)
    }

    func testAnOutageBacksOffAndThenTriesAgain() async {
        let server = FakeServer(), clock = TestClock()
        server.set(url, json: "{}", status: 503)
        let service = self.service(server, clock: clock)
        let down = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertNil(down)
        _ = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertEqual(server.requests.count, 1, "not asked again at once")
        clock.advance(61)
        server.set(url, json: realAnswer)
        let back = await service.segments(imdbID: "tt0944947", season: 1, episode: 1)
        XCTAssertNotNil(back?.intro)
    }

    // MARK: Which segment is on offer

    func testTheButtonIsOfferedFromJustBeforeTheSegmentUntilJustBeforeItsEnd() {
        let segments = EpisodeSkipSegments(intro: SkipSegment(kind: .intro, start: 437, end: 531))
        XCTAssertNil(segments.active(at: 400))
        XCTAssertNil(segments.active(at: 435.9), "more than a second early")
        XCTAssertEqual(segments.active(at: 436.5)?.kind, .intro)
        XCTAssertEqual(segments.active(at: 500)?.kind, .intro)
        XCTAssertEqual(segments.active(at: 529.9)?.kind, .intro)
        XCTAssertNil(segments.active(at: 530.2), "the last second is not worth a button")
        XCTAssertNil(segments.active(at: 600))
    }

    func testNoButtonForANegativeOrNotANumberPosition() {
        let segments = EpisodeSkipSegments(intro: SkipSegment(kind: .intro, start: 0, end: 90))
        XCTAssertNil(segments.active(at: -1))
        XCTAssertNil(segments.active(at: .nan))
        XCTAssertEqual(segments.active(at: 0)?.kind, .intro)
    }

    func testAnEpisodeShorterThanTheSegmentIsAnotherCutAndGetsNoButton() {
        let segments = EpisodeSkipSegments(intro: SkipSegment(kind: .intro, start: 437, end: 531))
        XCTAssertNil(segments.active(at: 450, duration: 300))
        XCTAssertNotNil(segments.active(at: 450, duration: 3_400))
        XCTAssertNotNil(segments.active(at: 450, duration: nil), "an unknown duration does not block the button")
        XCTAssertNotNil(segments.active(at: 450, duration: 0))
    }

    func testTheRecapComesBeforeTheIntroWhenBothContainThePosition() {
        let segments = EpisodeSkipSegments(intro: SkipSegment(kind: .intro, start: 30, end: 120),
                                           recap: SkipSegment(kind: .recap, start: 0, end: 60))
        XCTAssertEqual(segments.active(at: 10)?.kind, .recap)
        XCTAssertEqual(segments.active(at: 45)?.kind, .recap)
        XCTAssertEqual(segments.active(at: 90)?.kind, .intro)
    }

    // MARK: Setting

    func testTheSettingIsOnByDefaultAndSurvivesASaveAndLoad() throws {
        let fromNothing = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(fromNothing.skipSegmentsEnabled, "settings saved before this existed get the default")
        var settings = PlaybackSettings()
        settings.skipSegmentsEnabled = false
        let loaded = try JSONDecoder().decode(PlaybackSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertFalse(loaded.skipSegmentsEnabled)
    }
}
