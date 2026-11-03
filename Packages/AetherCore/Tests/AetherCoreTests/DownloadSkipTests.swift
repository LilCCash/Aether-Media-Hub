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
