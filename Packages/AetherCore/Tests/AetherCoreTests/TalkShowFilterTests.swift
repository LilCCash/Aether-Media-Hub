import XCTest
@testable import AetherCore

final class TalkShowFilterTests: XCTestCase {
    private func item(_ id: String, _ genres: [String]) -> MetaItem {
        return MetaItem(id: id, type: "series", name: "Title \(id)", genres: genres)
    }

    func testRecognisesTalkShowsWhateverTheSpelling() {
        XCTAssertTrue(TalkShowFilter.isTalkShow(item("a", ["Comedy", "Talk-Show"])))
        XCTAssertTrue(TalkShowFilter.isTalkShow(item("b", ["talk show"])))
        XCTAssertTrue(TalkShowFilter.isTalkShow(item("c", ["TALK"])))
        XCTAssertFalse(TalkShowFilter.isTalkShow(item("d", ["Drama", "Thriller"])))
        XCTAssertFalse(TalkShowFilter.isTalkShow(item("e", [])))
    }

    func testTheFilterHidesOnlyWhenSwitchedOn() {
        let items = [item("a", ["Talk-Show"]), item("b", ["Drama"])]
        let filter = CatalogItemFilter()
        XCTAssertEqual(filter.apply(items).count, 2)
        filter.hideTalkShows = true
        XCTAssertEqual(filter.apply(items).map { $0.id }, ["b"])
    }

    func testTheSettingSurvivesAnOldBackupWithoutIt() throws {
        let decoded = try JSONDecoder().decode(ContentSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.hideTalkShows)
    }
}
