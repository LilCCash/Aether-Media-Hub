import XCTest

// Dynamic filters in Search and configurable categories in Discover, against the fixture server.
//
// The fixture server offers two addons: the main one (films and series, searchable, no genre options) and a second one
// at /extra/manifest.json that provides live TV (searchable, with genres News/Kids) and sports (browse only).
// Installing or removing the second addon while the app runs is how these tests prove that types, genres and years
// are computed from the installed addons and follow them by themselves.

// MARK: - Helpers

extension AetherUITestCase {
    static var extraManifestURL: String { return Fixture.base + "/extra/manifest.json" }
    static var extraAddonRowID: String { return "addon.row.org.aether.fixture.extra" }

    // MARK: Filter menus

    /// The current choice of a filter menu: the menus expose it as their accessibility value.
    func filterMenuValue(_ identifier: String) -> String {
        return (element(identifier).value as? String) ?? ""
    }

    /// An item of the menu that is open. Menu items are buttons; the fallback covers systems that report menu items.
    func filterMenuItem(_ title: String) -> XCUIElement {
        let button = app.buttons[title]
        if button.waitForExistence(timeout: 8) { return button }
        return app.menuItems[title]
    }

    /// Opens a filter menu and returns without choosing anything.
    func openFilterMenu(_ identifier: String) {
        let menu = element(identifier)
        XCTAssertTrue(menu.waitForExistence(timeout: 20), "\(identifier) is not on screen")
        menu.tap()
    }

    /// Opens a filter menu and picks one of its items.
    func chooseFilter(_ identifier: String, _ itemTitle: String) {
        openFilterMenu(identifier)
        let item = filterMenuItem(itemTitle)
        XCTAssertTrue(item.exists, "the menu \(identifier) has no item «\(itemTitle)»")
        item.tap()
    }

    /// Whether the open menu lists `title`. Does not wait long: call it once the menu is open.
    func filterMenuLists(_ title: String) -> Bool {
        return app.buttons[title].waitForExistence(timeout: 3) || app.menuItems[title].exists
    }

    // MARK: Search

    /// Search recomputes its menus when the addons change; the genres of the second addon are the sign that it did.
    func waitForSearchToKnowTheExtraAddon() {
        XCTAssertTrue(element("search.genre").waitForExistence(timeout: 30),
                      "the filter bar did not pick up the installed addon")
    }

