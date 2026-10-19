import XCTest

/// Scenarios 3, 4, 5, 6 and 14: catalogs, search, details, several sources, unsupported sources.
final class BrowseUITests: AetherUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon()
    }

    // 3. Catalogs
    func testCatalogsLoadOnHomeAndDiscover() {
        XCTAssertTrue(app.staticTexts["Fixture Movies"].waitForExistence(timeout: 30), "the movie catalog row has a title")
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").exists)
        XCTAssertTrue(button(labelContaining: "Aether Fixture Two").exists)

        openTab("Scopri")
        XCTAssertTrue(element("discover.grid").waitForExistence(timeout: 30) || button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
    }

    // 4. Search across addons
    func testSearchFindsTitlesAndShowsEmptyState() {
        openTab("Cerca")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("two")
        XCTAssertTrue(button(labelContaining: "Aether Fixture Two").waitForExistence(timeout: 30), "search should return the matching title")
        XCTAssertFalse(button(labelContaining: "Aether Fixture One").exists, "non matching titles must not be listed")

        field.clearAndType("zzzz-no-such-title")
        XCTAssertTrue(element("search.empty").waitForExistence(timeout: 30), "an empty result explains itself")
    }

    // 5. Title details
    func testDetailsShowMetadata() {
        openFixtureMovie()
        XCTAssertTrue(element("detail.play").exists)
        XCTAssertTrue(element(labelContaining: "controlled fixture title").exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'fixture'")).firstMatch.exists)
    }

    // 5b. A series lists its episodes
    func testSeriesShowsEpisodes() {
        openTab("Home")
        let card = button(labelContaining: "Fixture Series")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        XCTAssertTrue(element("episode.tt9100001:1:1").waitForExistence(timeout: 30))
        XCTAssertTrue(element("episode.tt9100001:1:2").exists)
    }

    // 6. More than one source for the same title
    func testSourcesFromTheAddonAreListed() {
        openFixtureMovie()
        openStreamPicker()
        XCTAssertTrue(element("stream.row.1").waitForExistence(timeout: 15), "the addon returns two playable sources")
    }

    // 14. A source the engine cannot play is flagged before playback, never started
    func testUnsupportedSourcesAreFlaggedInsteadOfPlayed() {
        openTitleViaSearch("Unsupported", expecting: "Unsupported Format")
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 20))
        element("detail.play").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Non riproducibili'")).firstMatch.waitForExistence(timeout: 30)
                      || element(labelContaining: "Non riproducibili su iOS").waitForExistence(timeout: 30),
                      "MKV / torrent sources should be listed as not playable")
        XCTAssertFalse(element("stream.row.0").exists, "there is nothing playable to start")
    }

    // 6b. A title without sources says so
    func testTitleWithoutSourcesShowsEmptyState() {
        openTitleViaSearch("Nothing", expecting: "Nothing To Watch")
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 20))
        element("detail.play").tap()
        XCTAssertTrue(element("stream.empty").waitForExistence(timeout: 30))
    }
}
