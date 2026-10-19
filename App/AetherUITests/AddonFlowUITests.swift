import XCTest

/// Scenarios 1, 2 and 13 of the test plan: installing, rejecting and living with unavailable addons.
final class AddonFlowUITests: AetherUITestCase {
    private func openInstallSheet() {
        openTab("Altro")
        let addons = element("more.addons")
        XCTAssertTrue(addons.waitForExistence(timeout: 10))
        addons.tap()
        let add = element("addons.add")
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let install = app.buttons["Installa da URL"]
        XCTAssertTrue(install.waitForExistence(timeout: 10))
        install.tap()
        XCTAssertTrue(element("addon.install.field").waitForExistence(timeout: 10))
    }

    private func typeAndVerify(_ url: String) {
        let field = element("addon.install.field")
        field.tap()
        // iOS shows a one-time "swipe to type" explainer on fresh simulators.
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) { continueButton.tap() }
        field.typeText(url)
        element("addon.install.verify").tap()
    }

    // 1. Installing a valid addon (typing the URL, the manual path)
    func testInstallValidAddonByTypingItsURL() {
        launch()
        openInstallSheet()
        typeAndVerify(Fixture.manifestURL)
        let confirm = element("addon.install.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "valid manifest should produce an install preview")
        XCTAssertTrue(element(labelContaining: "Aether Fixture").exists || app.staticTexts["Aether Fixture"].exists)
        confirm.tap()
        XCTAssertTrue(element("addon.row.org.aether.fixture").waitForExistence(timeout: 20))
    }

    // 1b. Installing through the aether:// deep link shows the preview and installs
    func testInstallThroughDeepLink() {
        launchWithFixtureAddon()
        openTab("Home")
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30),
                      "catalogs of the new addon should fill Home")
    }

    // 2. A manifest that is not valid is refused with a message, nothing is installed
    func testRejectsInvalidManifests() {
        launch()
        openInstallSheet()
        typeAndVerify(Fixture.badManifestURL)
        XCTAssertTrue(element("addon.install.error").waitForExistence(timeout: 20), "an incomplete manifest must be refused")
        XCTAssertFalse(element("addon.install.confirm").exists)

        let field = element("addon.install.field")
        field.tap()
        field.clearAndType(Fixture.htmlManifestURL)
        element("addon.install.verify").tap()
        XCTAssertTrue(element("addon.install.error").waitForExistence(timeout: 20), "an HTML page must be refused")
        XCTAssertFalse(element("addon.install.confirm").exists)
    }

    // 2b. Dangerous schemes never reach the network
    func testRejectsNonHTTPSchemes() {
        launch()
        openInstallSheet()
        typeAndVerify("javascript:alert(1)")
        XCTAssertTrue(element("addon.install.error").waitForExistence(timeout: 10))
        XCTAssertTrue(Fixture.requestedPaths().isEmpty, "nothing should have been requested")
    }

    // 13a. Installing while the addon is down explains the problem
    func testInstallingWhileAddonIsOfflineShowsAnError() {
        launch()
        XCTAssertTrue(Fixture.control("/__control/offline?on=1"))
        openInstallSheet()
        typeAndVerify(Fixture.manifestURL)
        XCTAssertTrue(element("addon.install.error").waitForExistence(timeout: 30))
    }

    // 13b. An installed addon that goes offline leaves the app usable and offers a retry
    func testInstalledAddonGoingOfflineShowsRetryNotACrash() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15},"storage":{"cacheMetadata":false}}"#)
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
        app.terminate()

        XCTAssertTrue(Fixture.control("/__control/offline?on=1"))
        launch(reset: false, settings: #"{"playback":{"controlsAutoHideSeconds":15},"storage":{"cacheMetadata":false}}"#)
        openTab("Home")
        XCTAssertTrue(app.buttons["Riprova"].waitForExistence(timeout: 40), "a failed catalog should offer a retry button")
        XCTAssertTrue(app.tabBars.firstMatch.exists)

        XCTAssertTrue(Fixture.control("/__control/offline?on=0"))
        app.buttons["Riprova"].tap()
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30), "retrying after recovery should load the catalog")
    }
}

extension XCUIElement {
    /// Replaces the text of a field.
    func clearAndType(_ text: String) {
        guard let current = value as? String, !current.isEmpty else { typeText(text); return }
        tap()
        let delete = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
        typeText(delete)
        typeText(text)
    }
}