    func typeSearch(_ text: String) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search field is missing")
        field.tap()
        field.typeText(text)
    }

    // MARK: Switches and scrolling

    /// The switch of a settings row, whether the identifier sits on the row or on the switch itself.
    func settingsSwitch(_ identifier: String) -> XCUIElement {
        let container = element(identifier)
        XCTAssertTrue(container.waitForExistence(timeout: 15), "\(identifier) is not on screen")
        if container.elementType == .switch { return container }
        let inner = container.switches.firstMatch
        return inner.exists ? inner : container
    }

    func isOn(_ toggle: XCUIElement) -> Bool {
        return (toggle.value as? String) == "1"
    }

    func scrollUntilHittable(_ target: XCUIElement, maxSwipes: Int = 10) {
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    // MARK: Addons

    func openAddonsList() {
        openTab("Altro")
        if element("addons.add").waitForExistence(timeout: 3) { return }
        let addons = element("more.addons")
        XCTAssertTrue(addons.waitForExistence(timeout: 10), "the addons entry is missing")
        addons.tap()
        XCTAssertTrue(element("addons.add").waitForExistence(timeout: 10), "the addon list did not open")
    }

    /// Installs an addon the way a user does, by typing its address, while the app keeps running.
    func installAddonByTyping(_ manifestURL: String, expectingRow rowID: String) {
        openAddonsList()
        element("addons.add").tap()
        let install = app.buttons["Installa da URL"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), "the install entry is missing")
        install.tap()
        let field = element("addon.install.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the install field is missing")
        field.tap()
        // iOS shows a one-time "swipe to type" explainer on fresh simulators.
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 2) { continueButton.tap() }
        field.typeText(manifestURL)
        element("addon.install.verify").tap()
        let confirm = element("addon.install.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "the install preview did not appear")
        confirm.tap()
        XCTAssertTrue(element(rowID).waitForExistence(timeout: 20), "the addon was not listed after install")
    }

    /// Removes an installed addon through its detail page and the confirmation.
    func uninstallAddon(rowID: String) {
        openAddonsList()
        let row = element(rowID)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the addon is not installed")
        row.tap()
        XCTAssertTrue(element("addon.enabled").waitForExistence(timeout: 10), "the detail page did not open")
        // The list is lazy: the button at the bottom only exists once it has been scrolled into view.
        let remove = element("addon.remove")
        scrollUntilHittable(remove)
        XCTAssertTrue(remove.exists && remove.isHittable, "the uninstall button cannot be reached")
        remove.tap()
        // The confirmation button has the same title as the button that opened it, but no identifier.
        let predicate = NSPredicate(format: "label == %@ AND identifier != %@", "Disinstalla", "addon.remove")
        let confirm = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the confirmation did not appear")
        confirm.tap()
        waitUntil(20, "the addon is still listed after being removed") { !self.element(rowID).exists }
    }

    // MARK: Discover settings

    /// Altro > Impostazioni > Aspetto > Categorie di Scopri.
    func openDiscoverSettingsViaSettings() {
        openTab("Altro")
        let settingsEntry = element("more.settings")
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 10), "the settings entry is missing")
        settingsEntry.tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Aspetto'")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), "Aspetto is missing from the settings")
        appearance.tap()
        // The settings list is lazy: the link only exists once it has been scrolled into view.
        let link = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Categorie di Scopri'")).firstMatch
        XCTAssertTrue(app.navigationBars["Aspetto"].waitForExistence(timeout: 10), "the Aspetto page did not open")
        scrollUntilHittable(link)
        XCTAssertTrue(link.exists && link.isHittable, "the link to the Scopri categories cannot be reached")
        link.tap()
        XCTAssertTrue(element("settings.discover.reorder").waitForExistence(timeout: 15)
                      || app.navigationBars["Categorie di Scopri"].waitForExistence(timeout: 5),
                      "the Scopri categories page did not open")
    }
}

// MARK: - Search: filters that need only the main fixture addon

