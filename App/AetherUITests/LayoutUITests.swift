import XCTest

/// Guards against the layout bug where wide artwork (16:9 backdrops, as real catalogs return them) made the detail
/// screen and the Home carousel wider than the screen, so their sides were cut off.
/// The assertions are geometric: every element that is meant to fit the screen must lie inside the window horizontally.
final class LayoutUITests: AetherUITestCase {
    private var windowFrame: CGRect { app.windows.firstMatch.frame }

    private func assertFitsHorizontally(_ element: XCUIElement, _ name: String, context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 30), "\(name) does not exist", file: file, line: line)
        let frame = element.frame
        let window = windowFrame
        XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 0.5, "\(name) starts left of the screen (minX=\(frame.minX), width=\(frame.width), window=\(window)) \(context)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(name) ends right of the screen (maxX=\(frame.maxX), width=\(window.width)) \(context)", file: file, line: line)
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
        let report = cards.map { "[x=\($0.frame.minX) w=\($0.frame.width) h=\($0.frame.height) y=\($0.frame.minY)]" }.joined(separator: " ")
        let hero = element("home.hero").frame
        let context = "cards=\(report) home.hero=\(hero)"
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "home-carousel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // The accessibility frame of a card that holds a 16:9 picture drawn with .fill is the union of what it draws, including
        // the part its own clip hides, so its width is not the layout width. What the frame does prove is the horizontal
        // centre: a page that is shifted (the bug this guards against) is not centred on the screen. The carousel container
        // itself is a plain layout view and must fit the screen exactly.
        XCTAssertGreaterThanOrEqual(hero.minX, window.minX - 0.5, "carousel starts left of the screen. \(context)")
        XCTAssertLessThanOrEqual(hero.maxX, window.maxX + 0.5, "carousel ends right of the screen. \(context)")
        XCTAssertEqual(hero.width, window.width, accuracy: 1, "the carousel must be exactly as wide as the screen. \(context)")
        XCTAssertEqual(visible.frame.midX, window.midX, accuracy: 2, "the featured card is not centred on the screen. \(context)")
        XCTAssertTrue(visible.frame.width >= window.width * 0.8, "featured card is too narrow (\(visible.frame.width))")
        // Pages are laid out one screen apart.
        for card in cards where card != visible {
            let distance = abs(card.frame.midX - visible.frame.midX)
            XCTAssertEqual(distance, window.width, accuracy: 2, "neighbouring carousel pages must be one screen width apart. \(context)")
        }
    }

    func testRowsKeepTheirTitlesAndScrollHorizontally() {
        openTab("Home")
        let title = app.staticTexts["Fixture Movies"]
        assertFitsHorizontally(title, "catalog title")
        XCTAssertGreaterThanOrEqual(title.frame.minX, 8, "catalog title is outside the page margin")
    }

    /// A broad sweep: on every main screen no button, text or picture may be wider than the screen. Scrolling containers
    /// are excluded (their content is legitimately wider); the hero bug made one of the visible cards 1.65x the screen.
    func testNoVisibleElementIsWiderThanTheScreen() {
        let window = windowFrame
        for tab in ["Home", "Scopri", "Cerca", "Libreria", "Altro"] {
            let button = app.tabBars.buttons[tab]
            guard button.waitForExistence(timeout: 10) else { continue }
            button.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            var offenders: [String] = []
            for query in [app.buttons, app.staticTexts] {
                let elements = query.allElementsBoundByIndex.prefix(120)
                for element in elements where element.exists {
                    let frame = element.frame
                    // Cards that draw a picture report the union of what they draw (see testHomeCarouselFitsTheScreenWidth);
                    // the carousel is checked there, so its cards are not repeated here.
                    if element.label.hasPrefix("In evidenza") || element.label.hasSuffix("Dettagli") { continue }
                    if frame.intersects(window) && frame.width > window.width + 1 {
                        offenders.append("\(element.elementType.rawValue) '\(element.label.prefix(40))' w=\(Int(frame.width)) x=\(Int(frame.minX))")
                    }
                }
            }
            XCTAssertTrue(offenders.isEmpty, "\(tab): elements wider than the \(Int(window.width)) pt screen: \(offenders.prefix(5))")
        }
    }

    func testStreamPickerFitsTheScreenWidth() {
        openFixtureMovie()
        openStreamPicker()
        assertFitsHorizontally(element("stream.row.0"), "first source row")
    }
}
