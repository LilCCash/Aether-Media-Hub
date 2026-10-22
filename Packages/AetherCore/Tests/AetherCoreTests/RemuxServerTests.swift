import XCTest
@testable import AetherCore
#if canImport(Network)
import Network

/// The HLS source behind the real server: playlists and pieces over HTTP, ranges included.
final class RemuxServerLoopbackTests: XCTestCase {
    private func exchange(_ port: UInt16, token: String, leaf: String, headers: [String] = []) async -> (raw: Data, reply: RelayTestReply?) {
        let client = RelayRawClient(port: port)
        guard await client.connect() else { return (Data(), nil) }
        var text = "GET /r/\(token)/\(leaf) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        for header in headers { text += header + "\r\n" }
        client.send(Data((text + "\r\n").utf8))
        _ = await relayPollUntil(8) { client.finished }
        client.close()
        return (client.data, RelayTestReply.parse(client.data))
    }

    func testPlaylistsAndPiecesAreServedOverHTTP() async throws {
        let engine = FakeRemuxEngine(segmentCount: 3, segmentSize: 5000)
        let source = RemuxSource(engine: engine)
        try await source.prepare()
        let registry = RelaySessionRegistry()
        let server = RelayServer(registry: registry, configuration: RelayServer.Configuration(bindAddress: "127.0.0.1", allowLoopbackPeers: true), log: { _ in })
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let created = try registry.create(source: source, leaf: nil, owner: .airPlay, peerRule: .any)

        let master = await exchange(port, token: created.token, leaf: "index.m3u8")
        XCTAssertEqual(master.reply?.status, 200)
        XCTAssertEqual(master.reply?.headers["content-type"], "application/vnd.apple.mpegurl")
        XCTAssertTrue(String(decoding: master.reply?.body ?? Data(), as: UTF8.self).contains("media.m3u8"))

        let media = await exchange(port, token: created.token, leaf: "media.m3u8")
        XCTAssertTrue(String(decoding: media.reply?.body ?? Data(), as: UTF8.self).contains("seg-2.m4s"))

        let initPiece = await exchange(port, token: created.token, leaf: "init.mp4")
        XCTAssertEqual(initPiece.reply?.body, Data("INIT".utf8))

        let piece = await exchange(port, token: created.token, leaf: "seg-1.m4s")
        XCTAssertEqual(piece.reply?.status, 200)
        XCTAssertEqual(piece.reply?.headers["content-length"], "5000")
        XCTAssertTrue(piece.reply?.body == FakeRemuxEngine.bytes(segment: 1, size: 5000))

        let ranged = await exchange(port, token: created.token, leaf: "seg-2.m4s", headers: ["Range: bytes=10-19"])
        XCTAssertEqual(ranged.reply?.status, 206)
        XCTAssertEqual(ranged.reply?.headers["content-range"], "bytes 10-19/5000")
        XCTAssertTrue(ranged.reply?.body == FakeRemuxEngine.bytes(segment: 2, size: 5000).subdata(in: 10..<20))
    }

    func testNamesThatDoNotExistAreTheSameFourOhFour() async throws {
        let source = RemuxSource(engine: FakeRemuxEngine(segmentCount: 2))
        try await source.prepare()
        let registry = RelaySessionRegistry()
        let server = RelayServer(registry: registry, configuration: RelayServer.Configuration(bindAddress: "127.0.0.1", allowLoopbackPeers: true), log: { _ in })
        let port = try await server.start()
        addTeardownBlock { server.stop() }
        let created = try registry.create(source: source, leaf: nil, owner: .airPlay, peerRule: .any)
        for leaf in ["seg-9.m4s", "video.mkv", "other.m3u8"] {
            let result = await exchange(port, token: created.token, leaf: leaf)
            XCTAssertTrue(result.raw == RelayHeaderPolicy.notFoundBytes, leaf)
        }
    }
}
#endif
