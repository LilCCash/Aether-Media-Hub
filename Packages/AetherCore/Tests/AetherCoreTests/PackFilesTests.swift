import XCTest
@testable import AetherCore

final class PackFilesTests: XCTestCase {
    private func file(_ id: Int, _ name: String, size: Int64 = 1_000_000_000) -> TorBoxFile {
        return TorBoxFile(id: id, name: name, shortName: nil, size: size, mimetype: "video/x-matroska")
    }

    func testASeasonPackListsItsEpisodes() {
        let files = [file(1, "Show.S01.1080p/Show.S01E01.mkv"), file(2, "Show.S01.1080p/Show.S01E02.mkv"),
                     file(3, "Show.S01.1080p/Show.S01E03.mkv"), file(4, "Show.S01.1080p/Sample/sample.mkv", size: 5_000_000),
                     file(5, "Show.S01.1080p/readme.txt")]
        let pack = TorBoxFileMatcher.packFiles(from: files)
        XCTAssertTrue(pack.contains { $0.contains(season: 1, episode: 1) })
        XCTAssertTrue(pack.contains { $0.contains(season: 1, episode: 2) })
        XCTAssertTrue(pack.contains { $0.contains(season: 1, episode: 3) })
        XCTAssertFalse(pack.contains { $0.name == "readme.txt" })
        XCTAssertFalse(pack.contains { $0.contains(season: 1, episode: 9) })
        XCTAssertFalse(pack.contains { $0.contains(season: 2, episode: 1) })
    }

    func testAFileWithoutEpisodeNumbersMatchesNothing() {
        XCTAssertFalse(DebridPackFile(name: "Film.mkv").contains(season: 1, episode: 1))
    }
}
