import XCTest
@testable import AetherCore

final class TVGuideTests: XCTestCase {
    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv generator-info-name="test">
      <channel id="Rai.1.HD..101.it"><display-name lang="it">Rai 1 HD  101</display-name></channel>
      <channel id="27.Twentyseven.it"><display-name lang="it">27 Twentyseven</display-name></channel>
      <channel id="Empty.it"><display-name>Senza programmi</display-name></channel>
      <programme start="20261109200000 +0100" stop="20261109203000 +0100" channel="Rai.1.HD..101.it">
        <title lang="it">Tg1</title><desc lang="it">Il telegiornale.</desc><category>News</category>
      </programme>
      <programme start="20261109203000 +0100" stop="20261109220000 +0100" channel="Rai.1.HD..101.it">
        <title lang="it">Film &amp; Serata</title><sub-title>Prima parte</sub-title>
      </programme>
      <programme start="20261101200000 +0100" stop="20261101210000 +0100" channel="Rai.1.HD..101.it">
        <title>Troppo vecchio</title>
      </programme>
      <programme start="20261109190000 +0000" stop="20261109200000 +0000" channel="27.Twentyseven.it">
        <title>Telefilm</title>
      </programme>
    </tv>
    """

    private var now: Date { return XMLTVParser.date("20261109201500 +0100")! }

    func testDatesReadTheOffset() {
        let utc = XMLTVParser.date("20261109190000 +0000")
        let rome = XMLTVParser.date("20261109200000 +0100")
        XCTAssertNotNil(utc)
        XCTAssertEqual(utc, rome)
        XCTAssertEqual(XMLTVParser.date("202611091900"), utc)
        XCTAssertNil(XMLTVParser.date("ieri"))
    }

    func testParsesProgrammesInTheWindow() {
        let guide = XMLTVParser.parse(Data(sample.utf8), now: now)
        let rai = guide.programmes["Rai.1.HD..101.it"] ?? []
        XCTAssertEqual(rai.map { $0.title }, ["Tg1", "Film & Serata"])
        XCTAssertEqual(rai.first?.summary, "Il telegiornale.")
        XCTAssertEqual(rai.first?.category, "News")
        XCTAssertEqual(rai.last?.subtitle, "Prima parte")
        XCTAssertEqual(guide.now("Rai.1.HD..101.it", at: now)?.title, "Tg1")
        XCTAssertEqual(guide.upcoming("Rai.1.HD..101.it", from: now, count: 2).map { $0.title }, ["Tg1", "Film & Serata"])
        XCTAssertEqual(guide.now("Rai.1.HD..101.it", at: now)?.progress(at: now) ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(guide.channels.count, 3)
    }

    func testMatchesPlaylistIDsToGuideNames() {
        let guide = XMLTVParser.parse(Data(sample.utf8), now: now)
        let matcher = TVGuideMatcher(guide)
        XCTAssertEqual(matcher.channelID(tvgID: "Rai1.it", name: "Rai 1"), "Rai.1.HD..101.it")
        XCTAssertEqual(matcher.channelID(tvgID: nil, name: "Rai 1 HD"), "Rai.1.HD..101.it")
        XCTAssertEqual(matcher.channelID(tvgID: "TwentySeven.it", name: "27"), "27.Twentyseven.it")
        XCTAssertEqual(matcher.channelID(tvgID: "Rai.1.HD..101.it", name: "x"), "Rai.1.HD..101.it")
        // A guide channel without programmes is not a match.
        XCTAssertNil(matcher.channelID(tvgID: "Empty.it", name: "Senza programmi"))
        XCTAssertNil(matcher.channelID(tvgID: "Rai2.it", name: "Rai 2"))
    }

    func testNormalise() {
        XCTAssertEqual(TVGuideMatcher.normalise("Rai1.it"), "rai1")
        XCTAssertEqual(TVGuideMatcher.normalise("Rai 1 HD  101"), "rai1")
        XCTAssertEqual(TVGuideMatcher.normalise("Home&GardenTV.it"), "homeandgarden")
        XCTAssertEqual(TVGuideMatcher.normalise("Sportitalia.HD.it"), "sportitalia")
        XCTAssertEqual(TVGuideMatcher.normalise("TV8.HD.it"), "tv8")
    }

    func testPlaylistAnnouncesItsGuide() {
        let text = """
        #EXTM3U url-tvg="https://example.org/guide.xml.gz,https://example.org/two.xml" x-tvg-url="ftp://nope"
        #EXTINF:-1 tvg-id="Rai1.it",Rai 1
        https://example.org/rai1.m3u8
        """
        let result = M3UParser.parse(text)
        XCTAssertEqual(result.guides, ["https://example.org/guide.xml.gz", "https://example.org/two.xml"])
        XCTAssertEqual(result.channels.first?.tvgID, "Rai1.it")
    }

    func testGuideAddressFollowsTheSettings() {
        var settings = LiveTVSettings()
        XCTAssertEqual(settings.guideAddress(announced: []), TVGuide.defaultItalianURL)
        XCTAssertEqual(settings.guideAddress(announced: ["https://example.org/g.xml"]), "https://example.org/g.xml")
        settings.guideURL = " https://mine.example/epg.xml "
        XCTAssertEqual(settings.guideAddress(announced: ["https://example.org/g.xml"]), "https://mine.example/epg.xml")
        settings.guideEnabled = false
        XCTAssertNil(settings.guideAddress(announced: []))
        let decoded = try? JSONDecoder().decode(LiveTVSettings.self, from: Data(#"{"showTab":true}"#.utf8))
        XCTAssertEqual(decoded?.guideEnabled, true)
        XCTAssertEqual(decoded?.guideURL, "")
    }

    func testGzipHeader() {
        // "hi" compressed with gzip (no name): header, raw deflate, CRC32, size.
        let bytes: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03, 0xcb, 0xc8, 0x04, 0x00,
                              0xac, 0x2a, 0x93, 0xd8, 0x02, 0x00, 0x00, 0x00]
        let data = Data(bytes)
        XCTAssertTrue(GzipContainer.isGzip(data))
        XCTAssertEqual(GzipContainer.deflatePayload(data), Data([0xcb, 0xc8, 0x04, 0x00]))
        XCTAssertEqual(GzipContainer.originalSize(data), 2)
        XCTAssertFalse(GzipContainer.isGzip(Data("<tv></tv>".utf8)))
        XCTAssertNil(GzipContainer.deflatePayload(Data("<tv></tv>".utf8)))
    }
}
