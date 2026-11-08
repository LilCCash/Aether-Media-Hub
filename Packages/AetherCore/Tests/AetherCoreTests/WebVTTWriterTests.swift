import XCTest
@testable import AetherCore

final class WebVTTWriterTests: XCTestCase {
    func testASSEventsBecomePlainText() {
        let event = "12,0,Default,,0,0,0,,{\\i1}Ciao{\\i0}\\Ncome stai, tutto bene?"
        XCTAssertEqual(WebVTTWriter.text(of: event, codec: "ass"), "Ciao\ncome stai, tutto bene?")
    }

    func testSRTKeepsItalicsAndEscapesTheRest() {
        XCTAssertEqual(WebVTTWriter.text(of: "<i>Ehi</i> <font color=\"red\">tu</font> & io", codec: "subrip"), "<i>Ehi</i> tu &amp; io")
    }

    func testTheDocumentIsSortedAndTimed() {
        let text = WebVTTWriter.document([WebVTTWriter.Cue(start: 65.5, end: 67, text: "Due"),
                                          WebVTTWriter.Cue(start: 1, end: 2.25, text: "Uno"),
                                          WebVTTWriter.Cue(start: 3, end: 3, text: "vuota")])
        XCTAssertEqual(text, "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000\n\n00:00:01.000 --> 00:00:02.250\nUno\n\n00:01:05.500 --> 00:01:07.000\nDue\n")
    }

    func testTheMasterPlaylistListsTheSubtitles() {
        let info = HLSMasterInfo(bandwidth: 1000, averageBandwidth: 800, width: 1920, height: 1080, codecs: ["avc1.640028"])
        let text = HLSPlaylistBuilder.master(info, subtitles: [HLSSubtitleRendition(name: "Italiano", language: "it", uri: "subs-3.m3u8"),
                                                               HLSSubtitleRendition(name: "Italiano", language: "it", uri: "subs-4.m3u8")])
        XCTAssertTrue(text.contains("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"Italiano\",LANGUAGE=\"it\",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,URI=\"subs-3.m3u8\""))
        XCTAssertTrue(text.contains("NAME=\"Italiano 2\""), "names are unique in the group")
        XCTAssertTrue(text.contains("SUBTITLES=\"subs\""))
        XCTAssertEqual(HLSPlaylistBuilder.master(info), HLSPlaylistBuilder.master(info, subtitles: []), "no subtitles, no change")
    }
}
