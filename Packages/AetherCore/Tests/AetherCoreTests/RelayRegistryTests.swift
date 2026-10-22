import XCTest
@testable import AetherCore

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
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

/// A source that holds a real-looking secret, to prove the registry never prints it.
private final class SecretSource: RelaySource, @unchecked Sendable {
    let upstream = RelayUpstream(url: URL(string: "https://secret-host.example/SECRET123")!, headers: ["Authorization": "Bearer SECRET123"])
    func resource(named leaf: String) async throws -> RelayResource { throw RelayError.notFound }
    func open(_ leaf: String, range: ClosedRange<Int64>?) async throws -> RelayBodyReader { throw RelayError.notFound }
    func close() {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0

    func bytes(_ count: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        var result: [UInt8] = []
        for _ in 0..<count {
            result.append(value)
            value &+= 1
        }
        return result
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, RelayEndReason)] = []

    func add(_ id: RelaySessionID, _ reason: RelayEndReason) {
        lock.lock()
        items.append((id.label, reason))
        lock.unlock()
    }

    var reasons: [RelayEndReason] {
        lock.lock()
        defer { lock.unlock() }
        return items.map { $0.1 }
    }

    var labels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items.map { $0.0 }
    }
}

final class RelayRegistryTests: XCTestCase {
    private let clock = FakeClock()

    private func makeRegistry(limits: RelayLimits = .standard) -> RelaySessionRegistry {
        let clock = self.clock
        return RelaySessionRegistry(limits: limits, now: { clock.now })
    }

    private func isGranted(_ authorization: RelayAuthorization) -> Bool {
        if case .granted = authorization { return true }
        return false
    }

    private func source() -> MemoryRelaySource {
        return MemoryRelaySource(size: 100)
    }

    // MARK: Tokens

    func testTokensAreDistinctLongAndHex() throws {
        let registry = makeRegistry()
        var seen = Set<String>()
        for _ in 0..<1000 {
            let created = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
            XCTAssertEqual(created.token.count, 64)
            XCTAssertTrue(created.token.allSatisfy { "0123456789abcdef".contains($0) })
            XCTAssertTrue(seen.insert(created.token).inserted)
        }
    }

    func testAFixedRandomSourceGivesAFixedToken() throws {
        let first = RelaySessionRegistry(randomBytes: Counter().bytes)
        let second = RelaySessionRegistry(randomBytes: Counter().bytes)
        let a = try first.create(source: source(), leaf: "video.mkv", owner: .airPlay, peerRule: .any)
        let b = try second.create(source: source(), leaf: "video.mkv", owner: .airPlay, peerRule: .any)
        XCTAssertEqual(a.token, b.token)
        XCTAssertEqual(a.token.prefix(8), "00010203")
    }

