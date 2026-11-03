import XCTest
@testable import AetherCore

final class DownloadSkipTests: XCTestCase {
    private func item(_ videoID: String?) -> DownloadItem {
        DownloadItem(metaID: "tt0944947", videoID: videoID, type: "series", title: "Serie", sourceURL: "https://x.test/a.mkv")
    }

    func testEpisodeCoordinatesComeFromTheVideoID() {
        let found = item("tt0944947:2:5").episodeCoordinates
        XCTAssertEqual(found?.season, 2)
        XCTAssertEqual(found?.episode, 5)
        XCTAssertNil(item(nil).episodeCoordinates)
        XCTAssertNil(item("tt0944947").episodeCoordinates)
    }

    func testSkipSegmentsAreKeptWithTheDownloadAndSurviveEncoding() throws {
        var download = item("tt0944947:1:1")
        XCTAssertNil(download.storedSkipSegments)
        download.store(skipSegments: EpisodeSkipSegments(intro: SkipSegment(kind: .intro, start: 12, end: 95),
                                                        recap: SkipSegment(kind: .recap, start: 0, end: 10)))
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(download))
        XCTAssertEqual(decoded.storedSkipSegments?.intro?.end, 95)
        XCTAssertEqual(decoded.storedSkipSegments?.recap?.start, 0)
        XCTAssertEqual(decoded.skipChecked, true)
    }

    func testAnEpisodeWithoutSkipDataIsCheckedButHasNoSegments() {
        var download = item("tt0944947:1:2")
        download.store(skipSegments: .none)
        XCTAssertNil(download.storedSkipSegments)
        XCTAssertEqual(download.skipChecked, true)
    }

    func testOldDownloadsWithoutTheNewFieldsStillDecode() throws {
        let old = try JSONEncoder().encode(item("tt0944947:1:1"))
        var object = try JSONSerialization.jsonObject(with: old) as! [String: Any]
        for key in ["introStart", "introEnd", "recapStart", "recapEnd", "skipChecked"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.skipChecked)
    }

    func testContainerIsReadFromTheFirstBytes() {
        let mkv = Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, 0x42, 0xF7, 0x81, 0x01, 0x42, 0xF2, 0x81])
        XCTAssertEqual(ContainerSniffer.container(header: mkv), "mkv")
        let mp4 = Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D, 0, 0, 2, 0])
        XCTAssertEqual(ContainerSniffer.container(header: mp4), "mp4")
        let avi = Data([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x41, 0x56, 0x49, 0x20, 0, 0, 0, 0])
        XCTAssertEqual(ContainerSniffer.container(header: avi), "avi")
        XCTAssertNil(ContainerSniffer.container(header: Data([1, 2, 3])))
    }

    func testPreferDownloadedIsOnByDefaultAndOldSettingsKeepIt() throws {
        XCTAssertTrue(PlaybackSettings().preferDownloaded)
        let decoded = try JSONDecoder().decode(PlaybackSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.preferDownloaded)
    }
}

final class LiveContainerLauncherTests: XCTestCase {
    func testTheLaunchAddressCarriesTheAppAndTheEncodedPlayerLink() throws {
        let media = URL(string: "https://cdn.test/video.mkv?token=a+b")!
        let url = try XCTUnwrap(LiveContainerLauncher.url(scheme: "livecontainer", bundleID: "org.videolan.vlc-ios", media: media, player: .vlc))
        XCTAssertEqual(url.scheme, "livecontainer")
        XCTAssertEqual(url.host, "livecontainer-launch")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "bundle-name" })?.value, "org.videolan.vlc-ios")
        let encoded = try XCTUnwrap(items.first(where: { $0.name == "open-url" })?.value)
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: encoded)), as: UTF8.self)
        XCTAssertEqual(decoded, ExternalPlayer.vlc.url(for: media)?.absoluteString)
    }

    func testAnEmptyAppOrAMalformedSchemeGivesNothing() {
        let media = URL(string: "https://cdn.test/v.mp4")!
        XCTAssertNil(LiveContainerLauncher.url(scheme: "livecontainer", bundleID: " ", media: media, player: .vlc))
        XCTAssertNil(LiveContainerLauncher.url(scheme: "bad scheme://", bundleID: "a.b", media: media, player: .vlc))
        XCTAssertNil(LiveContainerLauncher.url(scheme: "livecontainer", bundleID: "a.b", media: URL(string: "magnet:?xt=1")!, player: .vlc))
    }
}

final class TorBoxWebCloudTests: XCTestCase {
    func testAWebDownloadPointsAtItsBiggestVideo() {
        let entry = TorBoxTorrent(id: 7, hash: nil, name: "Show.S01E01", size: 900, progress: 1, downloadFinished: true, files: [
            TorBoxFile(id: 1, name: "Show.S01E01/readme.txt", size: 5, mimetype: "text/plain"),
            TorBoxFile(id: 2, name: "Show.S01E01/sample.mkv", size: 50, mimetype: "video/x-matroska"),
            TorBoxFile(id: 3, name: "Show.S01E01/Show.S01E01.mkv", size: 800, mimetype: "video/x-matroska")])
        let items = TorBoxWebCloud.items(from: [entry])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].webID, 7)
        XCTAssertEqual(items[0].fileID, 3)
        XCTAssertEqual(items[0].kind, .web)
        XCTAssertTrue(items[0].isReady)
    }
}

final class SeasonPackDetectorTests: XCTestCase {
    func testSeasonPacksAreRecognised() {
        for name in ["Show.S01.1080p.BluRay.x265", "Show S02 COMPLETE", "Show Complete Season 3", "Show Stagione Completa ITA",
                     "Show.S01E01-E10.1080p", "Show Season 4 2160p", "Show.S01E01-10.WEB-DL", "Show Integrale"] {
            XCTAssertEqual(SeasonPackDetector.kind(of: name), .season, name)
        }
    }

    func testSeriesPacksAreRecognised() {
        for name in ["Show Complete Series 1080p", "Show S01-S05 1080p", "Show.Serie.Completa.ITA", "Show All Seasons"] {
            XCTAssertEqual(SeasonPackDetector.kind(of: name), .series, name)
        }
    }

    func testSingleEpisodesAndFilmsAreNot() {
        for name in ["Show.S01E05.1080p.WEB-DL", "Show 1x05 HDTV", "Film.2023.2160p.BluRay", "Show S02E10 Finale", "Show S03E02 x265"] {
            XCTAssertNil(SeasonPackDetector.kind(of: name), name)
        }
    }
}
