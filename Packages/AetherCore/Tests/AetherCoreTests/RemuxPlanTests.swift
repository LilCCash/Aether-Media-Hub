import XCTest
@testable import AetherCore

final class RemuxPlannerTests: XCTestCase {
    private func video(_ codec: String = "h264", bits: Int? = 8, dv: Int? = nil, index: Int = 0, isDefault: Bool = true) -> RemuxStreamInfo {
        return RemuxStreamInfo(index: index, kind: .video, codec: codec, bitDepth: bits, width: 1920, height: 1080, isDefault: isDefault, dolbyVisionProfile: dv)
    }

    private func audio(_ codec: String, index: Int, language: String? = nil, channels: Int = 6) -> RemuxStreamInfo {
        return RemuxStreamInfo(index: index, kind: .audio, codec: codec, channels: channels, language: language)
    }

    private func subtitle(_ index: Int) -> RemuxStreamInfo {
        return RemuxStreamInfo(index: index, kind: .subtitle, codec: "subrip")
    }

    private func plan(_ streams: [RemuxStreamInfo]) throws -> RemuxPlan {
        switch RemuxPlanner.plan(streams) {
        case .success(let plan): return plan
        case .failure(let refusal): throw refusal
        }
    }

    func testH264WithAACAndAC3IsCopiedAsItIs() throws {
        let result = try plan([video(), audio("aac", index: 1, language: "ita"), audio("ac3", index: 2, language: "eng"), subtitle(3)])
        XCTAssertEqual(result.video.index, 0)
        XCTAssertEqual(result.audio.map { $0.index }, [1, 2])
        XCTAssertTrue(result.droppedAudio.isEmpty)
        XCTAssertEqual(result.subtitleCount, 1)
        XCTAssertEqual(result.notes, ["I sottotitoli incorporati non passano in questo modo: usa quelli di Aether."])
    }

    func testHEVCTenBitIsAccepted() throws {
        XCTAssertNoThrow(try plan([video("hevc", bits: 10), audio("eac3", index: 1)]))
    }

    func testTracksTheSystemPlayerCannotReadAreLeftOutAndSaid() throws {
        let result = try plan([video(), audio("dts", index: 1, language: "ita"), audio("eac3", index: 2, language: "eng"), audio("truehd", index: 3)])
        XCTAssertEqual(result.audio.map { $0.index }, [2])
        XCTAssertEqual(result.droppedAudio.map { $0.index }, [1, 3])
        XCTAssertEqual(result.notes, ["Tracce audio non incluse perché il lettore di sistema non le legge: DTS (ita), Dolby TrueHD."])
    }

    func testOnlyUnreadableAudioIsRefusedWithAClearMessage() {
        let outcome = RemuxPlanner.plan([video(), audio("dts", index: 1), audio("truehd", index: 2)])
        guard case .failure(let refusal) = outcome else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal, .noUsableAudio(["dts", "truehd"]))
        XCTAssertTrue(refusal.message.contains("DTS"))
        XCTAssertTrue(refusal.message.contains("Automatico"))
    }

    func testAFileWithoutAudioStillWorks() throws {
        let result = try plan([video()])
        XCTAssertTrue(result.audio.isEmpty)
    }

    func testVideoCodecsTheSystemCannotDecodeAreRefused() {
        for codec in ["vp9", "av1", "mpeg2video", "mpeg4", "vc1", "msmpeg4v3"] {
            guard case .failure(let refusal) = RemuxPlanner.plan([video(codec), audio("aac", index: 1)]) else { return XCTFail(codec) }
            XCTAssertEqual(refusal, .videoCodec(codec))
            XCTAssertTrue(refusal.message.contains("Automatico"), codec)
        }
    }

    func testBitDepthLimits() {
        XCTAssertEqual(RemuxPlanner.plan([video("h264", bits: 10), audio("aac", index: 1)]), .failure(.videoBitDepth(codec: "h264", bits: 10)))
        XCTAssertEqual(RemuxPlanner.plan([video("hevc", bits: 12), audio("aac", index: 1)]), .failure(.videoBitDepth(codec: "hevc", bits: 12)))
        XCTAssertNotNil(try? plan([video("h264", bits: nil), audio("aac", index: 1)]), "an unknown depth is given the benefit of the doubt")
    }

    func testDolbyVisionProfile5IsRefusedButOthersPass() throws {
        XCTAssertEqual(RemuxPlanner.plan([video("hevc", bits: 10, dv: 5), audio("eac3", index: 1)]), .failure(.dolbyVisionProfile5))
        XCTAssertNoThrow(try plan([video("hevc", bits: 10, dv: 8), audio("eac3", index: 1)]))
    }

    func testNoVideoIsRefused() {
        XCTAssertEqual(RemuxPlanner.plan([audio("aac", index: 0)]), .failure(.noVideo))
    }

    func testTheDefaultVideoWinsAndAudioIsCapped() throws {
        let streams = [video(index: 0, isDefault: false), video(index: 1, isDefault: true)] + (2..<12).map { audio("aac", index: $0) }
        let result = try plan(streams)
        XCTAssertEqual(result.video.index, 1)
        XCTAssertEqual(result.audio.count, RemuxPlanner.maxAudioTracks)
        XCTAssertEqual(result.droppedAudio.count, 10 - RemuxPlanner.maxAudioTracks)
    }
}

