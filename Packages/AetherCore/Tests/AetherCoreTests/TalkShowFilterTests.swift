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

    func testEachPlaceIsChosenOnItsOwn() {
        let items = [item("a", ["Talk-Show"]), item("b", ["Drama"])]
        let filter = CatalogItemFilter()
        XCTAssertEqual(filter.apply(items, scope: .home).count, 2)
        filter.setHidden([.home, .search])
        XCTAssertEqual(filter.apply(items, scope: .home).map { $0.id }, ["b"])
        XCTAssertEqual(filter.apply(items, scope: .search).map { $0.id }, ["b"])
        XCTAssertEqual(filter.apply(items, scope: .discover).count, 2)
    }

    func testTheSettingsNameTheScopesOnlyWhenSwitchedOn() throws {
        var content = try JSONDecoder().decode(ContentSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(content.hideTalkShows)
        XCTAssertTrue(content.hiddenTalkScopes.isEmpty)
        content.hideTalkShows = true
        XCTAssertEqual(content.hiddenTalkScopes, Set(ContentScope.allCases))
        content.talkSimilar = false
        XCTAssertFalse(content.hiddenTalkScopes.contains(.similar))
    }
}