final class SearchFilterUITests: AetherUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon()
    }

    // The bar is built from the installed addons: the main fixture serves films and series, nothing else.
    func testTypeMenuListsOnlyTheTypesOfTheInstalledAddons() {
        openTab("Cerca")
        XCTAssertTrue(element("search.type").waitForExistence(timeout: 20))
        XCTAssertEqual(filterMenuValue("search.type"), "Tutti i tipi")
        openFilterMenu("search.type")
        XCTAssertTrue(filterMenuLists("Film"))
        XCTAssertTrue(filterMenuLists("Serie TV"))
        XCTAssertFalse(app.buttons["TV in diretta"].exists, "no addon provides live TV yet")
        XCTAssertFalse(app.buttons["Sport"].exists, "no addon provides sports yet")
        filterMenuItem("Tutti i tipi").tap()
        XCTAssertFalse(element("search.genre").exists, "no catalog lists genres: a genre menu would do nothing")
        XCTAssertFalse(element("search.reset").exists, "there is nothing to reset yet")
    }

    // Choosing the type before searching asks only the catalogs of that type: nothing is filtered after the fact.
    func testTheTypeDecidesWhichCatalogsAreAsked() {
        openTab("Cerca")
        chooseFilter("search.type", "Serie TV")
        XCTAssertEqual(filterMenuValue("search.type"), "Serie TV")
        typeSearch("fixture")
        XCTAssertTrue(button(labelContaining: "Fixture Series").waitForExistence(timeout: 30), "the series catalog should answer")
        XCTAssertFalse(button(labelContaining: "Aether Fixture One").exists, "films are not part of a series search")

        let paths = Fixture.requestedPaths()
        XCTAssertTrue(paths.contains { $0.contains("/catalog/series/fixture-series/search=fixture") },
                      "the series catalog was not searched: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/catalog/movie/") && $0.contains("search=") },
                       "a film catalog was searched although the type is Serie TV: \(paths)")

        chooseFilter("search.type", "Film")
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30), "films should now be listed")
        waitUntil(20, "the series result should leave when the type changes") {
            !self.button(labelContaining: "Fixture Series").exists
        }
        let after = Fixture.requestedPaths()
        XCTAssertTrue(after.contains { $0.contains("/catalog/movie/fixture-movies/search=fixture") },
                      "the film catalog was not searched after choosing Film: \(after)")
    }

    func testResetFiltersBringsEverythingBack() {
        openTab("Cerca")
        typeSearch("fixture")
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
        XCTAssertTrue(button(labelContaining: "Fixture Series").exists)
        XCTAssertFalse(element("search.reset").exists, "no filter is active, so there is nothing to reset")

        chooseFilter("search.type", "Film")
        waitUntil(20, "the series result should leave") { !self.button(labelContaining: "Fixture Series").exists }
        let reset = element("search.reset")
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "an active filter should offer «Reimposta filtri»")
        reset.tap()

        XCTAssertEqual(filterMenuValue("search.type"), "Tutti i tipi")
        XCTAssertTrue(button(labelContaining: "Fixture Series").waitForExistence(timeout: 30), "series should be back")
        waitUntil(10, "the reset button should disappear once nothing is filtered") { !self.element("search.reset").exists }
    }

    // The sort menu lives in the filter bar now: it must still reorder what is on screen.
    func testSortMenuReordersTheResults() {
        openTab("Cerca")
        typeSearch("fixture")
        let series = button(labelContaining: "Fixture Series")
        let two = button(labelContaining: "Aether Fixture Two")
        XCTAssertTrue(series.waitForExistence(timeout: 30))
        XCTAssertTrue(two.waitForExistence(timeout: 10))
        // Relevance interleaves the catalogs: film, series, film, …
        XCTAssertLessThan(series.frame.minX, two.frame.minX, "by relevance the series comes between the two films")

        chooseFilter("search.sort", "Titolo")
        XCTAssertEqual(filterMenuValue("search.sort"), "Titolo")
        waitUntil(15, "sorted by title «Aether Fixture Two» comes before «Fixture Series»") {
            two.frame.minX < series.frame.minX
        }
    }

    // Year is applied by Aether: the menu appears when results carry years, and the screen says what the filter hid.
    func testYearMenuAppearsWithYearsAndSaysWhatItHid() {
        openTab("Cerca")
        XCTAssertTrue(element("search.sort").waitForExistence(timeout: 20))
        XCTAssertFalse(element("search.year").exists, "nothing was searched, there are no years to offer")
        // Films only: three titles, so every one of them is among the first cards of the row.
        chooseFilter("search.type", "Film")
        typeSearch("fixture")
        XCTAssertTrue(button(labelContaining: "Sparse Fixture Movie").waitForExistence(timeout: 30),
                      "the title without a year is expected in the unfiltered results")
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").exists)
        XCTAssertTrue(element("search.year").waitForExistence(timeout: 10), "results carry years: the year menu should appear")
        XCTAssertFalse(element("search.hidden").exists, "nothing is hidden before a filter is chosen")

        chooseFilter("search.year", "2020–2029")
        XCTAssertEqual(filterMenuValue("search.year"), "2020–2029")
        waitUntil(20, "the title without a year should be hidden by the year filter") {
            !self.button(labelContaining: "Sparse Fixture Movie").exists
        }
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").exists, "a 2021 film stays")
        let hidden = element("search.hidden")
        XCTAssertTrue(hidden.waitForExistence(timeout: 10), "the screen should say what was hidden")
        XCTAssertTrue(hidden.label.contains("1 risultato senza anno nascosto"), "unexpected message: \(hidden.label)")
        let note = element("search.filterNote")
        scrollUntilHittable(note, maxSwipes: 4)
        XCTAssertTrue(note.exists, "the screen should say that the year filter is applied by Aether")
        XCTAssertTrue(note.label.contains("anno"), "unexpected note: \(note.label)")

        let paths = Fixture.requestedPaths()
        XCTAssertFalse(paths.contains { $0.contains("search=") && ($0.contains("year") || $0.contains("2020")) },
                       "the year must never be sent to an addon that does not declare it: \(paths)")
    }
}

