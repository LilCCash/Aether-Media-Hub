import XCTest

/// 1.1: the Home follows the viewer's choices (order, card style and size, hero style), the Cast button of the Home opens
/// something, and the logo in About hides a secret. Geometry is measured on the card of the "Aether Fixture One" title.
final class HomeCustomizationUITests: AetherUITestCase {
    private var window: CGRect { app.windows.firstMatch.frame }

    /// The settings JSON of a run: still screen (no carousel turning under the measurement), the given appearance extras.
    private static func settings(_ appearance: String) -> String {
        return #"{"appearance":{"animationsEnabled":false,\#(appearance)},"playback":{"controlsAutoHideSeconds":15}}"#
    }

    private static let heroHidden = #"{"id":"hero","isVisible":false}"#
    private static let otherSections = #"{"id":"continue"},{"id":"nextUp"},{"id":"watchlist"}"#

    /// A row card of the fixture title: its label starts with the title (the carousel's starts with "In evidenza").
    private func rowCard() -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", "Aether Fixture One")
        return app.buttons.matching(predicate).firstMatch
    }

    private func catalogCardWidth(sections: String) -> CGFloat {
        launchWithFixtureAddon(settings: HomeCustomizationUITests.settings(#""homeSections":[\#(sections)]"#))
        let card = rowCard()
        XCTAssertTrue(card.waitForExistence(timeout: 30), "no catalogue card on Home")
        return card.frame.width
    }

    // MARK: Card style and size

    func testCatalogCardsAreThePostersOfOneDotZeroByDefault() {
        let width = catalogCardWidth(sections: "\(Self.heroHidden),\(Self.otherSections),{\"id\":\"catalogs\"}")
        XCTAssertEqual(width, 128, accuracy: 2, "the general poster size (medium) is 128 pt")
    }

    func testSmallWideCards() {
        let width = catalogCardWidth(sections: "\(Self.heroHidden),\(Self.otherSections),{\"id\":\"catalogs\",\"style\":\"landscape\",\"size\":\"small\"}")
        XCTAssertEqual(width, 200, accuracy: 2)
    }

    func testLargeWideCards() {
        let width = catalogCardWidth(sections: "\(Self.heroHidden),\(Self.otherSections),{\"id\":\"catalogs\",\"style\":\"landscape\",\"size\":\"large\"}")
        XCTAssertEqual(width, 290, accuracy: 2)
    }

    func testLargePosters() {
        let width = catalogCardWidth(sections: "\(Self.heroHidden),\(Self.otherSections),{\"id\":\"catalogs\",\"style\":\"poster\",\"size\":\"large\"}")
        XCTAssertEqual(width, 156, accuracy: 2)
    }

    // MARK: Order

    func testSectionOrderIsHonoured() {
        // Catalogues first: the first card sits at the top, where the carousel used to be.
        launchWithFixtureAddon(settings: Self.settings(#""homeSections":[{"id":"catalogs"},{"id":"hero"},\#(Self.otherSections)]"#))
        let card = rowCard()
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertLessThan(card.frame.minY, 400, "catalogues were put first but the card is at y=\(card.frame.minY)")
    }

    func testDefaultOrderPutsTheCarouselFirst() {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"card""#))
        let card = rowCard()
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertGreaterThan(card.frame.minY, 450, "the first catalogue card should sit below the carousel (y=\(card.frame.minY))")
    }

    // MARK: Hero

    func testFullBleedHeroFillsTheWidthAndIsTaller() {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"fullBleed""#))
        XCTAssertTrue(button(labelContaining: "In evidenza").waitForExistence(timeout: 30), "no featured card on Home")
        let hero = element("home.hero").frame
        XCTAssertEqual(hero.width, window.width, accuracy: 1, "the carousel must be exactly as wide as the screen")
        XCTAssertGreaterThanOrEqual(hero.height, 480, "the full-screen hero is taller than the card (500 pt)")
        XCTAssertGreaterThanOrEqual(hero.minX, window.minX - 0.5)
        XCTAssertLessThanOrEqual(hero.maxX, window.maxX + 0.5)
    }

    func testCardHeroKeepsItsOneDotZeroHeight() {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"card""#))
        XCTAssertTrue(button(labelContaining: "In evidenza").waitForExistence(timeout: 30))
        let hero = element("home.hero").frame
        XCTAssertEqual(hero.width, window.width, accuracy: 1)
        XCTAssertLessThan(hero.height, 460)
    }

    func testGreetingAppearsWhenEnabled() {
        launchWithFixtureAddon(settings: Self.settings(#""greetingEnabled":true,"greetingName":"Giulia""#))
        let greeting = element("home.greeting")
        XCTAssertTrue(greeting.waitForExistence(timeout: 30))
        XCTAssertTrue(greeting.label.contains("Giulia"), "the greeting is \(greeting.label)")
    }

    func testNoGreetingByDefault() {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"card""#))
        XCTAssertTrue(button(labelContaining: "In evidenza").waitForExistence(timeout: 30))
        XCTAssertFalse(element("home.greeting").exists)
    }

    // MARK: Settings screens

    private func openAppearance() {
        openMoreRoot()
        element("more.settings").tap()
        let row = element("settings.Aspetto")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    func testChoosingWideCardsInSettingsChangesTheHome() {
        launchWithFixtureAddon(settings: Self.settings(#""homeSections":[\#(Self.heroHidden),\#(Self.otherSections),{"id":"catalogs"}]"#))
        openAppearance()
        let link = element("settings.homeLayout")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "no 'Personalizza la Home' entry")
        link.tap()
        let style = element("settings.home.style.catalogs")
        scrollUntilHittable(style)
        XCTAssertTrue(style.exists, "no card style picker for the catalogues")
        style.buttons["Orizzontale"].tap()
        let size = element("settings.home.size.catalogs")
        scrollUntilHittable(size)
        size.buttons["Piccola"].tap()
        openTab("Home")
        let card = rowCard()
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertEqual(card.frame.width, 200, accuracy: 2, "wide + small cards are 200 pt")
    }

    func testHomeLayoutScreenOffersTheHeroAndSectionOptions() {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"card""#))
        openAppearance()
        element("settings.homeLayout").tap()
        XCTAssertTrue(element("settings.home.section.hero").waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.home.heroStyle").exists)
        XCTAssertTrue(element("settings.home.reorder").exists)
        element("settings.home.heroStyle").buttons["Schermo intero"].tap()
        openTab("Home")
        XCTAssertTrue(button(labelContaining: "In evidenza").waitForExistence(timeout: 30))
        XCTAssertGreaterThanOrEqual(element("home.hero").frame.height, 480)
    }

    func testStyleScreenListsThePalettesButNotTheSecretOne() {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"card""#))
        openAppearance()
        let link = element("settings.style")
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(element("settings.palette.sunset").waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.palette.aether").exists)
        XCTAssertFalse(element("settings.palette.popcorn").exists, "the secret palette must stay hidden until it is found")
        element("settings.palette.sunset").tap()
        XCTAssertTrue(element("settings.style.preview").exists)
    }

    // MARK: Cast button

    func testTheCastButtonOnTheHomeOpensTheCastSheet() {
        launch()
        openTab("Home")
        let cast = element("home.cast")
        XCTAssertTrue(cast.waitForExistence(timeout: 15), "no cast button on Home")
        cast.tap()
        let done = element("cast.sheet.done")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "tapping Cast did not open anything")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Come si trasmette")).firstMatch.exists,
                      "the sheet does not explain how to cast")
        XCTAssertTrue(app.staticTexts["AirPlay"].exists || element("cast.openSettings").exists)
        done.tap()
        waitUntil(10, "the cast sheet did not close") { !done.exists }
    }

    // MARK: Easter egg

    func testTheLogoHidesAPopcornSurprise() {
        launch(settings: Self.settings(#""heroStyle":"card""#))
        openMoreRoot()
        let about = element("more.about")
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.tap()
        let logo = element("about.logo")
        XCTAssertTrue(logo.waitForExistence(timeout: 10), "no logo on the About screen")
        XCTAssertFalse(element("about.egg.message").exists)
        for _ in 0..<7 { logo.tap() }
        let message = element("about.egg.message")
        XCTAssertTrue(message.waitForExistence(timeout: 10), "seven taps on the logo did nothing")
        XCTAssertTrue(message.label.contains("Popcorn"), "the first pop should say where the secret theme is: \(message.label)")

        // The secret palette is now in the style screen.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element("more.settings").tap()
        let row = element("settings.Aspetto")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        element("settings.style").tap()
        let chip = element("settings.palette.popcorn")
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "the Popcorn palette was not unlocked")
        chip.tap()
    }

    func testFewTapsOnTheLogoOnlyWarmItUp() {
        launch(settings: Self.settings(#""heroStyle":"card""#))
        openMoreRoot()
        element("more.about").tap()
        let logo = element("about.logo")
        XCTAssertTrue(logo.waitForExistence(timeout: 10))
        for _ in 0..<3 { logo.tap() }
        sleep(2)
        XCTAssertFalse(element("about.egg.message").exists, "three taps are only a warm-up, the pop needs seven")
    }

    // MARK: Accessibility

    func testNewSettingsScreensPassTheAccessibilityAudit() throws {
        launchWithFixtureAddon(settings: Self.settings(#""heroStyle":"card""#))
        openAppearance()
        element("settings.style").tap()
        XCTAssertTrue(element("settings.palette.sunset").waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion, .trait])
    }
}
