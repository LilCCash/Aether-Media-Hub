import XCTest

/// Scenarios 15–20 as far as an automated simulator run can cover them (see docs/04-TESTING.md for what it cannot).
final class SettingsAndAccessibilityUITests: AetherUITestCase {
    // 18. Settings persist across launches
    func testSettingsPersistAcrossRelaunch() {
        launch()
        openTab("Altro")
        element("more.settings").tap()
        let privacy = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Account e dati'")).firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 10))
        privacy.tap()
        let toggle = element("settings.allowLocal")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let before = (toggle.value as? String) ?? ""
        toggle.switches.firstMatch.tap()
        let after = (element("settings.allowLocal").value as? String) ?? ""
        XCTAssertNotEqual(before, after, "the toggle should flip")
        app.terminate()

        launch(reset: false, settings: nil)
        openTab("Altro")
        element("more.settings").tap()
        let privacyAgain = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Account e dati'")).firstMatch
        XCTAssertTrue(privacyAgain.waitForExistence(timeout: 10))
        privacyAgain.tap()
        XCTAssertTrue(element("settings.allowLocal").waitForExistence(timeout: 10))
        XCTAssertEqual((element("settings.allowLocal").value as? String) ?? "", after, "the stored value should come back")
    }

    // 15/16/17. What can be checked without a TV: the casting entry points exist and explain themselves.
    // Connecting to a real AirPlay or Google Cast receiver is NOT covered here (hardware only).
    func testCastingScreenExplainsWhatIsAvailable() {
        launch()
        openTab("Altro")
        element("more.casting").tap()
        XCTAssertTrue(app.staticTexts["AirPlay"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Google Cast"].exists || app.staticTexts["GOOGLE CAST"].exists)
        XCTAssertTrue(app.staticTexts["DLNA / UPnP"].exists || app.staticTexts["DLNA / UPNP"].exists)
    }

    func testPlayerExposesCastAndAirPlayControls() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        XCTAssertTrue(element("player.cast").waitForExistence(timeout: 10))
        element("player.cast").tap()
        XCTAssertTrue(app.staticTexts["Dispositivi AirPlay"].waitForExistence(timeout: 10))
        // With no receiver on the simulator's network the list is empty and says why.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nessun'")).firstMatch.waitForExistence(timeout: 15))
    }

    // 20. Accessibility: Apple's automated audit on the main screens, plus labelled controls.
    // VoiceOver navigation on a real device is NOT covered by this test.
    func testMainScreensPassTheAccessibilityAudit() throws {
        launchWithFixtureAddon()
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .elementDetection, .trait])
        openTab("Altro")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait])
        openTab("Cerca")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait])
    }

    func testPlayerControlsHaveAccessibilityLabels() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        for label in ["Chiudi il player", "Pausa", "Audio e sottotitoli", "Altre opzioni"] {
            XCTAssertTrue(app.buttons[label].exists || app.buttons["Riproduci"].exists, "control \(label) lacks an accessibility label")
        }
        XCTAssertTrue(element("player.scrubber").exists)
    }

    // 19. Cache: a second launch with the cache enabled shows catalogs even if the addon went away
    func testCachedCatalogsSurviveAnOfflineAddon() {
        launchWithFixtureAddon()
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
        app.terminate()
        XCTAssertTrue(Fixture.control("/__control/offline?on=1"))
        launch(reset: false)
        openTab("Home")
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 40),
                      "stale-on-error: cached catalogs remain visible while the addon is unreachable")
    }
}
