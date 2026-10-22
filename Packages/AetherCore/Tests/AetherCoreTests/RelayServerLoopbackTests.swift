import XCTest
@testable import AetherCore
#if canImport(Network)
import Network

// The real server on 127.0.0.1, spoken to with a raw TCP client so the bytes on the wire are exactly the ones a test chooses.

final class RelayServerLoopbackTests: XCTestCase {
    private struct Harness {
        let server: RelayServer
        let registry: RelaySessionRegistry
        let port: UInt16
        let log: RelayLogBox
    }

    private func harness(limits: RelayLimits = .standard) async throws -> Harness {
        let registry = RelaySessionRegistry(limits: limits)
        let box = RelayLogBox()
        let server = RelayServer(registry: registry,
                                 configuration: RelayServer.Configuration(bindAddress: "127.0.0.1", allowLoopbackPeers: true, limits: limits),
                                 log: { box.add($0) })
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        return Harness(server: server, registry: registry, port: port, log: box)
    }

    private func get(_ token: String, leaf: String = "video.mkv", method: String = "GET", headers: [String] = []) -> Data {
        return request("/r/\(token)/\(leaf)", method: method, headers: headers)
    }

    private func request(_ path: String, method: String = "GET", headers: [String] = []) -> Data {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for header in headers { text += header + "\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    /// Sends `bytes` on a fresh connection and reads until the server closes it.
    private func exchange(_ port: UInt16, _ bytes: Data, timeout: TimeInterval = 8) async -> (raw: Data, reply: RelayTestReply?, finished: Bool) {
        let client = RelayRawClient(port: port)
        guard await client.connect() else { return (Data(), nil, false) }
        client.send(bytes)
        let done = await relayPollUntil(timeout) { client.finished }
        client.close()
        return (client.data, RelayTestReply.parse(client.data), done)
    }

    private let size: Int64 = 300_000

    private func session(_ h: Harness, size: Int64? = nil, owner: RelayOwner = .cast(.googleCast), peers: RelayPeerRule = .any,
                         configure: (MemoryRelaySource) -> Void = { _ in }) throws -> (token: String, id: RelaySessionID, source: MemoryRelaySource) {
        let source = MemoryRelaySource(size: size ?? self.size)
        configure(source)
        let created = try h.registry.create(source: source, leaf: "video.mkv", owner: owner, peerRule: peers)
        return (created.token, created.id, source)
    }

    // MARK: Answers

    func testAGetReturnsTheWholeFileWithTheExpectedHeaders() async throws {
        let h = try await harness()
        let s = try session(h)
        let result = await exchange(h.port, get(s.token))
        guard let reply = result.reply else { return XCTFail("no answer") }
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.body == MemoryRelaySource.expected(0...(size - 1)), "the body must be the source, byte for byte")
        XCTAssertEqual(reply.headers["content-length"], "300000")
        XCTAssertEqual(reply.headers["content-type"], "video/x-matroska")
        XCTAssertEqual(reply.headers["accept-ranges"], "bytes")
        XCTAssertEqual(reply.headers["cache-control"], "no-store")
        XCTAssertEqual(reply.headers["x-content-type-options"], "nosniff")
        XCTAssertEqual(reply.headers["access-control-allow-origin"], "*")
        XCTAssertEqual(reply.headers["connection"], "close")
        XCTAssertNil(reply.headers["server"])
        XCTAssertEqual(h.registry.requestsServed(s.id), 1)
        let counted = await relayPollUntil { h.registry.bytesServed(s.id) == 300_000 }
        XCTAssertTrue(counted)
    }

    func testRangesAreServedExactly() async throws {
        let h = try await harness()
        let s = try session(h)

        let middle = await exchange(h.port, get(s.token, headers: ["Range: bytes=1000-1999"]))
        XCTAssertEqual(middle.reply?.status, 206)
        XCTAssertEqual(middle.reply?.headers["content-range"], "bytes 1000-1999/300000")
        XCTAssertEqual(middle.reply?.headers["content-length"], "1000")
        XCTAssertTrue(middle.reply?.body == MemoryRelaySource.expected(1000...1999))

        let tail = await exchange(h.port, get(s.token, headers: ["Range: bytes=-100"]))
        XCTAssertEqual(tail.reply?.status, 206)
        XCTAssertEqual(tail.reply?.headers["content-range"], "bytes 299900-299999/300000")
        XCTAssertTrue(tail.reply?.body == MemoryRelaySource.expected(299_900...299_999))

        let open = await exchange(h.port, get(s.token, headers: ["Range: bytes=299990-"]))
        XCTAssertEqual(open.reply?.status, 206)
        XCTAssertTrue(open.reply?.body == MemoryRelaySource.expected(299_990...299_999))

        let beyond = await exchange(h.port, get(s.token, headers: ["Range: bytes=300000-"]))
        XCTAssertEqual(beyond.reply?.status, 416)
        XCTAssertEqual(beyond.reply?.headers["content-range"], "bytes */300000")
        XCTAssertEqual(beyond.reply?.body.count, 0)

        let several = await exchange(h.port, get(s.token, headers: ["Range: bytes=0-1,5-9"]))
        XCTAssertEqual(several.reply?.status, 200)
        XCTAssertEqual(several.reply?.body.count, 300_000)
    }

    func testHeadAnswersWithoutTouchingTheSource() async throws {
        let h = try await harness()
        let s = try session(h)
        let result = await exchange(h.port, get(s.token, method: "HEAD"))
        XCTAssertEqual(result.reply?.status, 200)
        XCTAssertEqual(result.reply?.headers["content-length"], "300000")
        XCTAssertEqual(result.reply?.body.count, 0)
        XCTAssertEqual(s.source.openCount, 0)
        XCTAssertEqual(s.source.producedBytes, 0)
    }

    func testOptionsNeedsAValidToken() async throws {
        let h = try await harness()
        let s = try session(h)
        let allowed = await exchange(h.port, get(s.token, method: "OPTIONS"))
        XCTAssertEqual(allowed.reply?.status, 204)
        XCTAssertTrue(allowed.reply?.headers["access-control-allow-methods"]?.contains("GET") ?? false)
        XCTAssertTrue(allowed.reply?.headers["access-control-allow-headers"]?.contains("Range") ?? false)
        let wrong = await exchange(h.port, get(String(repeating: "0", count: 64), method: "OPTIONS"))
        XCTAssertTrue(wrong.raw == RelayHeaderPolicy.notFoundBytes)
    }

    func testEveryKindOfRefusalIsTheSameFourOhFour() async throws {
        let h = try await harness()
        let first = try session(h, owner: .cast(.googleCast))
        let second = try session(h, owner: .cast(.dlna))
        h.registry.revoke(second.id, reason: .userStopped)
        let unknown = String(repeating: "ab", count: 32)
        let cases: [(String, Data)] = [
            ("unknown token", get(unknown)),
            ("revoked token", get(second.token)),
            ("wrong leaf", get(first.token, leaf: "video.mp4")),
            ("root", request("/")),
            ("/r/", request("/r/")),
            ("token only", request("/r/\(first.token)")),
            ("traversal", request("/r/\(first.token)/../video.mkv")),
            ("query", request("/r/\(first.token)/video.mkv?x=1"))
        ]
        for (name, bytes) in cases {
            let result = await exchange(h.port, bytes)
            XCTAssertTrue(result.raw == RelayHeaderPolicy.notFoundBytes, name)
        }
    }

    func testAPostIsNotAllowedAndGarbageDoesNotHurt() async throws {
        let h = try await harness()
        let s = try session(h)
        let post = await exchange(h.port, get(s.token, method: "POST"))
        XCTAssertEqual(post.reply?.status, 405)
        XCTAssertEqual(post.reply?.headers["allow"], "GET, HEAD, OPTIONS")

        let binary = await exchange(h.port, Data((0..<100).map { UInt8(0x80 + $0 % 100) }))
        XCTAssertTrue(binary.reply?.status == 400 || binary.raw.isEmpty, "binary noise is refused or dropped")

        let huge = await exchange(h.port, Data(("GET /r/x HTTP/1.1\r\nX-Pad: " + String(repeating: "a", count: 20_000)).utf8))
        XCTAssertTrue(huge.reply?.status == 431 || huge.raw.isEmpty)

        let fine = await exchange(h.port, get(s.token, headers: ["Range: bytes=0-9"]))
        XCTAssertEqual(fine.reply?.status, 206, "the server must still work after bad requests")
    }

    // MARK: Limits

    func testASlowHeadIsClosed() async throws {
        var limits = RelayLimits()
        limits.headTimeout = 0.3
        let h = try await harness(limits: limits)
        let client = RelayRawClient(port: h.port)
        let connected = await client.connect()
        XCTAssertTrue(connected)
        client.send(Data("GET /r/".utf8))
        let closed = await relayPollUntil(2) { client.finished }
        XCTAssertTrue(closed, "a half-sent head must not hold a connection open")
        client.close()
        XCTAssertTrue(h.log.messages.contains { $0.contains("troppo lenta") })
    }

    func testTheTotalNumberOfConnectionsIsLimited() async throws {
        var limits = RelayLimits()
        limits.maxConnections = 3
        let h = try await harness(limits: limits)
        var idle: [RelayRawClient] = []
        for _ in 0..<3 {
            let client = RelayRawClient(port: h.port)
            let connected = await client.connect()
            XCTAssertTrue(connected)
            idle.append(client)
        }
        let fourth = RelayRawClient(port: h.port)
        _ = await fourth.connect()
        let refused = await relayPollUntil(3) { fourth.finished }
        XCTAssertTrue(refused, "the fourth connection should be closed at once")
        XCTAssertTrue(idle.allSatisfy { !$0.finished })
        for client in idle + [fourth] { client.close() }
    }

    func testOnePeerCannotTakeAllTheConnections() async throws {
        var limits = RelayLimits()
        limits.maxConnectionsPerPeer = 2
        let h = try await harness(limits: limits)
        var idle: [RelayRawClient] = []
        for _ in 0..<2 {
            let client = RelayRawClient(port: h.port)
            _ = await client.connect()
            idle.append(client)
        }
        let third = RelayRawClient(port: h.port)
        _ = await third.connect()
        let refused = await relayPollUntil(3) { third.finished }
        XCTAssertTrue(refused)
        XCTAssertTrue(idle.allSatisfy { !$0.finished })
        for client in idle + [third] { client.close() }
    }

    func testASessionPinnedToAnotherPeerIsNotServed() async throws {
        let h = try await harness()
        let pinnedElsewhere = try session(h, owner: .cast(.googleCast), peers: .expected(["10.9.9.9"]))
        let denied = await exchange(h.port, get(pinnedElsewhere.token))
        XCTAssertTrue(denied.raw == RelayHeaderPolicy.notFoundBytes)
        let pinnedHere = try session(h, owner: .cast(.dlna), peers: .expected(["127.0.0.1"]))
        let granted = await exchange(h.port, get(pinnedHere.token, headers: ["Range: bytes=0-9"]))
        XCTAssertEqual(granted.reply?.status, 206)
    }

    // MARK: Streaming behaviour

    /// The receiver has stopped reading (the server is blocked sending), then the session is revoked. What the server does is checked
    /// on the server's side: the connection is dropped and the reader told to stop. Whether the bytes the kernel already holds still
    /// reach a receiver that does not read is up to the operating system, so nothing is asserted on the client here.
    func testRevokingASessionDropsAStalledConnectionAndCancelsTheReader() async throws {
        let h = try await harness()
        let s = try session(h, size: 1 << 40)
        let client = RelayRawClient(port: h.port, readLimit: 256 * 1024, retainBytes: false)
        let connected = await client.connect()
        XCTAssertTrue(connected)
        client.send(get(s.token))
        let streaming = await relayPollUntil { client.count > 100_000 }
        XCTAssertTrue(streaming)
        XCTAssertEqual(h.server.activeConnectionCount, 1)
        h.registry.revoke(s.id, reason: .userStopped)
        let dropped = await relayPollUntil(6) { h.server.activeConnectionCount == 0 }
        XCTAssertTrue(dropped, "the server must let go of the connection once the session is revoked")
        let cancelled = await relayPollUntil(6) { s.source.cancelCount >= 1 }
        XCTAssertTrue(cancelled, "the reader must be told to stop")
        client.close()
    }

    /// A receiver that keeps reading sees the connection end shortly after the revocation.
    func testRevokingASessionEndsTheConnectionOfAReceiverThatIsReading() async throws {
        let h = try await harness()
        let s = try session(h, size: 1 << 40)
        let client = RelayRawClient(port: h.port, retainBytes: false)
        let connected = await client.connect()
        XCTAssertTrue(connected)
        client.send(get(s.token))
        let streaming = await relayPollUntil { client.count > 100_000 }
        XCTAssertTrue(streaming)
        XCTAssertFalse(client.finished)
        h.registry.revoke(s.id, reason: .userStopped)
        let closed = await relayPollUntil(6) { client.finished }
        XCTAssertTrue(closed, "the connection should end shortly after the revocation (received \(client.count) bytes, server holds "
                      + "\(h.server.activeConnectionCount) connections, \(h.server.abortedConnectionCount) aborts, \(s.source.cancelCount) reader cancels; "
                      + "client: \(client.notes); log: \(h.log.messages.suffix(8)))")
        client.close()
    }

    func testASlowReceiverSlowsTheSourceDown() async throws {
        let h = try await harness()
        let s = try session(h, size: 256 << 20)
        let client = RelayRawClient(port: h.port, readLimit: 256 * 1024, retainBytes: false)
        _ = await client.connect()
        client.send(get(s.token))
        _ = await relayPollUntil { client.count >= 256 * 1024 }
        _ = try? await Task.sleep(nanoseconds: 2_000_000_000)
        let produced = s.source.producedBytes
        XCTAssertLessThan(produced, 32 << 20, "the source must not run ahead of a receiver that stopped reading (produced \(produced))")
        client.close()
    }

    // MARK: Failures

    func testASourceThatFailsToOpenIsABadGatewayAndTheServerSurvives() async throws {
        let h = try await harness()
        let s = try session(h) { $0.failOpen = .upstreamRejected(status: 403) }
        let failed = await exchange(h.port, get(s.token))
        XCTAssertEqual(failed.reply?.status, 502)
        XCTAssertEqual(failed.reply?.headers["content-length"], "0")
        XCTAssertTrue(h.log.messages.contains { $0.contains("rifiutata dalla sorgente (403)") })
        s.source.failOpen = nil
        let fine = await exchange(h.port, get(s.token, headers: ["Range: bytes=0-9"]))
        XCTAssertEqual(fine.reply?.status, 206)
    }

    func testABodyThatFailsMidwayIsCutNotCompleted() async throws {
        let h = try await harness()
        let s = try session(h) { $0.failAfterBytes = 100_000 }
        let result = await exchange(h.port, get(s.token))
        XCTAssertTrue(result.finished)
        XCTAssertEqual(result.reply?.status, 200)
        XCTAssertEqual(result.reply?.headers["content-length"], "300000")
        XCTAssertLessThan(result.reply?.body.count ?? Int.max, 300_000, "a short body must never look complete")
        let heads = result.raw.ranges(of: Data("HTTP/1.1".utf8)).count
        XCTAssertEqual(heads, 1, "no second head after the failure")
    }

    // MARK: Lifecycle

    func testStartingTwiceGivesTheSamePortAndStoppingRefusesConnections() async throws {
        let h = try await harness()
        let again = try await h.server.start()
        XCTAssertEqual(again, h.port)
        XCTAssertTrue(h.server.isRunning)
        h.server.stop()
        XCTAssertFalse(h.server.isRunning)
        let late = RelayRawClient(port: h.port)
        let connected = await late.connect(timeout: 2)
        XCTAssertFalse(connected, "nobody listens after stop")
        late.close()
    }

    func testTheServerDoesNotAnswerOnIPv6() async throws {
        let h = try await harness()
        let s = try session(h)
        let client = RelayRawClient(host: "::1", port: h.port)
        if await client.connect(timeout: 2) {
            client.send(get(s.token))
            _ = await relayPollUntil(2) { client.finished }
            XCTAssertTrue(client.data.isEmpty, "an IPv6 peer must get no answer")
        }
        client.close()
    }

    func testTheAddressHandedToAReceiver() async throws {
        let h = try await harness()
        let token = String(repeating: "ab", count: 32)
        let url = h.server.url(host: "192.168.1.50", token: token, leaf: "video.mkv")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.50:\(h.port)/r/\(token)/video.mkv")
        XCTAssertNil(h.server.url(host: "example.com", token: token, leaf: "video.mkv"))
        XCTAssertNil(h.server.url(host: "192.168.1.50", token: "short", leaf: "video.mkv"))
        XCTAssertNil(h.server.url(host: "192.168.1.50", token: token, leaf: "../x"))
        h.server.stop()
        XCTAssertNil(h.server.url(host: "192.168.1.50", token: token, leaf: "video.mkv"))
    }

    func testTheLogNeverHoldsATokenOrAnAddress() async throws {
        let h = try await harness()
        let s = try session(h)
        _ = await exchange(h.port, get(s.token, headers: ["Range: bytes=0-99"]))
        _ = await exchange(h.port, get(String(repeating: "0", count: 64)))
        _ = await exchange(h.port, get(s.token, method: "POST"))
        h.registry.revoke(s.id, reason: .userStopped)
        let messages = h.log.messages
        XCTAssertFalse(messages.isEmpty)
        for message in messages {
            XCTAssertFalse(message.contains(s.token), message)
            XCTAssertFalse(message.contains("/r/"), message)
            XCTAssertFalse(message.lowercased().contains("http"), message)
            XCTAssertFalse(message.contains("127.0.0.1"), message)
        }
    }
}
#endif
