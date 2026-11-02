import XCTest
@testable import AetherCore

final class DebridCloudTests: XCTestCase {
    func testRealDebridTorrentsAndDownloadsBecomeCloudItems() {
        let torrents: [[String: Any]] = [
            ["id": "AB12", "filename": "Film.2024.2160p", "hash": "abcdef", "bytes": 4_000_000_000, "progress": 100, "status": "downloaded"],
            ["id": "CD34", "filename": "Altro", "hash": "123456", "bytes": 1_000, "progress": 40, "status": "downloading"],
            ["status": "downloaded"],
        ]
        let downloads: [[String: Any]] = [["id": "ZZ", "filename": "clip.mp4", "download": "https://cdn.example/clip.mp4", "filesize": 5_000]]
        let items = RealDebridCloud.items(torrents: torrents, downloads: downloads)
        XCTAssertEqual(items.map { $0.id }, ["realdebrid:t:AB12", "realdebrid:t:CD34", "realdebrid:d:ZZ"])
        XCTAssertTrue(items[0].isReady)
        XCTAssertFalse(items[1].isReady)
        XCTAssertEqual(items[1].progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(items[2].kind, .web)
        XCTAssertEqual(items[2].directLink, "https://cdn.example/clip.mp4")
    }
}
