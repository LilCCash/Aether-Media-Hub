import XCTest
import AetherCore
@testable import Aether

// TorBox in the app, against a scripted copy of the API: nothing here leaves the process. The key is a made-up string and
// the e-mail address in the account answer exists only to prove that the app never keeps it.

private final class TorBoxStubHTTP: HTTPClient, @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: String
        var headers: [String: String]

        init(status: Int = 200, body: String, headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.headers = headers
        }
    }

    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) -> Answer

    init(handler: @escaping @Sendable (HTTPRequest) -> Answer) {
        self.handler = handler
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Paths below /v1/api, in the order they were asked ("/torrents/mylist").
    var paths: [String] {
        return requests.map { (request: HTTPRequest) -> String in
            let path = request.url.path
            if path.hasPrefix("/v1/api") { return String(path.dropFirst("/v1/api".count)) }
            return path
        }
    }

    private func record(_ request: HTTPRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        let answer = handler(request)
        return HTTPResponse(data: Data(answer.body.utf8), statusCode: answer.status, headers: answer.headers, url: request.url)
    }
}

private final class DebridCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func next(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let value = (counts[name] ?? 0) + 1
        counts[name] = value
        return value
    }
}

private final class DebridProgressLog: @unchecked Sendable {
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
}

private final class DebridTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private enum TorBoxJSON {
    static let email = "private.person@example.com"

    static func envelope(_ data: String, detail: String = "ok") -> String {
        return "{\"success\":true,\"error\":null,\"detail\":\"\(detail)\",\"data\":\(data)}"
    }

    static func failure(_ code: String) -> String {
        return "{\"success\":false,\"error\":\"\(code)\",\"detail\":\"scripted\",\"data\":null}"
    }

    static func user(plan: Int, expires: String?) -> String {
        let expiry: String = expires.map { (value: String) -> String in return "\"" + value + "\"" } ?? "null"
        let body = "{\"id\":7,\"email\":\"\(email)\",\"plan\":\(plan),\"is_subscribed\":true,"
            + "\"premium_expires_at\":\(expiry),\"cooldown_until\":null}"
        return envelope(body)
    }

    static func torrent(id: Int, hash: String, ready: Bool, progress: Double) -> String {
        let video = "{\"id\":41,\"name\":\"Slow.Download/Slow.Download.mkv\",\"short_name\":\"Slow.Download.mkv\","
            + "\"size\":700000000,\"mimetype\":\"video/x-matroska\"}"
        let files: String = ready ? "[" + video + "]" : "[]"
        let state: String = ready ? "completed" : "downloading"
        let speed: Int = ready ? 0 : 15_000_000
        let eta: Int = ready ? 0 : 4
        let flag: String = ready ? "true" : "false"
        var fields: [String] = []
        fields.append("\"id\":\(id)")
        fields.append("\"hash\":\"\(hash)\"")
        fields.append("\"name\":\"Slow.Download\"")
        fields.append("\"progress\":\(progress)")
        fields.append("\"download_state\":\"\(state)\"")
        fields.append("\"download_speed\":\(speed)")
        fields.append("\"eta\":\(eta)")
        fields.append("\"download_finished\":\(flag)")
        fields.append("\"download_present\":\(flag)")
        fields.append("\"files\":\(files)")
        return "{" + fields.joined(separator: ",") + "}"
    }
}

@MainActor
final class DebridServiceTests: XCTestCase {
    private let key = "unit-test-key-0123456789"
    private let slowHash = String(repeating: "3", count: 40)

    private func fixedClock() -> DebridClock {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        return DebridClock(now: { return date }, sleep: { (_: TimeInterval) async throws -> Void in })
    }

    private func makeService(http: HTTPClient, withKey: Bool = true,
                             clock: DebridClock) throws -> (service: DebridService, credentials: ServiceCredentials) {
        let credentials = ServiceCredentials(secrets: InMemorySecretStore())
        if withKey { try credentials.save(key, for: ServiceKind.torbox) }
        let service = DebridService(credentials: credentials, http: http, retry: TorBoxClient.RetryPolicy.noRetry, clock: clock)
        return (service: service, credentials: credentials)
    }

