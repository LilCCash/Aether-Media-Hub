import XCTest
@testable import Aether

final class QuotesTests: XCTestCase {
    func testEveryLineHasATextAFilmAndAnImdbId() {
        XCTAssertGreaterThan(Quotes.all.count, 20)
        for quote in Quotes.all {
            XCTAssertFalse(quote.text.isEmpty)
            XCTAssertFalse(quote.film.isEmpty)
            XCTAssertNotNil(quote.id.range(of: "^tt[0-9]{7,8}$", options: .regularExpression), quote.film)
        }
        XCTAssertEqual(Set(Quotes.all.map { $0.text }).count, Quotes.all.count, "no line is repeated")
    }

    func testTheLineChangesEveryThreeHoursAndTheViewerCanMoveByHand() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = Quotes.index(at: start, offset: 0)
        XCTAssertEqual(Quotes.index(at: start.addingTimeInterval(60), offset: 0), first, "within the same three hours")
        XCTAssertEqual(Quotes.index(at: start.addingTimeInterval(3 * 3600), offset: 0), (first + 1) % Quotes.all.count)
        XCTAssertEqual(Quotes.index(at: start, offset: 1), (first + 1) % Quotes.all.count)
        XCTAssertEqual(Quotes.index(at: start, offset: -1), (first - 1 + Quotes.all.count) % Quotes.all.count)
        XCTAssertTrue((0..<Quotes.all.count).contains(Quotes.index(at: start, offset: -10_000)))
    }

    func testTheSnapshotOfAnOlderVersionStillReads() throws {
        let old = Data("{\"updated\":0,\"items\":[]}".utf8)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: old)
        XCTAssertNil(decoded.pool)
        XCTAssertNil(decoded.stats)
        XCTAssertEqual(WidgetSnapshot.deepLink(type: "movie", id: "tt0068646")?.absoluteString, "aether://detail/movie/tt0068646")
    }
}