final class SegmentPlannerTests: XCTestCase {
    func testPiecesStartAtKeyframesAndLastAtLeastTheMinimum() {
        let keyframes = [0.0, 2, 4, 6, 8, 10, 12, 14]
        let spans = SegmentPlanner.plan(keyframes: keyframes, duration: 15, minimum: 6)
        XCTAssertEqual(spans.map { $0.start }, [0, 6, 12])
        XCTAssertEqual(spans.map { $0.end }, [6, 12, 15])
        XCTAssertEqual(spans.map { $0.index }, [0, 1, 2])
        XCTAssertEqual(spans.map { $0.duration }, [6, 6, 3])
    }

    func testALongKeyframeIntervalGivesLongPieces() {
        let spans = SegmentPlanner.plan(keyframes: [0, 10, 20], duration: 28, minimum: 6)
        XCTAssertEqual(spans.map { $0.duration }, [10, 10, 8])
    }

    func testATinyLastPieceIsFoldedIntoThePreviousOne() {
        let spans = SegmentPlanner.plan(keyframes: [0, 6, 12], duration: 12.4, minimum: 6)
        XCTAssertEqual(spans.map { $0.end }, [6, 12.4])
    }

    func testTheFirstPieceAlwaysStartsAtZeroEvenIfTheFirstKeyframeIsLater() {
        let spans = SegmentPlanner.plan(keyframes: [0.083, 7, 14], duration: 20, minimum: 6)
        XCTAssertEqual(spans.first?.start, 0)
        XCTAssertEqual(spans.map { $0.start }, [0, 7, 14])
    }

    func testNoKeyframesMeansNoPlan() {
        XCTAssertTrue(SegmentPlanner.plan(keyframes: [], duration: 100).isEmpty)
        XCTAssertTrue(SegmentPlanner.plan(keyframes: [1, 2], duration: 0).isEmpty)
    }

    func testDuplicatesAndKeyframesPastTheEndAreIgnored() {
        let spans = SegmentPlanner.plan(keyframes: [0, 0, 6, 6, 50], duration: 10, minimum: 6)
        XCTAssertEqual(spans.map { $0.start }, [0, 6])
    }
}

final class HLSPlaylistTests: XCTestCase {
    func testTheMediaPlaylistListsEveryPiece() {
        let spans = [RemuxSegmentSpan(index: 0, start: 0, end: 6.006), RemuxSegmentSpan(index: 1, start: 6.006, end: 12), RemuxSegmentSpan(index: 2, start: 12, end: 14.5)]
        let text = HLSPlaylistBuilder.media(segments: spans)
        XCTAssertEqual(text, """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:7
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.006,
        seg-0.m4s
        #EXTINF:5.994,
        seg-1.m4s
        #EXTINF:2.500,
        seg-2.m4s
        #EXT-X-ENDLIST

        """)
    }

