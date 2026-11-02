import XCTest
@testable import AetherCore

final class ExternalPlayerTests: XCTestCase {
    private let media = URL(string: "https://cdn.example/live/rai1.m3u8?token=a&b=c")!

    func testEachPlayerGetsItsOwnAddress() {
        XCTAssertEqual(ExternalPlayer.vlc.url(for: media)?.absoluteString,
                       "vlc-x-callback://x-callback-url/stream?url=https%3A%2F%2Fcdn.example%2Flive%2Frai1.m3u8%3Ftoken%3Da%26b%3Dc")
        XCTAssertTrue(ExternalPlayer.infuse.url(for: media)?.absoluteString.hasPrefix("infuse://x-callback-url/play?url=https%3A") ?? false)
        XCTAssertEqual(ExternalPlayer.nplayer.url(for: media)?.absoluteString, "nplayer-https://cdn.example/live/rai1.m3u8?token=a&b=c")
        XCTAssertEqual(ExternalPlayer.outplayer.url(for: media)?.absoluteString, "outplayer://https://cdn.example/live/rai1.m3u8?token=a&b=c")
    }

    func testOnlyDirectWebLinksAreHandedOver() {
        XCTAssertNil(ExternalPlayer.vlc.url(for: URL(string: "magnet:?xt=urn:btih:abc")!))
        XCTAssertNil(AddonStream(source: .external("https://example.org/page")).directMediaURL)
        XCTAssertNil(AddonStream(source: .youtube("abc")).directMediaURL)
        XCTAssertEqual(AddonStream(source: .url("https://cdn.example/a.mp4")).directMediaURL?.host, "cdn.example")
    }
}