    private func torrentStream(hash: String, name: String = "Torrent") -> AddonStream {
        return AddonStream(source: StreamSource.torrent(infoHash: hash, fileIndex: nil, trackers: []), name: name)
    }

    private func resolution(url: String = "https://cdn.example.com/dl/abc", torrentID: Int = 5) -> DebridResolution {
        return DebridResolution(url: URL(string: url)!, fileName: "Movie.mkv", fileSize: 1_000, torrentID: torrentID,
                                fileID: 9, wasAlreadyInAccount: false, resolvedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: Connection status

    func testStatusStartsAsNotConfiguredWithoutAKeyAndNeverTouchesTheNetwork() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 500, body: "")
        }
        let (service, _) = try makeService(http: http, withKey: false, clock: fixedClock())
        XCTAssertEqual(service.status, DebridService.ConnectionStatus.notConfigured)
        XCTAssertFalse(service.isConfigured)
        let failure = await service.verifyConnection()
        XCTAssertNil(failure)
        XCTAssertEqual(service.status, DebridService.ConnectionStatus.notConfigured)
        XCTAssertTrue(http.requests.isEmpty, "without a key nothing may be asked of TorBox")
    }

    func testASavedKeyStartsAsUnverifiedUntilTorBoxIsAsked() throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 500, body: "")
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        XCTAssertEqual(service.status, DebridService.ConnectionStatus.unverified)
        XCTAssertTrue(service.isConfigured)
        XCTAssertTrue(http.requests.isEmpty, "creating the service does not call TorBox")
    }

    func testVerifyConnectionShowsPlanAndExpiryButNeverTheEmailOrTheKey() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.user(plan: 2, expires: "2031-03-04T10:00:00Z"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let failure = await service.verifyConnection()
        XCTAssertNil(failure)
        guard case DebridService.ConnectionStatus.connected(let account) = service.status else {
            XCTFail("expected a connected status")
            return
        }
        XCTAssertEqual(account.planName, "Pro")
        XCTAssertNotNil(account.expiresAt, "the expiry is shown because the API returned one")
        XCTAssertNil(account.notice)
        let printed = String(describing: service.status)
        XCTAssertFalse(printed.contains(TorBoxJSON.email), "the e-mail address of the account is never kept")
        XCTAssertFalse(printed.contains(key))

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.path, "/v1/api/user/me")
        XCTAssertEqual(request.headers["Authorization"], "Bearer " + key)
        XCTAssertFalse(request.url.absoluteString.contains(key), "the key travels in a header, not in the address")
    }

    func testWithoutAnExpiryInTheAnswerNoExpiryIsShown() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.user(plan: 1, expires: nil))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        _ = await service.verifyConnection()
        guard case DebridService.ConnectionStatus.connected(let account) = service.status else {
            XCTFail("expected a connected status")
            return
        }
        XCTAssertEqual(account.planName, "Essential")
        XCTAssertNil(account.expiresAt, "nothing is invented when the API does not say")
    }

    func testTheFreePlanHidesTheExpiryAndExplainsTheLimits() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.user(plan: 0, expires: "2031-03-04T10:00:00Z"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        _ = await service.verifyConnection()
        guard case DebridService.ConnectionStatus.connected(let account) = service.status else {
            XCTFail("expected a connected status")
            return
        }
        XCTAssertEqual(account.planName, "Free")
        XCTAssertNil(account.expiresAt)
        XCTAssertTrue(account.notice?.contains("Piano Free") == true)
    }

    func testAnExpiredSubscriptionIsSaidSoInsteadOfPretendingAllIsWell() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.user(plan: 2, expires: "2020-01-01T00:00:00Z"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        _ = await service.verifyConnection()
        guard case DebridService.ConnectionStatus.connected(let account) = service.status else {
            XCTFail("expected a connected status")
            return
        }
        XCTAssertTrue(account.notice?.contains("scaduto") == true)
    }

    func testARefusedKeyIsReportedWithAnItalianReasonAndNeverEchoed() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 403, body: TorBoxJSON.failure("AUTH_ERROR"), headers: ["retry-after": "60"])
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let failure = await service.verifyConnection()
        XCTAssertEqual(failure, DebridError.authFailed)
        guard case DebridService.ConnectionStatus.failed(let message) = service.status else {
            XCTFail("expected a failed status")
            return
        }
        XCTAssertTrue(message.contains("Chiave non valida"), "got: \(message)")
        XCTAssertFalse(message.contains(key))
    }

    func testRateLimitingAndAGatewayPageEachHaveTheirOwnReason() async throws {
        let limited = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 429, body: TorBoxJSON.failure("RATE_LIMIT_EXCEEDED"), headers: ["retry-after": "30"])
        }
        let (rateService, _) = try makeService(http: limited, clock: fixedClock())
        let rateFailure = await rateService.verifyConnection()
        XCTAssertEqual(rateFailure, DebridError.rateLimited(retryAfter: 30))
        guard case DebridService.ConnectionStatus.failed(let rateMessage) = rateService.status else {
            XCTFail("expected a failed status")
            return
        }
        XCTAssertTrue(rateMessage.contains("limitando"), "got: \(rateMessage)")
        XCTAssertTrue(rateMessage.contains("30"), "the wait asked by TorBox is shown, got: \(rateMessage)")

        let gateway = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 502, body: "<html><body>Bad gateway</body></html>")
        }
        let (gatewayService, _) = try makeService(http: gateway, clock: fixedClock())
        let gatewayFailure = await gatewayService.verifyConnection()
        XCTAssertEqual(gatewayFailure, DebridError.serviceUnavailable(statusCode: 502))
        guard case DebridService.ConnectionStatus.failed(let gatewayMessage) = gatewayService.status else {
            XCTFail("expected a failed status")
            return
        }
        XCTAssertTrue(gatewayMessage.contains("non risponde correttamente"), "got: \(gatewayMessage)")
    }

    func testAPlanThatDoesNotAllowTheFeatureIsReportedAsSuch() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 403, body: TorBoxJSON.failure("PLAN_RESTRICTED_FEATURE"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let failure = await service.verifyConnection()
        XCTAssertEqual(failure, DebridError.planRestricted)
        guard case DebridService.ConnectionStatus.failed(let message) = service.status else {
            XCTFail("expected a failed status")
            return
        }
        XCTAssertTrue(message.contains("piano"), "got: \(message)")
    }

    func testForgettingTheKeyRemovesItFromTheKeychainAndResetsTheStatus() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.user(plan: 2, expires: nil))
        }
        let (service, credentials) = try makeService(http: http, clock: fixedClock())
        _ = await service.verifyConnection()
        let before = http.requests.count
        service.forget()
        XCTAssertFalse(credentials.isConfigured(ServiceKind.torbox))
        XCTAssertNil(credentials.secret(for: ServiceKind.torbox))
        XCTAssertEqual(service.status, DebridService.ConnectionStatus.notConfigured)
        XCTAssertEqual(http.requests.count, before, "forgetting the key deletes nothing on TorBox")
        let failure = await service.verifyConnection()
        XCTAssertNil(failure)
        XCTAssertEqual(http.requests.count, before, "and without a key nothing is asked")
    }

    func testChangingTheKeyDropsWhatWasLearnedAboutTheOldOne() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.user(plan: 2, expires: nil))
        }
        let (service, credentials) = try makeService(http: http, clock: fixedClock())
        credentials.onChange = { [weak service] in service?.credentialsDidChange() }
        _ = await service.verifyConnection()
        service.stashResolution(resolution(), for: torrentStream(hash: slowHash), stremioID: "tt1")
        XCTAssertTrue(service.hasPreparedLinks)
        try credentials.save("another-key-987654321", for: ServiceKind.torbox)
        XCTAssertEqual(service.status, DebridService.ConnectionStatus.unverified, "a new key has not been checked yet")
        XCTAssertFalse(service.hasPreparedLinks, "a link obtained with the old key is not reused")
    }

    // MARK: Cache check

    private func cacheCheckHandler() -> @Sendable (HTTPRequest) -> TorBoxStubHTTP.Answer {
        return { (request: HTTPRequest) -> TorBoxStubHTTP.Answer in
            guard request.url.path.hasSuffix("/torrents/checkcached"), let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let hashes = object["hashes"] as? [String] else {
                return TorBoxStubHTTP.Answer(status: 400, body: TorBoxJSON.failure("INVALID_INPUT"))
            }
            var items: [String] = []
            for hash in hashes {
                if let value = UInt64(hash.suffix(8), radix: 16), value % 10 == 0 {
                    items.append("{\"name\":\"n\",\"size\":1,\"hash\":\"\(hash)\"}")
                }
            }
            return TorBoxStubHTTP.Answer(body: TorBoxJSON.envelope("[" + items.joined(separator: ",") + "]"))
        }
    }

    func testRealDebridUsesItsOwnTokenAndDoesNotCallDisabledInstantAvailabilityEndpoint() async throws {
        let realDebridKey = "rd-unit-test-token-012345"
        let hash = String(repeating: "a", count: 40)
        let http = TorBoxStubHTTP { (request: HTTPRequest) -> TorBoxStubHTTP.Answer in
            if request.url.path.hasSuffix("/torrents") {
                return TorBoxStubHTTP.Answer(status: 200, body: "[]")
            }
            return TorBoxStubHTTP.Answer(status: 501, body: "{\"error\":\"disabled_endpoint\",\"error_code\":37}")
        }
        let credentials = ServiceCredentials(secrets: InMemorySecretStore())
        try credentials.save(key, for: .torbox)
        try credentials.save(realDebridKey, for: .realdebrid)
        let service = DebridService(credentials: credentials, http: http,
                                    retry: TorBoxClient.RetryPolicy.noRetry, clock: fixedClock())
        service.selectProvider(.realdebrid)

        XCTAssertTrue(service.isConfigured, "configuration follows the selected provider")
        let report = await service.availability(infoHashes: [hash])
        XCTAssertEqual(report.failure, DebridError.api(code: "INSTANT_AVAILABILITY_UNSUPPORTED", detail: nil))
        XCTAssertEqual(report.status(for: hash), .unknown)
        XCTAssertTrue(http.requests.isEmpty, "Real-Debrid instant availability is disabled; do not mistake its failure for a bad token")

        do {
            _ = try await service.resolve(DebridRequest(infoHash: hash, mode: .cachedOnly), onProgress: nil)
            XCTFail("cached-only must not silently add a torrent when cache cannot be checked")
        } catch let error as DebridError {
            XCTAssertEqual(error, .api(code: "INSTANT_AVAILABILITY_UNSUPPORTED", detail: nil))
        }

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.host, "api.real-debrid.com", "Real-Debrid requests must never go to TorBox")
        XCTAssertEqual(request.url.path, "/rest/1.0/torrents")
        XCTAssertEqual(request.headers["Authorization"], "Bearer " + realDebridKey)
        XCTAssertFalse(request.headers["Authorization"]?.contains(key) ?? false)
        XCTAssertFalse(request.url.absoluteString.contains(realDebridKey))
        XCTAssertEqual(http.requests.count, 1, "no fallback to TorBox and no call to the retired cache endpoint")
        XCTAssertEqual(service.status, .notConfigured, "a Real-Debrid issue must not be shown as a TorBox key failure")
    }

    func testTheCacheCheckAsksAtMostOneHundredHashesPerRequest() async throws {
        let http = TorBoxStubHTTP(handler: cacheCheckHandler())
        let (service, _) = try makeService(http: http, clock: fixedClock())
        var hashes: [String] = []
        for number in 1...250 {
            hashes.append(String(format: "%040llx", UInt64(number)))
        }
        let report = await service.availability(infoHashes: hashes)
        XCTAssertNil(report.failure)
        let cached = report.statuses.values.filter { (status: DebridCacheStatus) -> Bool in return status == DebridCacheStatus.cached }
        let notCached = report.statuses.values.filter { (status: DebridCacheStatus) -> Bool in return status == DebridCacheStatus.notCached }
        XCTAssertEqual(cached.count, 25)
        XCTAssertEqual(notCached.count, 225)
        XCTAssertEqual(report.statuses.count, 250)

        let sizes: [Int] = http.requests.compactMap { (request: HTTPRequest) -> Int? in
            guard let body = request.body,
                  let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let list = object["hashes"] as? [String] else { return nil }
            return list.count
        }
        XCTAssertEqual(sizes, [100, 100, 50])
        for request in http.requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.headers["Authorization"], "Bearer " + key)
            XCTAssertFalse(request.url.absoluteString.contains(key))
        }
    }

    func testAnAnswerIsReusedAndAskedAgainOnlyAfterItExpires() async throws {
        let box = DebridTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let clock = DebridClock(now: { return box.now() }, sleep: { (_: TimeInterval) async throws -> Void in })
        let http = TorBoxStubHTTP(handler: cacheCheckHandler())
        let (service, _) = try makeService(http: http, clock: clock)
        let hashes = [String(format: "%040llx", UInt64(10)), String(format: "%040llx", UInt64(11))]
        let first = await service.availability(infoHashes: hashes)
        XCTAssertEqual(first.status(for: hashes[0]), DebridCacheStatus.cached)
        XCTAssertEqual(first.status(for: hashes[1]), DebridCacheStatus.notCached)
        XCTAssertEqual(http.requests.count, 1)
        _ = await service.availability(infoHashes: hashes)
        XCTAssertEqual(http.requests.count, 1, "a second picker opened right away reuses the answer")
        box.advance(by: 2 * 3600)
        _ = await service.availability(infoHashes: hashes)
        XCTAssertEqual(http.requests.count, 2, "TorBox's own cache lasts about an hour, so the answer is asked again later")
    }

    func testAFailedCacheCheckNeverBecomesNotCached() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 502, body: "<html>Bad gateway</html>")
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let hashes = [String(repeating: "a", count: 40), String(repeating: "b", count: 40)]
        let report = await service.availability(infoHashes: hashes)
        XCTAssertNotNil(report.failure)
        for hash in hashes {
            XCTAssertEqual(report.status(for: hash), DebridCacheStatus.unknown, "an error is not 'non in cache'")
        }
    }

    func testARefusedKeyFoundByTheCacheCheckIsRememberedInTheStatus() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 403, body: TorBoxJSON.failure("AUTH_ERROR"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let report = await service.availability(infoHashes: [String(repeating: "c", count: 40)])
        XCTAssertEqual(report.failure, DebridError.authFailed)
        guard case DebridService.ConnectionStatus.failed(let message) = service.status else {
            XCTFail("a key TorBox refuses is a fact worth keeping in the status")
            return
        }
        XCTAssertTrue(message.contains("Chiave non valida"))
    }

    // MARK: Hand-off from the picker to the player

    func testAResolvedLinkIsHandedToThePlayerOnce() throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 500, body: "")
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let stream = torrentStream(hash: slowHash)
        service.stashResolution(resolution(), for: stream, stremioID: "tt1")
        XCTAssertNil(service.takePreparedResolution(for: stream, stremioID: "tt2"), "another video does not get the link")
        XCTAssertNotNil(service.takePreparedResolution(for: stream, stremioID: "tt1"))
        XCTAssertNil(service.takePreparedResolution(for: stream, stremioID: "tt1"), "a retry resolves afresh")
        XCTAssertFalse(service.hasPreparedLinks)
    }

    func testAStashedLinkExpires() throws {
        let box = DebridTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let clock = DebridClock(now: { return box.now() }, sleep: { (_: TimeInterval) async throws -> Void in })
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 500, body: "")
        }
        let (service, _) = try makeService(http: http, clock: clock)
        let stream = torrentStream(hash: slowHash)
        service.stashResolution(resolution(), for: stream, stremioID: "tt1")
        box.advance(by: DebridService.preparedLifetime + 1)
        XCTAssertNil(service.takePreparedResolution(for: stream, stremioID: "tt1"))
    }

    func testThePlayerUsesTheLinkTheTorrentPickerAlreadyResolvedWithoutAskingTorBoxAgain() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 500, body: "")
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let stream = torrentStream(hash: slowHash, name: "Slow 720p")
        service.stashResolution(resolution(url: "https://cdn.example.com/dl/xyz"), for: stream, stremioID: "tt9400002")
        let playable = try await service.playableStream(for: stream, stremioID: "tt9400002", onProgress: nil)
        XCTAssertEqual(playable.source, StreamSource.url("https://cdn.example.com/dl/xyz"))
        XCTAssertEqual(playable.behaviorHints.filename, "Movie.mkv", "the file name keeps the container known when the address has no extension")
        XCTAssertEqual(playable.name, "Slow 720p")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testThePlayerNeverStartsADownloadOnItsOwn() async throws {
        let http = TorBoxStubHTTP { (request: HTTPRequest) -> TorBoxStubHTTP.Answer in
            let path = request.url.path
            if path.hasSuffix("/torrents/mylist") || path.hasSuffix("/torrents/checkcached") {
                return TorBoxStubHTTP.Answer(body: TorBoxJSON.envelope("[]"))
            }
            return TorBoxStubHTTP.Answer(status: 500, body: TorBoxJSON.failure("UNKNOWN_ERROR"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        do {
            _ = try await service.playableStream(for: torrentStream(hash: slowHash), stremioID: "tt9400002", onProgress: nil)
            XCTFail("a torrent outside TorBox's cache must not be played from the player")
        } catch {
            XCTAssertEqual(error as? DebridError, DebridError.notCached)
        }
        XCTAssertFalse(http.paths.contains("/torrents/createtorrent"), "adding a torrent needs the user's confirmation in the picker")
    }

    func testAStreamThatIsNotATorrentCannotBeResolved() async throws {
        let http = TorBoxStubHTTP { (_: HTTPRequest) -> TorBoxStubHTTP.Answer in
            return TorBoxStubHTTP.Answer(status: 500, body: "")
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let direct = AddonStream(source: StreamSource.url("https://cdn.example.com/file.mp4"), name: "Diretto")
        do {
            _ = try await service.playableStream(for: direct, stremioID: "tt1", onProgress: nil)
            XCTFail("a direct link has nothing to resolve")
        } catch {
            XCTAssertTrue(error is DebridError)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    // MARK: Downloading a torrent that was not in the cache

    func testAConfirmedDownloadReportsProgressAndEndsWithALinkWithoutTouchingTheUsersItems() async throws {
        let counter = DebridCallCounter()
        let hash = slowHash
        let http = TorBoxStubHTTP { (request: HTTPRequest) -> TorBoxStubHTTP.Answer in
            let path = request.url.path
            let query = request.url.query ?? ""
            if path.hasSuffix("/torrents/mylist") && query.contains("id=5") {
                let poll = counter.next("poll")
                let ready = poll >= 2
                return TorBoxStubHTTP.Answer(body: TorBoxJSON.envelope(TorBoxJSON.torrent(id: 5, hash: hash, ready: ready, progress: ready ? 1 : 0.4)))
            }
            if path.hasSuffix("/torrents/mylist") {
                return TorBoxStubHTTP.Answer(body: TorBoxJSON.envelope("[]"))
            }
            if path.hasSuffix("/torrents/createtorrent") {
                return TorBoxStubHTTP.Answer(body: TorBoxJSON.envelope("{\"torrent_id\":5,\"hash\":\"\(hash)\"}", detail: "Torrent added."))
            }
            if path.hasSuffix("/torrents/requestdl") {
                return TorBoxStubHTTP.Answer(body: TorBoxJSON.envelope("\"https://cdn.example.com/dl/abc\""))
            }
            return TorBoxStubHTTP.Answer(status: 404, body: TorBoxJSON.failure("ENDPOINT_NOT_FOUND"))
        }
        let (service, _) = try makeService(http: http, clock: fixedClock())
        let log = DebridProgressLog()
        let request = DebridRequest(infoHash: hash, stremioID: "tt9400002", mode: DebridMode.startIfNeeded)
        let result = try await service.resolve(request, onProgress: { (progress: DebridProgress) -> Void in log.add(progress) })

        XCTAssertEqual(result.url.absoluteString, "https://cdn.example.com/dl/abc")
        XCTAssertEqual(result.torrentID, 5)
        XCTAssertEqual(result.fileID, 41)
        XCTAssertFalse(result.wasAlreadyInAccount)

        let phases = log.all.map { (progress: DebridProgress) -> DebridProgress.Phase in return progress.phase }
        XCTAssertTrue(phases.contains(DebridProgress.Phase.checking))
        XCTAssertTrue(phases.contains(DebridProgress.Phase.adding))
        XCTAssertTrue(phases.contains(DebridProgress.Phase.requestingLink))
        let downloading = try XCTUnwrap(log.all.first(where: { (progress: DebridProgress) -> Bool in return progress.phase == DebridProgress.Phase.downloading }))
        XCTAssertEqual(downloading.fraction ?? -1, 0.4, accuracy: 0.001)
        XCTAssertEqual(downloading.downloadSpeed, 15_000_000)
        XCTAssertEqual(downloading.etaSeconds, 4)

        // The key goes in the Authorization header everywhere except in requestdl, whose address is the only one that carries it.
        let carrying = http.requests.filter { (request: HTTPRequest) -> Bool in return request.url.absoluteString.contains(key) }
        XCTAssertEqual(carrying.count, 1)
        XCTAssertEqual(carrying.first?.url.path, "/v1/api/torrents/requestdl")
        // Nothing of the user's account is ever deleted, paused or changed except the one add the user confirmed.
        XCTAssertEqual(http.paths.filter { (path: String) -> Bool in return path == "/torrents/createtorrent" }.count, 1)
        XCTAssertFalse(http.paths.contains { (path: String) -> Bool in return path.contains("control") })
    }

    // MARK: UI-test hook

    func testTheFixtureAddressIsHonouredOnlyForLocalAddresses() {
        XCTAssertEqual(DebridService.fixtureAPIBase(from: "http://127.0.0.1:7778")?.absoluteString, "http://127.0.0.1:7778/v1/api")
        XCTAssertEqual(DebridService.fixtureAPIBase(from: " http://127.0.0.1:7778/ ")?.absoluteString, "http://127.0.0.1:7778/v1/api")
        XCTAssertEqual(DebridService.fixtureAPIBase(from: "http://127.0.0.1:7778/v1/api")?.absoluteString, "http://127.0.0.1:7778/v1/api")
        XCTAssertNotNil(DebridService.fixtureAPIBase(from: "http://192.168.1.20:7778"))
        XCTAssertNil(DebridService.fixtureAPIBase(from: "https://evil.example.com"), "the key must never be sent to another host")
        XCTAssertNil(DebridService.fixtureAPIBase(from: "http://8.8.8.8:7778"))
        XCTAssertNil(DebridService.fixtureAPIBase(from: "http://api.torbox.app"), "the real service is reached over https only")
        XCTAssertNil(DebridService.fixtureAPIBase(from: ""))
    }

    func testTheLaunchArgumentIsReadOnlyInUITestMode() {
        let testing = UITestHooks(arguments: ["-AETHER_UITEST", "-AETHER_UITEST_TORBOX_URL", "http://127.0.0.1:7778"])
        XCTAssertEqual(testing.torboxServerURL, "http://127.0.0.1:7778")
        let normalLaunch = UITestHooks(arguments: ["-AETHER_UITEST_TORBOX_URL", "http://127.0.0.1:7778"])
        XCTAssertNil(normalLaunch.torboxServerURL, "outside the UI tests the address of TorBox cannot be changed")
        let noAddress = UITestHooks(arguments: ["-AETHER_UITEST"])
        XCTAssertNil(noAddress.torboxServerURL)
    }
}
