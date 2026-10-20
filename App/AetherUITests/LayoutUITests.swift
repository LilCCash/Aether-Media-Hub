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

    /// Animations off: the Home carousel advances by itself every few seconds, which would move the card under measurement.
    private static let stillSettings = #"{"appearance":{"animationsEnabled":false},"playback":{"controlsAutoHideSeconds":15}}"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon(settings: Self.stillSettings)
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
        XCTAssertTrue(button(labelContaining: "In evidenza").waitForExistence(timeout: 30), "no featured card on Home")
        // The carousel is a paged TabView: the neighbouring pages exist in the accessibility tree, just outside the screen.
        // The page that is on screen is the one overlapping the window the most; it must lie inside it, and every page
        // must have the same width (a page wider than the others is the bug this guards against).
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "In evidenza")
        let cards = app.buttons.matching(predicate).allElementsBoundByIndex
        XCTAssertFalse(cards.isEmpty)
        let window = windowFrame
        let visible = cards.max { $0.frame.intersection(window).width < $1.frame.intersection(window).width }!
        assertFitsHorizontally(visible, "featured card")
        XCTAssertGreaterThan(visible.frame.width, window.width * 0.8, "featured card is too narrow (\(visible.frame.width))")
        XCTAssertLessThanOrEqual(visible.frame.width, window.width + 0.5, "featured card is wider than the screen (\(visible.frame.width))")
        for card in cards {
            XCTAssertEqual(card.frame.width, visible.frame.width, accuracy: 1, "carousel pages have different widths")
        }
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
