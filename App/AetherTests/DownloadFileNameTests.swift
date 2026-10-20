import XCTest
@testable import Aether

final class DownloadFileNameTests: XCTestCase {
    func testTheExtensionOfTheURLWinsWhenItIsAContainer() {
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: "https://cdn.test/a/movie.mkv?token=1"), mime: "video/mp4"), "mkv")
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: "https://cdn.test/a/movie.MOV"), mime: ""), "mov")
    }

    func testAHintedContainerSurvivesAURLWithoutExtension() {
        let remembered = DownloadManager.sourceURLString(URL(string: "https://debrid.test/dl/abc123")!, container: "mkv")
        XCTAssertTrue(remembered.hasSuffix("#aether-container=mkv"), remembered)
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: remembered), mime: "application/octet-stream"), "mkv")
    }

    func testURLsThatAlreadyHaveAContainerAreLeftAlone() {
        let url = URL(string: "https://cdn.test/a.mp4?x=1")!
        XCTAssertEqual(DownloadManager.sourceURLString(url, container: "mp4"), url.absoluteString)
    }

    func testTheContentTypeIsTheLastResort() {
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: "https://x.test/dl"), mime: "video/x-matroska"), "mkv")
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: "https://x.test/dl"), mime: "video/webm"), "webm")
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: "https://x.test/dl"), mime: "video/quicktime"), "mov")
        XCTAssertEqual(DownloadManager.fileExtension(forURL: URL(string: "https://x.test/dl"), mime: "video/mp4"), "mp4")
        XCTAssertEqual(DownloadManager.fileExtension(forURL: nil, mime: ""), "mp4", "unknown content defaults to the previous behaviour")
    }

    func testUnknownHintsAreNotTrusted() {
        let remembered = DownloadManager.sourceURLString(URL(string: "https://debrid.test/dl/abc123")!, container: "exe")
        XCTAssertEqual(remembered, "https://debrid.test/dl/abc123")
    }
}
