import XCTest
import AVFoundation
import AetherCore
@testable import Aether

#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)

/// A source file held in memory, read the way the relay reads a real one.
private final class MemoryFetcher: RelayRangeFetcher, @unchecked Sendable {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    func probe() async throws -> RelayResource {
        return RelayResource(contentType: "video/x-matroska", length: Int64(data.count), acceptsRanges: true)
    }

    func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
    }
}

/// The remux engine on real Matroska files (a few seconds of test pattern and tones, made with ffmpeg: see docs/04-TESTING.md).
final class FFmpegRemuxEngineTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: FFmpegRemuxEngineTests.self)
        let url = bundle.url(forResource: name, withExtension: "mkv") ?? bundle.url(forResource: name, withExtension: "mkv", subdirectory: "Fixtures")
        return try Data(contentsOf: try XCTUnwrap(url, "fixture \(name).mkv is not in the test bundle"))
    }

    private func engine(_ name: String, minimumSegment: Double = 4) throws -> FFmpegRemuxEngine {
        let data = try fixture(name)
        return FFmpegRemuxEngine(fetcher: MemoryFetcher(data), totalBytes: Int64(data.count), minimumSegment: minimumSegment)
    }

    // MARK: Planning

    func testAnH264FileWithThreeAudioTracksIsPlanned() async throws {
        let engine = try engine("remux-h264-3audio")
        defer { engine.close() }
        let prepared = try await engine.prepare()
        XCTAssertEqual(prepared.plan.video.codec, "h264")
        XCTAssertEqual(prepared.plan.audio.map { $0.codec }, ["aac", "ac3", "eac3"])
        XCTAssertEqual(prepared.plan.audio.map { $0.language }, ["ita", "eng", "fra"])
        XCTAssertTrue(prepared.plan.droppedAudio.isEmpty)
        XCTAssertEqual(prepared.duration, 8.0, accuracy: 0.2)
        XCTAssertEqual(prepared.segments.count, 2, "keyframes every 2 s with a 4 s minimum")
        XCTAssertEqual(prepared.segments[0].start, 0)
        XCTAssertEqual(prepared.segments[0].end, 4.0, accuracy: 0.1)
        XCTAssertEqual(prepared.master.width, 160)
        XCTAssertEqual(prepared.master.height, 90)
        XCTAssertEqual(prepared.master.frameRate ?? 0, 24, accuracy: 0.01)
        XCTAssertTrue(prepared.master.codecs[0].hasPrefix("avc1."), "\(prepared.master.codecs)")
        XCTAssertTrue(prepared.master.codecs.contains("mp4a.40.2"))
        XCTAssertTrue(prepared.master.codecs.contains("ac-3"))
        XCTAssertTrue(prepared.master.codecs.contains("ec-3"))
        XCTAssertEqual(prepared.master.range, .sdr)
    }

    func testAnHEVCTenBitFileGetsAnHEVCCodecString() async throws {
        let engine = try engine("remux-hevc10-eac3")
        defer { engine.close() }
        let prepared = try await engine.prepare()
        XCTAssertEqual(prepared.plan.video.codec, "hevc")
        XCTAssertEqual(prepared.plan.video.bitDepth, 10)
        XCTAssertTrue(prepared.master.codecs[0].hasPrefix("hvc1.2."), "\(prepared.master.codecs)")
        XCTAssertEqual(prepared.plan.audio.map { $0.codec }, ["eac3"])
    }

    func testFilesThatCannotBeCopiedAreRefusedWithTheReason() async throws {
        let dts = try engine("remux-h264-dts")
        defer { dts.close() }
        do {
            _ = try await dts.prepare()
            XCTFail("DTS only: expected a refusal")
        } catch {
            XCTAssertEqual(error as? RemuxError, .refused(.noUsableAudio(["dts"])))
        }
        let vp9 = try engine("remux-vp9-aac")
        defer { vp9.close() }
        do {
            _ = try await vp9.prepare()
            XCTFail("VP9: expected a refusal")
        } catch {
            XCTAssertEqual(error as? RemuxError, .refused(.videoCodec("vp9")))
        }
    }

    // MARK: Pieces

    func testTheInitSegmentAndThePiecesFormACoherentTimeline() async throws {
        let engine = try engine("remux-h264-3audio")
        defer { engine.close() }
        let prepared = try await engine.prepare()
        let initSegment = try await engine.initSegment()
        XCTAssertEqual(MP4Fragment.boxes(in: initSegment).map { $0.type }, ["ftyp", "moov"])
        let scales = MP4Fragment.trackTimescales(in: initSegment)
        XCTAssertEqual(scales.count, 4, "one video and three audio tracks")
        let videoScale = try XCTUnwrap(scales[1])
        let audioScale = try XCTUnwrap(scales[2])

        var starts: [Double] = []
        for index in 0..<prepared.segments.count {
            let piece = try await engine.mediaSegment(index)
            XCTAssertEqual(MP4Fragment.boxes(in: piece).map { $0.type }.first, "moof")
            XCTAssertFalse(MP4Fragment.boxes(in: piece).contains { $0.type == "mfra" })
            let times = MP4Fragment.decodeTimes(in: piece)
            XCTAssertEqual(Set(times.keys), [1, 2, 3, 4])
            starts.append(Double(try XCTUnwrap(times[1])) / Double(videoScale))
            // Audio starts together with the video of the same piece (within a frame or two), after the shift.
            let audioStart = Double(try XCTUnwrap(times[2])) / Double(audioScale)
            XCTAssertEqual(audioStart, starts[index], accuracy: 0.35, "piece \(index)")
        }
        XCTAssertEqual(starts[0], 0, accuracy: 0.001)
        XCTAssertEqual(starts[1], prepared.segments[1].start, accuracy: 0.1, "the second piece continues where the first ended")
    }

    func testAPieceIsTheSameWhenAskedAgainAndOutOfOrder() async throws {
        let engine = try engine("remux-h264-3audio")
        defer { engine.close() }
        _ = try await engine.prepare()
        let second = try await engine.mediaSegment(1)      // before the first: the timeline must not depend on the order
        let first = try await engine.mediaSegment(0)
        let secondAgain = try await engine.mediaSegment(1)
        XCTAssertEqual(second, secondAgain)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(MP4Fragment.decodeTimes(in: second)[1] ?? 0 > 0, true)
        do {
            _ = try await engine.mediaSegment(9)
            XCTFail("a piece that does not exist")
        } catch {
            XCTAssertEqual(error as? RemuxError, .segmentOutOfRange(9))
        }
    }

    func testClosingStopsTheEngine() async throws {
        let engine = try engine("remux-h264-3audio")
        _ = try await engine.prepare()
        engine.close()
        do {
            _ = try await engine.mediaSegment(0)
            XCTFail("a closed engine makes nothing")
        } catch {
            XCTAssertEqual(error as? RemuxError, .closed)
        }
    }

    // MARK: The system player

    private func serve(_ name: String) async throws -> (url: URL, stop: () -> Void) {
        let engine = try engine(name)
        let source = RemuxSource(engine: engine)
        try await source.prepare()
        let registry = RelaySessionRegistry()
        let server = RelayServer(registry: registry, configuration: RelayServer.Configuration(bindAddress: "127.0.0.1", allowLoopbackPeers: true),
                                 log: { _ in })
        let port = try await server.start()
        let created = try registry.create(source: source, leaf: nil, owner: .airPlay, peerRule: .any)
        let url = try XCTUnwrap(server.url(host: "127.0.0.1", token: created.token, leaf: "index.m3u8"))
        return (url, { registry.revokeAll(reason: .appClosing); server.stop(); _ = port })
    }

    /// An HLS asset has no `tracks` of its own: what it holds is only known once a player item is ready.
    @MainActor
    private func readyItem(_ url: URL) async throws -> (item: AVPlayerItem, player: AVPlayer) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && item.status == .unknown { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(item.status, .readyToPlay, "\(String(describing: item.error))")
        // The picture size is reported a moment after the item is ready.
        while Date() < deadline && item.presentationSize == .zero { try await Task.sleep(nanoseconds: 50_000_000) }
        return (item, player)
    }

    @MainActor
    func testTheSystemPlayerReadsTheRemuxedH264File() async throws {
        let served = try await serve("remux-h264-3audio")
        defer { served.stop() }
        let (item, _) = try await readyItem(served.url)
        XCTAssertEqual(CMTimeGetSeconds(item.duration), 8.0, accuracy: 0.5)
        XCTAssertEqual(item.presentationSize.width, 160)
        XCTAssertEqual(item.presentationSize.height, 90)
        let kinds = item.tracks.compactMap { $0.assetTrack?.mediaType }
        XCTAssertEqual(kinds.filter { $0 == .video }.count, 1, "tracks seen by the player: \(kinds.map { $0.rawValue })")
        XCTAssertGreaterThanOrEqual(kinds.filter { $0 == .audio }.count, 1, "tracks seen by the player: \(kinds.map { $0.rawValue })")
        let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let names = group?.options.map { $0.displayName } ?? []
        // How many audio choices the system player offers for tracks muxed into one variant (a probe: it decides whether the audio
        // tracks need their own renditions or one track is chosen before the file is converted).
        XCTAssertEqual(names.count, 3, "PROBE audio choices \(names.count): \(names); tracks seen: \(kinds.map { $0.rawValue })")
        XCTContext.runActivity(named: "REMUX-AV tracks \(kinds.map { $0.rawValue }) audio choices \(names)") { _ in }
    }

    @MainActor
    func testTheSystemPlayerReadsTheRemuxedHEVCFile() async throws {
        let served = try await serve("remux-hevc10-eac3")
        defer { served.stop() }
        let (item, _) = try await readyItem(served.url)
        XCTAssertEqual(CMTimeGetSeconds(item.duration), 10.0, accuracy: 0.5)
        XCTAssertEqual(item.presentationSize.width, 160)
        let kinds = item.tracks.compactMap { $0.assetTrack?.mediaType }
        XCTAssertEqual(kinds.filter { $0 == .video }.count, 1, "tracks seen by the player: \(kinds.map { $0.rawValue })")
    }

    @MainActor
    func testTheSystemPlayerPlaysTheRemuxedFileAcrossTheFirstPieceBoundary() async throws {
        let served = try await serve("remux-h264-3audio")
        defer { served.stop() }
        let item = AVPlayerItem(url: served.url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        let deadline = Date().addingTimeInterval(25)
        var reached = false
        while Date() < deadline {
            if CMTimeGetSeconds(player.currentTime()) > 4.6 { reached = true; break }
            if item.status == .failed { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        player.pause()
        XCTAssertNotEqual(item.status, .failed, "\(String(describing: item.error))")
        XCTAssertTrue(reached, "playback should pass the 4 s piece boundary (reached \(CMTimeGetSeconds(player.currentTime())) s)")
    }
}

#endif
