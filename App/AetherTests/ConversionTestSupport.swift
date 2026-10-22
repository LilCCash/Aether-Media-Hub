import XCTest
import AetherCore
@testable import Aether

/// A converter that makes nothing: enough to see what the services do around it.
final class FakeConversionEngine: RemuxEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _closed = 0
    var refusal: RemuxError?
    var audio: RemuxAudioChoice

    init(audio: RemuxAudioChoice = .standard) {
        self.audio = audio
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _closed
    }

    func prepare() async throws -> RemuxPrepared {
        if let refusal = refusal { throw refusal }
        let video = RemuxStreamInfo(index: 0, kind: .video, codec: "h264", bitDepth: 8, width: 1920, height: 1080, isDefault: true)
        let italian = RemuxStreamInfo(index: 1, kind: .audio, codec: "aac", channels: 2, language: "ita")
        let english = RemuxStreamInfo(index: 2, kind: .audio, codec: "ac3", channels: 6, language: "eng")
        let plan: RemuxPlan
        switch RemuxPlanner.plan([video, italian, english], audio: audio) {
        case .success(let decided): plan = decided
        case .failure(let refusal): throw RemuxError.refused(refusal)
        }
        let spans = [RemuxSegmentSpan(index: 0, start: 0, end: 6), RemuxSegmentSpan(index: 1, start: 6, end: 12)]
        return RemuxPrepared(plan: plan, segments: spans, duration: 12,
                             master: HLSMasterInfo(bandwidth: 5_000_000, averageBandwidth: 4_000_000, width: 1920, height: 1080, frameRate: 24,
                                                   codecs: ["avc1.640028", "mp4a.40.2"]))
    }

    func initSegment() async throws -> Data { return Data("INIT".utf8) }
    func mediaSegment(_ index: Int) async throws -> Data { return Data("SEG\(index)".utf8) }

    func close() {
        lock.lock()
        _closed += 1
        lock.unlock()
    }
}

/// Hands out fake converters and remembers them.
final class FakeConversionMaker: @unchecked Sendable {
    private let lock = NSLock()
    private var _engines: [FakeConversionEngine] = []
    private var _choices: [RemuxAudioChoice] = []
    var refusal: RemuxError?
    var available = true

    var engines: [FakeConversionEngine] {
        lock.lock()
        defer { lock.unlock() }
        return _engines
    }

    var choices: [RemuxAudioChoice] {
        lock.lock()
        defer { lock.unlock() }
        return _choices
    }

    var maker: RemuxEngineFactory.Maker {
        return { [self] _, _, audio in
            guard available else { return nil }
            let engine = FakeConversionEngine(audio: audio)
            engine.refusal = refusal
            lock.lock()
            _engines.append(engine)
            _choices.append(audio)
            lock.unlock()
            return engine
        }
    }
}

final class FakeLoopbackServer: RelayServing, @unchecked Sendable {
    var port: UInt16?
    var onFailure: (@Sendable () -> Void)?
    var started = 0
    var stopped = 0

    func start(preferredPort: UInt16?) async throws -> UInt16 {
        started += 1
        port = 50999
        return 50999
    }

    func stop() {
        stopped += 1
        port = nil
    }

    func url(host: String, token: String, leaf: String) -> URL? {
        return URL(string: "http://\(host):\(port ?? 0)/r/\(token)/\(leaf)")
    }
}

final class ProbingFetcher: RelayRangeFetcher, @unchecked Sendable {
    var length: Int64? = 5_000_000
    var probeError: Error?
    private(set) var invalidated = 0

    func probe() async throws -> RelayResource {
        if let error = probeError { throw error }
        return RelayResource(contentType: "video/x-matroska", length: length, acceptsRanges: true)
    }

    func fetch(_ range: ClosedRange<Int64>) async throws -> Data { return Data(count: range.count) }
    func invalidate() { invalidated += 1 }
}