    func testTheLogLabelIsShortAndHex() throws {
        let registry = makeRegistry()
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .airPlay, peerRule: .any)
        XCTAssertEqual(created.id.label.count, 6)
        XCTAssertTrue(created.id.label.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testNothingThePrinterCanReachHoldsTheTokenOrTheUpstream() throws {
        let registry = makeRegistry()
        let secret = SecretSource()
        let created = try registry.create(source: secret, leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        var dumped = ""
        dump(registry, to: &dumped)
        for text in [String(reflecting: registry), String(describing: registry), dumped, "\(registry)"] {
            XCTAssertFalse(text.contains(created.token), text)
            XCTAssertFalse(text.contains("SECRET123"), text)
            XCTAssertFalse(text.contains("secret-host"), text)
        }
        guard case .granted(let grant) = registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9") else { return XCTFail("denied") }
        XCTAssertFalse(String(reflecting: grant).contains(created.token))
        XCTAssertFalse("\(grant)".contains("SECRET123"))
    }

    // MARK: Authorisation

    func testTheRightTokenLeafAndPeerAreGranted() throws {
        let registry = makeRegistry()
        let memory = source()
        let created = try registry.create(source: memory, leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        guard case .granted(let grant) = registry.authorize(token: created.token, leaf: "video.mkv", peer: "192.168.1.40") else { return XCTFail("denied") }
        XCTAssertEqual(grant.id, created.id)
        XCTAssertEqual(grant.leaf, "video.mkv")
        XCTAssertTrue(grant.source === memory)
    }

    func testEverythingElseIsDeniedTheSameWay() throws {
        let registry = makeRegistry()
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.dlna), peerRule: .expected(["192.168.1.40"]))
        let good = created.token
        XCTAssertFalse(isGranted(registry.authorize(token: String(repeating: "0", count: 64), leaf: "video.mkv", peer: "192.168.1.40")))
        XCTAssertFalse(isGranted(registry.authorize(token: String(good.dropLast()), leaf: "video.mkv", peer: "192.168.1.40")))
        XCTAssertFalse(isGranted(registry.authorize(token: good.uppercased(), leaf: "video.mkv", peer: "192.168.1.40")))
        XCTAssertFalse(isGranted(registry.authorize(token: "", leaf: "video.mkv", peer: "192.168.1.40")))
        XCTAssertFalse(isGranted(registry.authorize(token: good, leaf: "video.mp4", peer: "192.168.1.40")))
        XCTAssertFalse(isGranted(registry.authorize(token: good, leaf: "video.mkv", peer: "192.168.1.41")))
        XCTAssertFalse(isGranted(registry.authorize(token: good, leaf: "video.mkv", peer: "")))
        XCTAssertTrue(isGranted(registry.authorize(token: good, leaf: "video.mkv", peer: "192.168.1.40")))
        registry.revoke(created.id, reason: .userStopped)
        XCTAssertFalse(isGranted(registry.authorize(token: good, leaf: "video.mkv", peer: "192.168.1.40")))
    }

    func testPeerRulesMatchWholeAddresses() throws {
        let registry = makeRegistry()
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .expected(["10.0.0.9"]))
        XCTAssertTrue(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9")))
        XCTAssertFalse(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.10")))
        XCTAssertFalse(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.")))
    }

    func testTheAirPlaySessionAlwaysAllowsThePhoneItself() throws {
        let registry = makeRegistry()
        registry.ownAddress = "192.168.1.5"
        let airPlay = try registry.create(source: source(), leaf: "video.mp4", owner: .airPlay, peerRule: .expected(["192.168.1.9"]))
        XCTAssertTrue(isGranted(registry.authorize(token: airPlay.token, leaf: "video.mp4", peer: "192.168.1.5")))
        XCTAssertTrue(isGranted(registry.authorize(token: airPlay.token, leaf: "video.mp4", peer: "192.168.1.9")))
        XCTAssertFalse(isGranted(registry.authorize(token: airPlay.token, leaf: "video.mp4", peer: "192.168.1.6")))

        let cast = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .expected(["192.168.1.9"]))
        XCTAssertFalse(isGranted(registry.authorize(token: cast.token, leaf: "video.mkv", peer: "192.168.1.5")), "only AirPlay reads from the phone itself")
    }

    // MARK: Lifetimes

    func testASessionNobodyUsedEndsAfterTheArmedWindow() throws {
        let registry = makeRegistry()
        let recorder = Recorder()
        registry.observeRevocations { recorder.add($0, $1) }
        let memory = source()
        let created = try registry.create(source: memory, leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        clock.advance(179)
        XCTAssertTrue(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9")))
        clock.advance(2)
        registry.sweep()
        XCTAssertEqual(recorder.reasons, [.neverUsed])
        XCTAssertEqual(recorder.labels, [created.id.label])
        XCTAssertFalse(registry.isActive(created.id))
        XCTAssertTrue(memory.isClosed)
        XCTAssertFalse(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9")))
    }

    func testAnExpiredSessionIsDeniedEvenBeforeTheSweepRuns() throws {
        let registry = makeRegistry()
        let recorder = Recorder()
        registry.observeRevocations { recorder.add($0, $1) }
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        clock.advance(181)
        XCTAssertFalse(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9")))
        XCTAssertEqual(recorder.reasons, [.neverUsed])
    }

    func testASessionInUseLivesUntilTheLifetimeCap() throws {
        let registry = makeRegistry()
        let recorder = Recorder()
        registry.observeRevocations { recorder.add($0, $1) }
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        clock.advance(10)
        registry.noteRequest(created.id)
        clock.advance(40 * 60)
        registry.sweep()
        XCTAssertTrue(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9")))
        XCTAssertTrue(recorder.reasons.isEmpty)

        clock.advance(12 * 3600)
        registry.sweep()
        XCTAssertEqual(recorder.reasons, [.expiredLifetime])
        XCTAssertFalse(isGranted(registry.authorize(token: created.token, leaf: "video.mkv", peer: "10.0.0.9")))
    }

    // MARK: Ownership and limits

    func testANewSessionOfTheSameOwnerReplacesTheOldOne() throws {
        let registry = makeRegistry()
        let recorder = Recorder()
        registry.observeRevocations { recorder.add($0, $1) }
        let oldSource = source()
        let first = try registry.create(source: oldSource, leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        let second = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        XCTAssertEqual(recorder.reasons, [.replaced])
        XCTAssertTrue(oldSource.isClosed)
        XCTAssertFalse(isGranted(registry.authorize(token: first.token, leaf: "video.mkv", peer: "10.0.0.9")))
        XCTAssertTrue(isGranted(registry.authorize(token: second.token, leaf: "video.mkv", peer: "10.0.0.9")))
        XCTAssertEqual(registry.sessionCount, 1)
    }

    func testACastSessionAndAnAirPlaySessionCoexistButNotAThird() throws {
        let registry = makeRegistry()
        let cast = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        let airPlay = try registry.create(source: source(), leaf: "video.mp4", owner: .airPlay, peerRule: .any)
        XCTAssertThrowsError(try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.dlna), peerRule: .any)) { error in
            XCTAssertEqual(error as? RelayError, .tooManySessions)
        }
        XCTAssertEqual(registry.sessionCount, 2)
        XCTAssertTrue(isGranted(registry.authorize(token: cast.token, leaf: "video.mkv", peer: "10.0.0.9")))
        XCTAssertTrue(isGranted(registry.authorize(token: airPlay.token, leaf: "video.mp4", peer: "10.0.0.9")))
        // Replacing one of them is still possible at the cap.
        XCTAssertNoThrow(try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any))
    }

    func testRevokingEndsAndClosesAndTellsTheObservers() throws {
        let registry = makeRegistry()
        let recorder = Recorder()
        registry.observeRevocations { recorder.add($0, $1) }
        let a = source(), b = source()
        let first = try registry.create(source: a, leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        _ = try registry.create(source: b, leaf: "video.mp4", owner: .airPlay, peerRule: .any)
        registry.revoke(first.id, reason: .userStopped)
        XCTAssertTrue(a.isClosed)
        XCTAssertFalse(b.isClosed)
        registry.revoke(first.id, reason: .userStopped)       // already gone: nothing happens
        XCTAssertEqual(recorder.reasons, [.userStopped])
        registry.revokeAll(reason: .appClosing)
        XCTAssertTrue(b.isClosed)
        XCTAssertEqual(registry.sessionCount, 0)
        XCTAssertEqual(recorder.reasons, [.userStopped, .appClosing])
    }

    func testRevokingByOwner() throws {
        let registry = makeRegistry()
        _ = try registry.create(source: source(), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        let airPlay = try registry.create(source: source(), leaf: "video.mp4", owner: .airPlay, peerRule: .any)
        registry.revoke(owner: .cast(.googleCast), reason: .directLinkDisabled)
        XCTAssertEqual(registry.sessionCount, 1)
        XCTAssertEqual(registry.sessionID(for: .airPlay), airPlay.id)
        XCTAssertNil(registry.sessionID(for: .cast(.googleCast)))
    }

    func testAnObserverMayCallBackIntoTheRegistry() throws {
        let registry = makeRegistry()
        let seen = Recorder()
        registry.observeRevocations { id, reason in
            seen.add(id, reason)
            _ = registry.sessionCount          // would deadlock if the lock were still held
        }
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .airPlay, peerRule: .any)
        registry.revoke(created.id, reason: .receiverEnded)
        XCTAssertEqual(seen.reasons, [.receiverEnded])
    }

    func testCountersFollowTheRequests() throws {
        let registry = makeRegistry()
        let created = try registry.create(source: source(), leaf: "video.mkv", owner: .airPlay, peerRule: .any)
        XCTAssertEqual(registry.requestsServed(created.id), 0)
        registry.noteRequest(created.id)
        registry.noteRequest(created.id)
        registry.noteServed(created.id, bytes: 500)
        registry.noteServed(created.id, bytes: -7)
        XCTAssertEqual(registry.requestsServed(created.id), 2)
        XCTAssertEqual(registry.bytesServed(created.id), 500)
        XCTAssertEqual(registry.requestsServed(RelaySessionID(label: "zzzzzz")), 0)
    }
}
