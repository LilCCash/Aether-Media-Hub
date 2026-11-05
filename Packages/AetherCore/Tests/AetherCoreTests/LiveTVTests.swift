import XCTest
@testable import AetherCore

final class M3UParserTests: XCTestCase {
    private let sample = """
    #EXTM3U url-tvg="http://epg.example/guide.xml"
    #EXTINF:-1 tvg-id="rai1.it" tvg-name="Rai 1" tvg-logo="https://img.example/rai1.png" group-title="Generalisti, Italia",Rai 1 HD
    https://tv.example/rai1.m3u8
    #EXTINF:-1 group-title="Sport",Sport Uno
    #EXTVLCOPT:http-user-agent=Mozilla/5.0 Test
    #EXTVLCOPT:http-referrer=https://tv.example/
    http://tv.example/sport1.ts
    #EXTINF:-1,Senza gruppo
    #EXTGRP:Film
    https://tv.example/film.m3u8
    #EXTINF:-1,Rtmp
    rtmp://tv.example/live
    #EXTINF:-1 group-title="Sport",Sport Uno
    http://tv.example/sport1.ts
    """

    func testChannelsGroupsAndLogosAreRead() {
        let result = M3UParser.parse(sample)
        XCTAssertEqual(result.channels.map { $0.name }, ["Rai 1 HD", "Sport Uno", "Senza gruppo"])
        XCTAssertEqual(result.channels[0].group, "Generalisti, Italia", "a comma inside quotes is not the end of the attributes")
        XCTAssertEqual(result.channels[0].logo, "https://img.example/rai1.png")
        XCTAssertEqual(result.channels[0].tvgID, "rai1.it")
        XCTAssertEqual(result.channels[2].group, "Film")
    }

    func testHeadersDuplicatesAndOtherSchemes() {
        let result = M3UParser.parse(sample)
        XCTAssertEqual(result.channels[1].requestHeaders, ["User-Agent": "Mozilla/5.0 Test", "Referer": "https://tv.example/"])
        XCTAssertEqual(result.skipped, 1, "the rtmp entry is skipped")
        XCTAssertEqual(result.channels.count, 3, "the repeated channel is kept once")
    }

    func testIdsAreStableAndGarbageIsHarmless() {
        XCTAssertEqual(M3UParser.parse(sample).channels.map { $0.id }, M3UParser.parse(sample).channels.map { $0.id })
        XCTAssertEqual(M3UParser.stableID("a"), M3UParser.stableID("a"))
        XCTAssertNotEqual(M3UParser.stableID("a"), M3UParser.stableID("b"))
        XCTAssertTrue(M3UParser.parse("niente di tutto questo\n<html>").channels.isEmpty)
        XCTAssertTrue(M3UParser.parse("").channels.isEmpty)
        XCTAssertEqual(M3UParser.parse(sample, maxChannels: 1).channels.count, 1)
    }

    func testSearchAndGroups() {
        let channels = M3UParser.parse(sample).channels
        XCTAssertEqual(LiveChannelList.filter(channels, query: "rai", group: nil).count, 1)
        XCTAssertEqual(LiveChannelList.filter(channels, query: "SPORT uno", group: nil).count, 1)
        XCTAssertEqual(LiveChannelList.filter(channels, query: "", group: "Film").map { $0.name }, ["Senza gruppo"])
        XCTAssertEqual(LiveChannelList.groups(channels).map { $0.name }, ["Generalisti, Italia", "Sport", "Film"])
    }
}

final class LiveTVSettingsTests: XCTestCase {
    func testCatalogSelectionFollowsTheTypeUnlessTheViewerChose() {
        var settings = LiveTVSettings()
        XCTAssertTrue(settings.includes(catalogKey: "a/x", isTVType: true))
        XCTAssertFalse(settings.includes(catalogKey: "a/y", isTVType: false))
        settings.setIncluded(false, catalogKey: "a/x", isTVType: true)
        settings.setIncluded(true, catalogKey: "a/y", isTVType: false)
        XCTAssertFalse(settings.includes(catalogKey: "a/x", isTVType: true))
        XCTAssertTrue(settings.includes(catalogKey: "a/y", isTVType: false))
        settings.setIncluded(true, catalogKey: "a/x", isTVType: true)
        settings.setIncluded(false, catalogKey: "a/y", isTVType: false)
        XCTAssertEqual(settings, LiveTVSettings(), "going back to the default leaves no trace")
    }

    func testFavouritesToggleAndSettingsSurviveEncoding() throws {
        var settings = LiveTVSettings()
        settings.showTab = true
        settings.playlists = [LivePlaylist(name: "Lista", url: "https://x.test/l.m3u")]
        let favourite = LiveFavorite(id: "m3u:1", name: "Rai 1", url: "https://tv.example/rai1.m3u8")
        settings.toggleFavorite(favourite)
        XCTAssertTrue(settings.isFavorite("m3u:1"))
        let decoded = try JSONDecoder().decode(LiveTVSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        settings.toggleFavorite(favourite)
        XCTAssertFalse(settings.isFavorite("m3u:1"))
        XCTAssertEqual(try JSONDecoder().decode(ContentSettings.self, from: Data("{}".utf8)).liveTV, LiveTVSettings())
    }
}
