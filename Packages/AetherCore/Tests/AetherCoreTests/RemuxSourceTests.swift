import XCTest
@testable import AetherCore

/// An engine that makes pieces of known content, counts what it was asked and can be slowed down or made to fail.
final class FakeRemuxEngine: RemuxEngine, @unchecked Sendable {
    let segmentCount: Int
    let segmentSize: Int
    var prepareError: Error?
    var failingSegment: Int?
    var delay: UInt64 = 0
    private let lock = NSLock()
    private var _initCalls = 0
    private var _segmentCalls: [Int] = []
    private var _closed = false

    init(segmentCount: Int = 4, segmentSize: Int = 1000) {
        self.segmentCount = segmentCount
        self.segmentSize = segmentSize
    }

    var initCalls: Int { return locked { _initCalls } }
    var segmentCalls: [Int] { return locked { _segmentCalls } }
    var closed: Bool { return locked { _closed } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func bytes(segment index: Int, size: Int) -> Data {
        return Data((0..<size).map { UInt8(truncatingIfNeeded: index * 31 + $0) })
    }

    func prepare() async throws -> RemuxPrepared {
        if let error = prepareError { throw error }
        let video = RemuxStreamInfo(index: 0, kind: .video, codec: "h264", bitDepth: 8, width: 1920, height: 1080, isDefault: true)
        let audio = RemuxStreamInfo(index: 1, kind: .audio, codec: "aac", channels: 2, language: "ita")
        let spans = (0..<segmentCount).map { RemuxSegmentSpan(index: $0, start: Double($0) * 6, end: Double($0 + 1) * 6) }
        return RemuxPrepared(plan: RemuxPlan(video: video, audio: [audio], droppedAudio: [], subtitleCount: 0), segments: spans,
                             duration: Double(segmentCount) * 6,
                             master: HLSMasterInfo(bandwidth: 5_000_000, averageBandwidth: 4_000_000, width: 1920, height: 1080, frameRate: 24,
                                                   codecs: ["avc1.640028", "mp4a.40.2"]))
    }

    func initSegment() async throws -> Data {
        locked { _initCalls += 1 }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return Data("INIT".utf8)
    }

    func mediaSegment(_ index: Int) async throws -> Data {
        locked { _segmentCalls.append(index) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failingSegment == index { throw RemuxError.engine(code: -5) }
        return FakeRemuxEngine.bytes(segment: index, size: segmentSize)
    }

    func close() {
        locked { _closed = true }
    }
}

final class RemuxSourceTests: XCTestCase {
    private func drain(_ reader: RelayBodyReader) async throws -> Data {
        var all = Data()
        while let chunk = try await reader.next() { all.append(chunk) }
        return all
    }

    private func make(_ engine: FakeRemuxEngine, maxCacheBytes: Int = 160 << 20) async throws -> RemuxSource {
        let source = RemuxSource(engine: engine, maxCacheBytes: maxCacheBytes)
        try await source.prepare()
        return source
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            _ = try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: Names

    func testLeafNames() {
        XCTAssertEqual(RemuxSource.Leaf.parse("index.m3u8"), .master)
        XCTAssertEqual(RemuxSource.Leaf.parse("media.m3u8"), .media)
        XCTAssertEqual(RemuxSource.Leaf.parse("init.mp4"), .initSegment)
        XCTAssertEqual(RemuxSource.Leaf.parse("seg-0.m4s"), .segment(0))
        XCTAssertEqual(RemuxSource.Leaf.parse("seg-123.m4s"), .segment(123))
        for bad in ["seg-.m4s", "seg-01.m4s", "seg-1.mp4", "seg--1.m4s", "seg-1234567.m4s", "seg-1a.m4s", "video.mkv", "", "SEG-1.m4s", "../seg-1.m4s"] {
            XCTAssertNil(RemuxSource.Leaf.parse(bad), bad)
        }
    }

    // MARK: Playlists

    func testThePlaylistsAreServedWithTheRightTypes() async throws {
        let source = try await make(FakeRemuxEngine())
        let master = try await source.resource(named: "index.m3u8")
        XCTAssertEqual(master.contentType, "application/vnd.apple.mpegurl")
        let reader = try await source.open("index.m3u8", range: nil)
        let text = String(decoding: try await drain(reader), as: UTF8.self)
        XCTAssertTrue(text.contains("#EXT-X-STREAM-INF:BANDWIDTH=5000000"))
        XCTAssertTrue(text.contains("media.m3u8"))
        XCTAssertEqual(Int64(text.utf8.count), master.length)

        let media = try await source.resource(named: "media.m3u8")
        let mediaText = String(decoding: try await drain(try await source.open("media.m3u8", range: nil)), as: UTF8.self)
        XCTAssertTrue(mediaText.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertEqual(mediaText.components(separatedBy: "seg-").count - 1, 4)
        XCTAssertEqual(media.length, Int64(mediaText.utf8.count))
    }

    func testUnknownNamesAreNotFound() async throws {
        let source = try await make(FakeRemuxEngine(segmentCount: 2))
        for name in ["video.mkv", "seg-2.m4s", "seg-99.m4s", "other.m3u8"] {
            do {
                _ = try await source.resource(named: name)
                XCTFail("\(name) should not exist")
            } catch {
                XCTAssertEqual(error as? RelayError, .notFound, name)
            }
        }
    }

    func testNothingIsServedBeforePrepare() async {
        let source = RemuxSource(engine: FakeRemuxEngine())
        do {
            _ = try await source.resource(named: "index.m3u8")
            XCTFail("not prepared")
        } catch {
            XCTAssertEqual(error as? RelayError, .notFound)
        }
    }

    func testARefusalSurfacesFromPrepareWithItsReason() async {
        let engine = FakeRemuxEngine()
        engine.prepareError = RemuxError.refused(.videoCodec("vp9"))
        let source = RemuxSource(engine: engine)
        do {
            try await source.prepare()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? RemuxError, .refused(.videoCodec("vp9")))
            XCTAssertTrue((error as? RemuxError)?.message.contains("VP9") ?? false)
        }
    }

    // MARK: Pieces

    func testAPieceHasItsLengthBeforeItsBodyAndCanBeReadInRanges() async throws {
        let engine = FakeRemuxEngine(segmentSize: 600_000)
        let source = try await make(engine)
        let resource = try await source.resource(named: "seg-1.m4s")
        XCTAssertEqual(resource.length, 600_000)
        XCTAssertEqual(resource.contentType, "video/mp4")
        XCTAssertTrue(resource.acceptsRanges)
        let whole = try await drain(try await source.open("seg-1.m4s", range: nil))
        XCTAssertEqual(whole, FakeRemuxEngine.bytes(segment: 1, size: 600_000))
        let part = try await drain(try await source.open("seg-1.m4s", range: 1000...1999))
        XCTAssertEqual(part, FakeRemuxEngine.bytes(segment: 1, size: 600_000).subdata(in: 1000..<2000))
        do {
            _ = try await source.open("seg-1.m4s", range: 599_999...600_000)
            XCTFail("a range past the end must be refused")
        } catch {
            XCTAssertEqual(error as? RelayError, .rangeNotSatisfiable(total: 600_000))
        }
    }

    func testThePiecesAreMadeOnceAndSharedByConcurrentRequests() async throws {
        let engine = FakeRemuxEngine()
        engine.delay = 50_000_000
        let source = try await make(engine)
        async let first = source.resource(named: "seg-0.m4s")
        async let second = source.resource(named: "seg-0.m4s")
        async let third = source.resource(named: "init.mp4")
        _ = try await (first, second, third)
        _ = try await source.open("seg-0.m4s", range: nil)
        _ = try await source.resource(named: "init.mp4")
        XCTAssertEqual(engine.segmentCalls.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(engine.initCalls, 1)
    }

    func testTheNextPieceIsPreparedWhileTheCurrentOneIsSent() async throws {
        let engine = FakeRemuxEngine()
        let source = try await make(engine)
        _ = try await source.resource(named: "seg-0.m4s")
        let ahead = await waitUntil { engine.segmentCalls.contains(1) }
        XCTAssertTrue(ahead, "the following piece should be started by itself")
        XCTAssertFalse(engine.segmentCalls.contains(2), "but only one piece ahead")
    }

    func testTheLastPieceHasNothingToPrefetch() async throws {
        let engine = FakeRemuxEngine(segmentCount: 2)
        let source = try await make(engine)
        _ = try await source.resource(named: "seg-1.m4s")
        _ = try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.segmentCalls, [1])
    }

    func testTheCacheKeepsTheInitSegmentAndEvictsTheOldestPieces() async throws {
        let engine = FakeRemuxEngine(segmentCount: 6, segmentSize: 1000)
        let source = try await make(engine, maxCacheBytes: 2500)
        _ = try await source.resource(named: "init.mp4")
        for index in 0..<5 { _ = try await source.resource(named: "seg-\(index).m4s") }
        _ = try? await Task.sleep(nanoseconds: 100_000_000)
        let before = engine.segmentCalls.count
        _ = try await source.resource(named: "init.mp4")
        XCTAssertEqual(engine.initCalls, 1, "the init segment is never evicted")
        _ = try await source.resource(named: "seg-0.m4s")        // evicted long ago: made again
        XCTAssertGreaterThan(engine.segmentCalls.count, before)
    }

    func testAFailingPieceIsAnErrorForThatPieceOnly() async throws {
        let engine = FakeRemuxEngine()
        engine.failingSegment = 2
        let source = try await make(engine)
        do {
            _ = try await source.resource(named: "seg-2.m4s")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? RelayError, .upstreamUnreachable(code: -5))
        }
        let fine = try await source.resource(named: "seg-1.m4s")
        XCTAssertEqual(fine.length, 1000)
        engine.failingSegment = nil
        let retried = try await source.resource(named: "seg-2.m4s")
        XCTAssertEqual(retried.length, 1000, "a failure is not cached")
    }

    func testClosingCancelsAndClosesTheEngine() async throws {
        let engine = FakeRemuxEngine()
        let source = try await make(engine)
        _ = try await source.resource(named: "init.mp4")
        source.close()
        XCTAssertTrue(engine.closed)
        do {
            _ = try await source.resource(named: "init.mp4")
            XCTFail("a closed source serves nothing")
        } catch {
            XCTAssertEqual(error as? RelayError, .notFound)
        }
        source.close()
    }

    func testEngineErrorsAreReducedToRelayErrors() {
        XCTAssertEqual(RemuxSource.relayError(from: RemuxError.closed) as? RelayError, .notFound)
        XCTAssertEqual(RemuxSource.relayError(from: RemuxError.refused(.noVideo)) as? RelayError, .upstreamNotMedia)
        XCTAssertEqual(RemuxSource.relayError(from: RemuxError.noKeyframeIndex) as? RelayError, .upstreamBadRange)
        XCTAssertEqual(RemuxSource.relayError(from: RemuxError.engine(code: -22)) as? RelayError, .upstreamUnreachable(code: -22))
        XCTAssertTrue(RemuxSource.relayError(from: CancellationError()) is CancellationError)
    }
}

final class RemuxRegistryTests: XCTestCase {
    func testASessionWithoutAFixedNameServesAnyNameOfItsSource() throws {
        let registry = RelaySessionRegistry()
        let source = MemoryRelaySource(size: 10)
        let created = try registry.create(source: source, leaf: nil, owner: .airPlay, peerRule: .any)
        for leaf in ["index.m3u8", "seg-4.m4s", "video.mkv"] {
            guard case .granted(let grant) = registry.authorize(token: created.token, leaf: leaf, peer: "10.0.0.9") else { return XCTFail(leaf) }
            XCTAssertEqual(grant.leaf, leaf, "the grant carries the name that was asked for")
        }
        let fixed = try registry.create(source: MemoryRelaySource(size: 10), leaf: "video.mkv", owner: .cast(.googleCast), peerRule: .any)
        guard case .denied = registry.authorize(token: fixed.token, leaf: "other.mkv", peer: "10.0.0.9") else { return XCTFail("a fixed name must stay fixed") }
    }
}