// MARK: - Search: filters that follow the installed addons

final class SearchFilterAddonsUITests: AetherUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon()
    }

    // New types, genres and the honest "cannot search" message appear when an addon is installed, with the app running.
    func testInstallingAnAddonAddsItsTypesAndGenres() {
        openTab("Cerca")
        XCTAssertTrue(element("search.type").waitForExistence(timeout: 20))
        XCTAssertFalse(element("search.genre").exists, "no genres are known before the second addon is installed")

        installAddonByTyping(AetherUITestCase.extraManifestURL, expectingRow: AetherUITestCase.extraAddonRowID)
        openTab("Cerca")
        waitForSearchToKnowTheExtraAddon()

        // The type menu now lists live TV and sports next to films and series.
        openFilterMenu("search.type")
        XCTAssertTrue(filterMenuLists("Film"))
        XCTAssertTrue(filterMenuLists("Serie TV"))
        XCTAssertTrue(filterMenuLists("TV in diretta"), "the type of the new addon should be offered by itself")
        XCTAssertTrue(filterMenuLists("Sport"))
        filterMenuItem("Tutti i tipi").tap()

        // The genre menu appeared too (that is what the wait above relied on), with the genres of the searchable addon.
        openFilterMenu("search.genre")
        XCTAssertTrue(filterMenuLists("News"))
        XCTAssertTrue(filterMenuLists("Kids"))
        filterMenuItem("News").tap()
        XCTAssertEqual(filterMenuValue("search.genre"), "News")

        typeSearch("fixture")
        XCTAssertTrue(button(labelContaining: "Fixture News Live").waitForExistence(timeout: 30), "the TV channel with that genre")
        XCTAssertFalse(button(labelContaining: "Fixture Kids Channel").exists, "another genre")
        XCTAssertFalse(button(labelContaining: "Aether Fixture One").exists, "films of another genre must not be listed")

        // The genre travelled only to the catalog whose manifest declares search+genre; the others were filtered by Aether.
        let paths = Fixture.requestedPaths()
        XCTAssertTrue(paths.contains { $0.contains("/extra/catalog/tv/extra-tv/search=fixture&genre=News") },
                      "the genre should be sent to the catalog that declares it: \(paths)")
        XCTAssertTrue(paths.contains { $0.contains("/catalog/movie/fixture-movies/search=fixture") },
                      "the film catalog should still be searched: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/catalog/movie/") && $0.contains("genre=") },
                       "a catalog that does not declare genre must not receive it: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("/catalog/series/") && $0.contains("genre=") },
                       "a catalog that does not declare genre must not receive it: \(paths)")

        let hidden = element("search.hidden")
        XCTAssertTrue(hidden.waitForExistence(timeout: 10), "the film without genres is hidden for lack of data and the screen says so")
        XCTAssertTrue(hidden.label.contains("senza genere nascost"), "unexpected message: \(hidden.label)")
        let note = element("search.filterNote")
        scrollUntilHittable(note, maxSwipes: 4)
        XCTAssertTrue(note.exists, "the screen should say who applied the genre filter")
        XCTAssertTrue(note.label.contains("applicato da Aether"), "unexpected note: \(note.label)")

        // Live TV is searchable and keeps the genre; sports have no search: the message is honest and nothing is asked.
        chooseFilter("search.type", "TV in diretta")
        XCTAssertEqual(filterMenuValue("search.type"), "TV in diretta")
        XCTAssertTrue(button(labelContaining: "Fixture News Live").waitForExistence(timeout: 30))

        chooseFilter("search.type", "Sport")
        let notice = element("search.unsupported")
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "sports cannot be searched: the screen must say so")
        XCTAssertTrue(notice.label.contains("Nessun addon installato supporta la ricerca per «Sport»"), "unexpected notice: \(notice.label)")
        XCTAssertTrue(element("search.empty").waitForExistence(timeout: 20), "an empty result explains itself")
        XCTAssertFalse(button(labelContaining: "Fixture News Live").exists)
        XCTAssertFalse(element("search.genre").exists, "sports list no searchable genres, and the old genre is dropped with the type")
    }

    // Removing the addon takes its types away; a choice that no longer exists is dropped.
    func testRemovingTheAddonRemovesItsTypesAndTheChoice() {
        installAddonByTyping(AetherUITestCase.extraManifestURL, expectingRow: AetherUITestCase.extraAddonRowID)
        openTab("Cerca")
        waitForSearchToKnowTheExtraAddon()
        chooseFilter("search.type", "Sport")
        XCTAssertEqual(filterMenuValue("search.type"), "Sport")
        XCTAssertTrue(element("search.unsupported").waitForExistence(timeout: 10))
        // The choice survives a visit to another tab: when it is gone later, that is the app dropping it, not a fresh screen.
        openTab("Altro")
        openTab("Cerca")
        XCTAssertEqual(filterMenuValue("search.type"), "Sport", "the choice should survive a tab switch")

        uninstallAddon(rowID: AetherUITestCase.extraAddonRowID)
        openTab("Cerca")

        waitUntil(20, "the choice «Sport» should be dropped once nobody provides it") {
            self.filterMenuValue("search.type") == "Tutti i tipi"
        }
        XCTAssertFalse(element("search.unsupported").exists, "the notice belongs to the removed type")
        openFilterMenu("search.type")
        XCTAssertTrue(filterMenuLists("Film"))
        XCTAssertFalse(app.buttons["TV in diretta"].exists, "live TV went away with its addon")
        XCTAssertFalse(app.buttons["Sport"].exists, "sports went away with their addon")
        filterMenuItem("Tutti i tipi").tap()
        XCTAssertFalse(element("search.genre").exists, "its genres went away too")
    }

    // The year menu follows the results of the chosen type, and the screen counts channels that have no year.
    func testYearFilterOnLiveTVCountsChannelsWithoutAYear() {
        installAddonByTyping(AetherUITestCase.extraManifestURL, expectingRow: AetherUITestCase.extraAddonRowID)
        openTab("Cerca")
        waitForSearchToKnowTheExtraAddon()
        chooseFilter("search.type", "TV in diretta")
        typeSearch("fixture")
        XCTAssertTrue(button(labelContaining: "Fixture News Live").waitForExistence(timeout: 30))
        XCTAssertTrue(button(labelContaining: "Fixture Kids Channel").exists)
        XCTAssertTrue(button(labelContaining: "Fixture Night Channel").exists)

        openFilterMenu("search.year")
        XCTAssertTrue(filterMenuLists("2020–2029"))
        XCTAssertTrue(filterMenuLists("2010–2019"))
        filterMenuItem("2010–2019").tap()

        waitUntil(20, "only the 2018 channel should remain") { !self.button(labelContaining: "Fixture News Live").exists }
        XCTAssertTrue(button(labelContaining: "Fixture Kids Channel").exists)
        XCTAssertFalse(button(labelContaining: "Fixture Night Channel").exists, "a channel without a year cannot satisfy a year filter")
        let hidden = element("search.hidden")
        XCTAssertTrue(hidden.waitForExistence(timeout: 10))
        XCTAssertTrue(hidden.label.contains("1 risultato senza anno nascosto"), "unexpected message: \(hidden.label)")
    }
}

