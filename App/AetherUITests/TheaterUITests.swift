import XCTest

/// Theater Mode: in and out, its rail, and the immersive page of a title that continues in the normal details screen.
final class TheaterUITests: AetherUITestCase {
    private var noIntro: [String] { ["-theater.intro", "NO"] }

    /// What the screen offers, to say why an expected element is missing.
    private func seen() -> String {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(40).map { "\($0.identifier)|\($0.label)" }.joined(separator: " ; ")
        let others = app.otherElements.allElementsBoundByIndex.map { $0.identifier }.filter { $0.hasPrefix("theater") }.joined(separator: ",")
        return "buttons: \(buttons) | theater elements: \(others)"
    }

    private func enter() {
        launchWithFixtureAddon(extraArguments: noIntro)
        openTab("Home")
        let entry = element("home.theater")
        XCTAssertTrue(entry.waitForExistence(timeout: 30), "the way into Theater Mode is not on the Home")
        entry.tap()
        XCTAssertTrue(element("theater.root").waitForExistence(timeout: 20), "Theater Mode did not open")
    }

    func testEnteringSwitchingSectionsAndLeaving() {
        enter()
        for section in ["series", "discover", "library", "settings", "home"] {
            let button = element("theater.rail.\(section)")
            XCTAssertTrue(button.waitForExistence(timeout: 10), "rail button \(section) missing: \(seen())")
            button.tap()
            if section == "settings" {
                XCTAssertTrue(element("theater.more.addons").waitForExistence(timeout: 10), "the settings should offer the same entries as Altro: \(seen())")
                XCTAssertTrue(element("theater.more.about").exists, "Informazioni e licenze missing from the Theater settings")
            }
        }
        XCTAssertFalse(element("theater.rail.search").exists, "search belongs at the top right only, not on the rail")
        XCTAssertTrue(app.buttons["Cerca"].waitForExistence(timeout: 10), "the search button at the top right is missing")
        XCTAssertTrue(element("theater.rail.home").isSelected, "the Film section should be on after tapping it")
        element("theater.exit").tap()
        XCTAssertTrue(element("home.theater").waitForExistence(timeout: 20), "leaving Theater Mode did not return to the Home")
    }

    func testATitleOpensItsImmersivePageAndContinuesInTheSourceChoiceOfTheMode() {
        enter()
        let card = button(labelContaining: "Aether Fixture One")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no title card in the Film section")
        card.tap()
        XCTAssertTrue(element("theater.detail.play").waitForExistence(timeout: 15), "the immersive page did not open: \(seen())")
        element("theater.detail.play").tap()
        // Playing stays in Theater Mode: its own source choice (or, when a source is chosen on its own, the player), never the normal details.
        let picker = element("theater.picker.close")
        let player = element("player.close")
        let deadline = Date().addingTimeInterval(30)
        while !picker.exists && !player.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertTrue(picker.exists || player.exists, "Riproduci should open the source choice of Theater Mode: \(seen())")
        XCTAssertFalse(element("detail.title").exists, "Riproduci must not leave Theater Mode for the normal details")
        if picker.exists {
            picker.tap()
            XCTAssertTrue(element("theater.detail.play").waitForExistence(timeout: 10), "going back should return to the page of the title")
        }
    }
}
