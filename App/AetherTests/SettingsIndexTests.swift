import XCTest
@testable import Aether

final class SettingsIndexTests: XCTestCase {
    func testFindsOptionsIgnoringCaseAndAccents() {
        XCTAssertTrue(SettingsIndex.search("velocita").contains { $0.page == .playback })
        XCTAssertTrue(SettingsIndex.search("TORBOX").contains { $0.page == .services })
        XCTAssertTrue(SettingsIndex.search("dlna").contains { $0.page == .casting })
    }

    func testEveryWordMustMatch() {
        XCTAssertTrue(SettingsIndex.search("lingua sottotitoli").allSatisfy { SettingsIndex.fold($0.title + $0.page.title).contains("sottotitoli") })
        XCTAssertTrue(SettingsIndex.search("zzzz nessuna").isEmpty)
        XCTAssertTrue(SettingsIndex.search("   ").isEmpty)
    }

    func testEveryPageIsReachableByItsTitleAndHitsAreUnique() {
        for page in SettingsIndex.Page.allCases {
            XCTAssertTrue(SettingsIndex.search(page.title).contains { $0.page == page }, page.title)
        }
        let hits = SettingsIndex.search("a")
        XCTAssertEqual(hits.count, Set(hits.map(\.id)).count)
    }
}
