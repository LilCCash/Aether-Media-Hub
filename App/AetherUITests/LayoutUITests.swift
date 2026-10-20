import XCTest

/// Guards against the layout bug where wide artwork (16:9 backdrops, as real catalogs return them) made the detail
/// screen and the Home carousel wider than the screen, so their sides were cut off.
/// The assertions are geometric: every element that is meant to fit the screen must lie inside the window horizontally.
final class LayoutUITests: AetherUITestCase {
    private var windowFrame: CGRect { app.windows.firstMatch.frame }

    private func assertFitsHorizontally(_ element: XCUIElement, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(name) does not exist", file: file, line: line)
        let frame = element.frame
        let window = windowFrame
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 0.5, "\(name) starts left of the screen (minX=\(frame.minX))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(name) ends right of the screen (maxX=\(frame.maxX), width=\(window.width))", file: file, line: line)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon()
    }

    func testDetailScreenFitsTheScreenWidth() {
        openFixtureMovie()
        assertFitsHorizontally(element("detail.title"), "movie title")
        assertFitsHorizontally(element("detail.play"), "play button")
        assertFitsHorizontally(element("detail.watchlist"), "watchlist button")
        // The play button is a wide call to action: it must keep a margin on both sides, not touch an edge.
        let play = element("detail.play").frame
        XCTAssertGreaterThan(play.minX, 4, "play button hugs the left edge")
        XCTAssertLessThan(play.maxX, windowFrame.maxX - 4, "play button hugs the right edge")
    }

    func testSeriesDetailScreenFitsTheScreenWidth() {
        openTab("Home")
        let card = button(labelContaining: "Fixture Series")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        assertFitsHorizontally(element("detail.title"), "series title")
        assertFitsHorizontally(element("detail.play"), "play button")
        assertFitsHorizontally(element("episode.tt9100001:1:1"), "first episode row")
    }

    func testHomeCarouselFitsTheScreenWidth() {
        openTab("Home")
        let hero = button(labelContaining: "In evidenza")
        assertFitsHorizontally(hero, "featured card")
        let frame = hero.frame
        XCTAssertGreaterThan(frame.width, windowFrame.width * 0.8, "featured card is too narrow (\(frame.width))")
        XCTAssertLessThanOrEqual(frame.width, windowFrame.width + 0.5, "featured card is wider than the screen (\(frame.width))")
    }

    func testRowsKeepTheirTitlesAndScrollHorizontally() {
        openTab("Home")
        let title = app.staticTexts["Fixture Movies"]
        assertFitsHorizontally(title, "catalog title")
        XCTAssertGreaterThanOrEqual(title.frame.minX, 8, "catalog title is outside the page margin")
    }

    func testStreamPickerFitsTheScreenWidth() {
        openFixtureMovie()
        openStreamPicker()
        assertFitsHorizontally(element("stream.row.0"), "first source row")
    }
}