    func testTheTargetDurationIsTheLongestPieceRoundedUp() {
        let spans = [RemuxSegmentSpan(index: 0, start: 0, end: 10.2), RemuxSegmentSpan(index: 1, start: 10.2, end: 12)]
        XCTAssertTrue(HLSPlaylistBuilder.media(segments: spans).contains("#EXT-X-TARGETDURATION:11\n"))
    }

    func testTheMasterPlaylistCarriesCodecsAndRange() {
        let info = HLSMasterInfo(bandwidth: 9_600_000, averageBandwidth: 8_000_000, width: 3840, height: 2160, frameRate: 23.976,
                                 codecs: ["hvc1.2.4.L153.B0", "ec-3"], range: .pq)
        XCTAssertEqual(HLSPlaylistBuilder.master(info), """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=9600000,AVERAGE-BANDWIDTH=8000000,RESOLUTION=3840x2160,FRAME-RATE=23.976,CODECS="hvc1.2.4.L153.B0,ec-3",VIDEO-RANGE=PQ
        media.m3u8

        """)
    }

    func testTheMasterPlaylistOmitsWhatIsUnknown() {
        let text = HLSPlaylistBuilder.master(HLSMasterInfo(bandwidth: 0, averageBandwidth: 0, width: 0, height: 0, codecs: []))
        XCTAssertTrue(text.contains("BANDWIDTH=1,AVERAGE-BANDWIDTH=1,VIDEO-RANGE=SDR"))
        XCTAssertFalse(text.contains("RESOLUTION"))
        XCTAssertFalse(text.contains("CODECS"))
        XCTAssertFalse(text.contains("FRAME-RATE"))
    }
}

final class CodecStringsTests: XCTestCase {
    func testAVCFromTheConfigurationRecord() {
        XCTAssertEqual(CodecStrings.avc1(avcC: [1, 0x64, 0x00, 0x28, 0xFF]), "avc1.640028")
        XCTAssertEqual(CodecStrings.avc1(avcC: [1, 0x4D, 0x40, 0x1F]), "avc1.4D401F")
        XCTAssertNil(CodecStrings.avc1(avcC: [1, 0x64]))
        XCTAssertNil(CodecStrings.avc1(avcC: [0, 0x64, 0, 0x28]))
    }

    func testHEVCMain10() {
        // version 1, profile 2 (Main 10), compatibility flags 0x20000000 (flag 2 set), constraints 90 00 00 00 00 00, level 150 (5.0)
        let record: [UInt8] = [1, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0, 0, 0, 0, 0, 150]
        XCTAssertEqual(CodecStrings.hvc1(hvcC: record), "hvc1.2.4.L150.90")
    }

    func testHEVCMainWithHighTier() {
        // profile 1 (Main), tier high, compatibility 0x60000000 (flags 1 and 2), constraint 0xB0, level 120
        let record: [UInt8] = [1, 0x21, 0x60, 0x00, 0x00, 0x00, 0xB0, 0, 0, 0, 0, 0, 120]
        XCTAssertEqual(CodecStrings.hvc1(hvcC: record), "hvc1.1.6.H120.B0")
    }

    func testBadRecordsGiveNothing() {
        XCTAssertNil(CodecStrings.hvc1(hvcC: [1, 2, 3]))
        XCTAssertNil(CodecStrings.hvc1(hvcC: [2, 0x02, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 150]))
    }

    func testAudioStrings() {
        XCTAssertEqual(CodecStrings.audio(codec: "aac"), "mp4a.40.2")
        XCTAssertEqual(CodecStrings.audio(codec: "aac", aacObjectType: 5), "mp4a.40.5")
        XCTAssertEqual(CodecStrings.audio(codec: "ac3"), "ac-3")
        XCTAssertEqual(CodecStrings.audio(codec: "eac3"), "ec-3")
        XCTAssertEqual(CodecStrings.audio(codec: "mp3"), "mp4a.6B")
        XCTAssertNil(CodecStrings.audio(codec: "dts"))
    }
}
