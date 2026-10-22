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
        for section in ["series", "discover", "library", "search", "settings", "home"] {
            let button = element("theater.rail.\(section)")
            XCTAssertTrue(button.waitForExistence(timeout: 10), "rail button \(section) missing: \(seen())")
            button.tap()
        }
        XCTAssertTrue(element("theater.rail.home").isSelected, "the Film section should be on after tapping it")
        element("theater.exit").tap()
        XCTAssertTrue(element("home.theater").waitForExistence(timeout: 20), "leaving Theater Mode did not return to the Home")
    }

    func testATitleOpensItsImmersivePageAndContinuesInTheDetails() {
        enter()
        let card = button(labelContaining: "Aether Fixture One")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no title card in the Film section")
        card.tap()
        XCTAssertTrue(element("theater.detail.play").waitForExistence(timeout: 15), "the immersive page did not open: \(seen())")
        element("theater.detail.play").tap()
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 20), "Riproduci should continue in the normal details")
    }
}
