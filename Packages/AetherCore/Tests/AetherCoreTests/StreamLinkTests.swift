import XCTest
@testable import AetherCore

final class StreamLinkTests: XCTestCase {
    func testDirectLinksAndPagesAreCopiedAsTheyAre() {
        XCTAssertEqual(AddonStream(source: .url("https://cdn.example/rai1.m3u8")).shareableLink, "https://cdn.example/rai1.m3u8")
        XCTAssertEqual(AddonStream(source: .external("https://example.org/watch")).shareableLink, "https://example.org/watch")
        XCTAssertEqual(AddonStream(source: .youtube("abc123")).shareableLink, "https://www.youtube.com/watch?v=abc123")
        XCTAssertNil(AddonStream(source: .url("  ")).shareableLink)
        XCTAssertNil(AddonStream(source: .unknown).shareableLink)
    }

    func testATorrentBecomesAMagnetWithTrackersAndFile() {
        let stream = AddonStream(source: .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 3,
                                                  trackers: ["tracker:udp://t.example:1/announce", "dht:0123"]),
                                 behaviorHints: StreamBehaviorHints(filename: "Film 2020.mkv"))
        let link = stream.shareableLink ?? ""
        XCTAssertTrue(link.hasPrefix("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
        XCTAssertTrue(link.contains("&dn=Film%202020.mkv"))
        XCTAssertTrue(link.contains("&tr=udp://t.example:1/announce"))
        XCTAssertFalse(link.contains("dht:"))
        XCTAssertTrue(link.hasSuffix("&so=3"))
    }
}
