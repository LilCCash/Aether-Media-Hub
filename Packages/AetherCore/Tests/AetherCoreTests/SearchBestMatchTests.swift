import XCTest
@testable import AetherCore

final class SearchBestMatchTests: XCTestCase {
    private func row(_ names: [String]) -> SearchRow {
        let catalog = ManifestCatalog(type: "movie", id: "c", name: "c", extra: [])
        let items = names.enumerated().map { MetaItem(id: "tt\($0.offset)\($0.element.count)", type: "movie", name: $0.element) }
        return SearchRow(ref: CatalogRef(addonID: UUID(), addonName: "A", catalog: catalog), items: items, error: nil, isStale: false)
    }

    func testTheExactNameWinsOverEarlierResults() {
        let rows = [row(["Dune: Part Two", "Dune Drifter"]), row(["Dune"])]
        XCTAssertEqual(SearchService.pickBest(query: "dune", rows: rows)?.name, "Dune")
    }

    func testANameStartingWithTheQueryComesNext() {
        let rows = [row(["The Batman Returns of", "Batman Begins"])]
        XCTAssertEqual(SearchService.pickBest(query: "Batman", rows: rows)?.name, "Batman Begins")
    }

    func testOtherwiseTheFirstResult() {
        let rows = [row([]), row(["Interstellar", "Inception"])]
        XCTAssertEqual(SearchService.pickBest(query: "film spaziale", rows: rows)?.name, "Interstellar")
        XCTAssertNil(SearchService.pickBest(query: "x", rows: [row([])]))
    }
}