// MARK: - Dynamic Type

final class SearchFilterLargeTextUITests: AetherUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    // At the largest accessibility text size the bar scrolls instead of overflowing, and every control stays reachable.
    func testFilterBarStaysUsableAtTheLargestTextSize() {
        openTab("Cerca")
        let type = element("search.type")
        XCTAssertTrue(type.waitForExistence(timeout: 20))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(type.frame.minX, window.minX, "the first control starts outside the screen")
        XCTAssertLessThanOrEqual(type.frame.maxX, window.maxX + 1, "the first control is wider than the screen")
        XCTAssertGreaterThanOrEqual(type.frame.height, 44, "controls keep a comfortable touch target")

        revealInFilterBar("search.sort", anchor: type)
        chooseFilter("search.sort", "Titolo")
        XCTAssertEqual(filterMenuValue("search.sort"), "Titolo", "the last control of the bar must be reachable too")

        openTab("Scopri")
        let chip = element("discover.type.movie")
        XCTAssertTrue(chip.waitForExistence(timeout: 30))
        XCTAssertLessThanOrEqual(chip.frame.maxX, window.maxX + 1)
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
    }

    /// Scrolls the horizontal filter bar sideways until `identifier` can be tapped. `anchor` is the first control, which
    /// always starts at the leading edge and tells at which height the bar is.
    private func revealInFilterBar(_ identifier: String, anchor: XCUIElement) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(identifier) is missing from the bar")
        let window = app.windows.firstMatch.frame
        let height = anchor.frame.midY
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < 8 {
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let start = origin.withOffset(CGVector(dx: window.width * 0.85, dy: height))
            let end = origin.withOffset(CGVector(dx: window.width * 0.15, dy: height))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
    }
}

