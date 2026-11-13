import XCTest
@testable import AetherCore

final class CastTracksTests: XCTestCase {
    private let cues = [
        SubtitleCue(start: 61.5, end: 63, text: "Ciao <i>mondo</i> & amici"),
        SubtitleCue(start: 1, end: 2.25, text: "Prima riga\nseconda"),
        SubtitleCue(start: 5, end: 4, text: "rovesciata"),
        SubtitleCue(start: 7, end: 8, text: "   "),
    ]

    func testWebVTTIsSortedEscapedAndShifted() {
        let vtt = SubtitleExport.webVTT(cues, offset: 0.5)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:01.500 --> 00:00:02.750\nPrima riga\nseconda"))
        XCTAssertTrue(vtt.contains("00:01:02.000 --> 00:01:03.500\nCiao <i>mondo</i> &amp; amici"))
        XCTAssertFalse(vtt.contains("rovesciata"))
        XCTAssertLessThan(vtt.range(of: "Prima")!.lowerBound, vtt.range(of: "Ciao")!.lowerBound)
    }

    func testSrtIsNumberedWithCommas() {
        let srt = SubtitleExport.srt(cues)
        XCTAssertTrue(srt.hasPrefix("1\n00:00:01,000 --> 00:00:02,250\nPrima riga\nseconda\n\n2\n00:01:01,500 --> 00:01:03,000\n"))
        XCTAssertFalse(srt.contains("3\n"))
    }

    func testNegativeOffsetNeverGoesBeforeZero() {
        let srt = SubtitleExport.srt([SubtitleCue(start: 0.2, end: 1, text: "a")], offset: -0.5)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:00,500"))
    }

    func testTrackListNamesAndIDs() {
        let list = CastTrackList.make([
            CastTrack(id: 1, kind: .audio, name: "", language: "it"),
            CastTrack(id: 2, kind: .audio, name: "", language: "it"),
            CastTrack(id: 3, kind: .audio, name: "Commento"),
            CastTrack(id: 10, kind: .text, name: "", language: "en"),
        ], active: [2, 10])
        XCTAssertEqual(list.audio.map { $0.name }, ["Italiano", "Italiano 2", "Commento"])
        XCTAssertEqual(list.activeAudio?.id, 2)
        XCTAssertEqual(list.activeText?.id, 10)
        XCTAssertEqual(list.ids(audio: nil, text: nil), [2])
        XCTAssertEqual(list.ids(audio: 3, text: 10), [3, 10])
        XCTAssertEqual(CastSidecarSubtitle(trackID: 4, name: "x", language: nil, cues: []).leaf(srt: true), "sub-4.srt")
    }

    func testSidecarSourceServesFilesAndPassesTheRestOn() async throws {
        let base = MemoryRelaySource(leaf: "video.mp4", contentType: "video/mp4", size: 1000)
        let vtt = Data("WEBVTT\n\n".utf8)
        let source = SidecarRelaySource(base: base, files: [RelaySidecarFile(leaf: "sub-1.vtt", contentType: "text/vtt", data: vtt)])
        let sub = try await source.resource(named: "sub-1.vtt")
        XCTAssertEqual(sub.contentType, "text/vtt")
        XCTAssertEqual(sub.length, Int64(vtt.count))
        let reader = try await source.open("sub-1.vtt", range: 0...5)
        var read = Data()
        while let chunk = try await reader.next() { read.append(chunk) }
        XCTAssertEqual(read, vtt.prefix(6))
        source.setCaption(url: "http://192.168.1.2:9000/r/x/sub-1.srt", forVideoLeaf: "video.mp4")
        let video = try await source.resource(named: "video.mp4")
        XCTAssertEqual(video.contentType, "video/mp4")
        XCTAssertEqual(video.captionURL, "http://192.168.1.2:9000/r/x/sub-1.srt")
        do { _ = try await source.resource(named: "other.mkv"); XCTFail("unknown leaf served") } catch {}
        let alone = SidecarRelaySource(base: nil, files: [])
        do { _ = try await alone.resource(named: "video.mp4"); XCTFail("served without a base") } catch {}
        source.close()
        XCTAssertTrue(base.isClosed)
    }

    func testCaptionHeaderOnlyForPlainLanAddresses() {
        let head = RelayHeaderPolicy.receiverHead(status: 200, contentType: "video/mp4", contentLength: 10, contentRange: nil, acceptsRanges: true,
                                                  wantsDLNAFeatures: true, date: Date(), captionURL: "http://192.168.1.2:9000/r/a/sub-1.srt")
        XCTAssertTrue(head.headers.contains { $0.name == "CaptionInfo.sec" && $0.value.hasSuffix("sub-1.srt") })
        let injected = RelayHeaderPolicy.receiverHead(status: 200, contentType: "video/mp4", contentLength: 10, contentRange: nil, acceptsRanges: true,
                                                      wantsDLNAFeatures: true, date: Date(), captionURL: "http://a/b\r\nX: y")
        XCTAssertFalse(injected.headers.contains { $0.name == "CaptionInfo.sec" })
    }

    func testDIDLAnnouncesTheSubtitle() {
        let xml = DIDLLite.metadata(title: "Film & co", url: URL(string: "http://192.168.1.2:9000/r/a/video.mp4")!, mimeType: "video/mp4",
                                    subtitleURL: URL(string: "http://192.168.1.2:9000/r/a/sub-1.srt")!)
        XCTAssertTrue(xml.contains("xmlns:sec=\"http://www.sec.co.kr/\""))
        XCTAssertTrue(xml.contains("<sec:CaptionInfoEx sec:type=\"srt\">http://192.168.1.2:9000/r/a/sub-1.srt</sec:CaptionInfoEx>"))
        XCTAssertTrue(xml.contains("protocolInfo=\"http-get:*:text/srt:*\""))
        XCTAssertFalse(DIDLLite.metadata(title: "x", url: URL(string: "http://h/v.mp4")!, mimeType: "video/mp4").contains("sec:"))
    }
}