// MARK: - Discover

final class DiscoverCategoriesUITests: AetherUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        launchWithFixtureAddon()
    }

    // Chips come from the installed addons, in canonical order, and follow them while the app runs.
    func testChipsFollowTheInstalledAddons() {
        openTab("Scopri")
        let movie = element("discover.type.movie")
        let series = element("discover.type.series")
        XCTAssertTrue(movie.waitForExistence(timeout: 30))
        XCTAssertTrue(series.exists)
        XCTAssertFalse(element("discover.type.tv").exists)
        XCTAssertFalse(element("discover.type.sports").exists)
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30), "the first type is selected")

        series.tap()
        XCTAssertTrue(button(labelContaining: "Fixture Series").waitForExistence(timeout: 30))
        waitUntil(20, "films should leave when series are chosen") { !self.button(labelContaining: "Aether Fixture One").exists }

        installAddonByTyping(AetherUITestCase.extraManifestURL, expectingRow: AetherUITestCase.extraAddonRowID)
        openTab("Scopri")
        let tv = element("discover.type.tv")
        let sports = element("discover.type.sports")
        XCTAssertTrue(tv.waitForExistence(timeout: 30), "live TV should appear by itself")
        XCTAssertTrue(sports.waitForExistence(timeout: 10), "sports should appear by itself")
        XCTAssertLessThan(movie.frame.minX, series.frame.minX)
        XCTAssertLessThan(series.frame.minX, tv.frame.minX)
        XCTAssertLessThan(tv.frame.minX, sports.frame.minX, "known types follow the canonical order")

        tv.tap()
        XCTAssertTrue(button(labelContaining: "Fixture News Live").waitForExistence(timeout: 30))
        sports.tap()
        XCTAssertTrue(button(labelContaining: "Fixture Derby Highlights").waitForExistence(timeout: 30))

        uninstallAddon(rowID: AetherUITestCase.extraAddonRowID)
        openTab("Scopri")
        waitUntil(30, "the chips of the removed addon should disappear") {
            !self.element("discover.type.tv").exists && !self.element("discover.type.sports").exists
        }
        XCTAssertTrue(element("discover.type.movie").exists)
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30)
                      || button(labelContaining: "Fixture Series").waitForExistence(timeout: 5),
                      "the selection falls back to a type that still exists")
    }

    // The genre is requested from the addon (its manifest declares it); the year is filtered by Aether and counted.
    func testGenreAndYearFiltersInDiscover() {
        installAddonByTyping(AetherUITestCase.extraManifestURL, expectingRow: AetherUITestCase.extraAddonRowID)
        openTab("Scopri")
        let sports = element("discover.type.sports")
        XCTAssertTrue(sports.waitForExistence(timeout: 30))
        sports.tap()
        XCTAssertTrue(button(labelContaining: "Fixture Derby Highlights").waitForExistence(timeout: 30))
        XCTAssertTrue(button(labelContaining: "Fixture Open Final").exists)

        chooseFilter("discover.genreMenu", "Tennis")
        waitUntil(20, "the football title should leave when the genre is Tennis") {
            !self.button(labelContaining: "Fixture Derby Highlights").exists
        }
        XCTAssertTrue(button(labelContaining: "Fixture Open Final").exists)
        XCTAssertEqual(filterMenuValue("discover.genreMenu"), "Tennis")
        XCTAssertTrue(Fixture.requestedPaths().contains { $0.contains("/extra/catalog/sports/extra-sports/genre=Tennis") },
                      "the genre is declared by the manifest, so it must be requested from the addon")

        element("discover.type.tv").tap()
        XCTAssertTrue(button(labelContaining: "Fixture News Live").waitForExistence(timeout: 30))
        XCTAssertTrue(button(labelContaining: "Fixture Night Channel").exists)
        XCTAssertFalse(element("discover.hidden").exists)
        chooseFilter("discover.yearMenu", "2010–2019")
        waitUntil(20, "only the 2018 channel should remain") { !self.button(labelContaining: "Fixture News Live").exists }
        XCTAssertTrue(button(labelContaining: "Fixture Kids Channel").exists)
        XCTAssertFalse(button(labelContaining: "Fixture Night Channel").exists)
        let hidden = element("discover.hidden")
        XCTAssertTrue(hidden.waitForExistence(timeout: 10), "Discover must say how many titles the year filter hid")
        XCTAssertTrue(hidden.label.contains("1 risultato senza anno nascosto"), "unexpected message: \(hidden.label)")
    }

    // Hiding a type in Settings removes its chip at once; showing it brings it back.
    func testHidingATypeInSettingsRemovesItsChip() {
        openTab("Scopri")
        XCTAssertTrue(element("discover.type.series").waitForExistence(timeout: 30))
        XCTAssertTrue(element("discover.type.movie").exists)

        openDiscoverSettingsViaSettings()
        let seriesSwitch = settingsSwitch("settings.discover.type.series")
        XCTAssertTrue(isOn(seriesSwitch), "every type starts visible")
        seriesSwitch.tap()
        waitUntil(10, "the switch should turn off") { !self.isOn(self.settingsSwitch("settings.discover.type.series")) }

        openTab("Scopri")
        XCTAssertTrue(element("discover.type.movie").waitForExistence(timeout: 20))
        waitUntil(20, "the hidden type must not be a chip any more") { !self.element("discover.type.series").exists }

        openTab("Altro")
        let again = settingsSwitch("settings.discover.type.series")
        XCTAssertFalse(isOn(again), "the setting is still off when the page is reopened")
        again.tap()
        openTab("Scopri")
        XCTAssertTrue(element("discover.type.series").waitForExistence(timeout: 20), "showing the type again restores its chip")
    }

    // Hiding everything is an honest empty state with a way back, not an empty screen.
    func testHidingEveryTypeShowsAnEmptyStateWithAWayBack() {
        openTab("Scopri")
        XCTAssertTrue(element("discover.type.movie").waitForExistence(timeout: 30))
        let customize = element("discover.customize")
        XCTAssertTrue(customize.waitForExistence(timeout: 10), "Discover offers a way to choose its categories")
        customize.tap()

        let movieSwitch = settingsSwitch("settings.discover.type.movie")
        let seriesSwitch = settingsSwitch("settings.discover.type.series")
        movieSwitch.tap()
        seriesSwitch.tap()
        waitUntil(10, "both switches should be off") {
            !self.isOn(self.settingsSwitch("settings.discover.type.movie"))
                && !self.isOn(self.settingsSwitch("settings.discover.type.series"))
        }
        element("settings.discover.close").tap()

        XCTAssertTrue(element("discover.allHidden").waitForExistence(timeout: 20), "hiding every type must say so")
        XCTAssertFalse(element("discover.type.movie").exists)
        XCTAssertFalse(element("discover.grid").exists, "there is nothing to list")

        let choose = button(labelContaining: "Scegli le categorie")
        XCTAssertTrue(choose.waitForExistence(timeout: 10), "the empty state offers a button to the settings")
        choose.tap()
        settingsSwitch("settings.discover.type.movie").tap()
        waitUntil(10, "the movie switch should turn on") { self.isOn(self.settingsSwitch("settings.discover.type.movie")) }
        element("settings.discover.close").tap()

        XCTAssertTrue(element("discover.type.movie").waitForExistence(timeout: 20), "the chip is back")
        XCTAssertFalse(element("discover.allHidden").exists)
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
        XCTAssertFalse(element("discover.type.series").exists, "series stay hidden")
    }

    // The order chosen in Settings is applied to the chips, drives the first selection, and survives a relaunch.
    func testReorderingPersistsAcrossRelaunch() {
        openTab("Scopri")
        let movie = element("discover.type.movie")
        let series = element("discover.type.series")
        XCTAssertTrue(movie.waitForExistence(timeout: 30))
        XCTAssertLessThan(movie.frame.minX, series.frame.minX, "the default order puts films first")

        openDiscoverSettingsViaSettings()
        let reorder = element("settings.discover.reorder")
        XCTAssertTrue(reorder.waitForExistence(timeout: 10), "with two categories there is something to reorder")
        reorder.tap()
        dragSeriesAboveMovies()
        reorder.tap()

        let movieRow = element("settings.discover.type.movie")
        let seriesRow = element("settings.discover.type.series")
        XCTAssertLessThan(seriesRow.frame.minY, movieRow.frame.minY, "the list shows the new order")

        openTab("Scopri")
        XCTAssertTrue(element("discover.type.series").waitForExistence(timeout: 20))
        waitUntil(20, "the chips should follow the new order") {
            self.element("discover.type.series").frame.minX < self.element("discover.type.movie").frame.minX
        }

        app.terminate()
        launch(reset: false, settings: nil)
        openTab("Scopri")
        XCTAssertTrue(element("discover.type.series").waitForExistence(timeout: 30))
        XCTAssertTrue(element("discover.type.movie").exists)
        XCTAssertLessThan(element("discover.type.series").frame.minX, element("discover.type.movie").frame.minX,
                          "the order must survive a relaunch")
        XCTAssertTrue(button(labelContaining: "Fixture Series").waitForExistence(timeout: 30),
                      "the first chip is the one selected after a relaunch")
    }

    func testNewScreensPassTheAccessibilityAudit() throws {
        openTab("Scopri")
        XCTAssertTrue(element("discover.type.movie").waitForExistence(timeout: 30))
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 30))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        openDiscoverSettingsViaSettings()
        XCTAssertTrue(element("settings.discover.type.movie").waitForExistence(timeout: 15))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
    }

    // MARK: Dragging

    /// Drags the Serie TV row above the Film row while the list is in reorder mode. The handle is found by its system
    /// label; if that fails, the trailing edge of the first two rows of the list is used. Retried, because a drag can be
    /// dropped by a busy CI machine.
    private func dragSeriesAboveMovies() {
        let seriesRow = element("settings.discover.type.series")
        let movieRow = element("settings.discover.type.movie")
        XCTAssertTrue(seriesRow.waitForExistence(timeout: 10))
        XCTAssertTrue(movieRow.waitForExistence(timeout: 10))
        let handlePredicate = NSPredicate(format: "label BEGINSWITH[c] 'Reorder' OR label BEGINSWITH[c] 'Riordina' OR label BEGINSWITH[c] 'Sposta'")

        for attempt in 0..<3 {
            if seriesRow.frame.minY < movieRow.frame.minY { return }
            let handles = app.buttons.matching(handlePredicate).allElementsBoundByIndex
                .sorted { $0.frame.minY < $1.frame.minY }
            let start: XCUICoordinate
            let end: XCUICoordinate
            if handles.count >= 2 {
                start = handles[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                end = handles[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.2))
            } else {
                // The only cells on this page are the two category rows (the first is Film, the second Serie TV).
                let cells = app.cells
                start = cells.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5))
                end = cells.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.2))
            }
            if attempt == 0 {
                start.press(forDuration: 0.8, thenDragTo: end)
            } else {
                start.press(forDuration: 0.8, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
            }
            let settle = Date().addingTimeInterval(1.5)
            while Date() < settle && !(seriesRow.frame.minY < movieRow.frame.minY) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
        XCTAssertLessThan(seriesRow.frame.minY, movieRow.frame.minY,
                          "the drag did not move «Serie TV» above «Film» after three attempts")
    }
}
