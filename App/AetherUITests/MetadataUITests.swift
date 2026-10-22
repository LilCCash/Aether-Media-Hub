import XCTest

/// TMDB / TheTVDB keys and the enrichment they enable, end to end, against the fixture server's stand-ins for the two
/// services (Tools/FixtureAddonServer/metadata.js). Nothing here talks to the real services.
final class MetadataUITests: AetherUITestCase {
    private let tmdbOverview = "Trama fornita dal servizio TMDB di prova."

    private var metadataArguments: [String] { ["-AETHER_UITEST_METADATA_BASE", Fixture.base] }

    private func openServices() {
        openMoreRoot()
        element("more.settings").tap()
        let services = element("settings.Servizi")
        XCTAssertTrue(services.waitForExistence(timeout: 10), "the Servizi page is not listed in the settings")
        services.tap()
    }

    private func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        if !field.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(identifier) missing")
        field.tap()
        field.typeText(text)
    }

    private func status(of service: String) -> String {
        let label = element("service.\(service).status")
        return label.waitForExistence(timeout: 20) ? label.label : ""
    }

    private func openSparseMovie() {
        openTab("Cerca")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Sparse")
        let result = button(labelContaining: "Sparse Fixture Movie")
        XCTAssertTrue(result.waitForExistence(timeout: 30), "search did not return the bare fixture movie")
        result.tap()
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 20), "detail screen did not open")
    }

    func testWithoutAKeyTheBareTitleStaysBareAndNothingIsRequested() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openSparseMovie()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(element(labelContaining: tmdbOverview).exists, "no key: nothing may be added to the addon's meta")
        XCTAssertFalse(Fixture.requestedPaths().contains { $0.hasPrefix("/tmdb/") || $0.hasPrefix("/tvdb/") },
                       "no key: the services must not be contacted at all")
    }

    func testARefusedTMDBKeyIsReportedAndNotKept() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openServices()
        type("not-a-valid-key", into: "service.tmdb.key")
        element("service.tmdb.save").tap()
        let message = status(of: "tmdb")
        XCTAssertTrue(message.contains("rifiutato"), "the refusal should be explained, got: \(message)")
        XCTAssertTrue(message.contains("non è stata salvata"), "a refused key must not be kept, got: \(message)")
        XCTAssertFalse(element("service.tmdb.saved").exists)
        XCTAssertTrue(element("service.tmdb.key").exists, "the field is offered again")
    }

    func testAcceptedTMDBKeyFillsTheBareTitleAndShowsTheAttribution() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openServices()
        type("fixture-tmdb-key", into: "service.tmdb.key")
        element("service.tmdb.save").tap()
        XCTAssertTrue(status(of: "tmdb").contains("accetta"), "the key should be accepted")
        XCTAssertTrue(element("service.tmdb.saved").waitForExistence(timeout: 10))

        openSparseMovie()
        XCTAssertTrue(element(labelContaining: tmdbOverview).waitForExistence(timeout: 30),
                      "the overview from the service should appear on the bare title")
        XCTAssertTrue(element(labelContaining: "not endorsed or certified by TMDB").waitForExistence(timeout: 10),
                      "TMDB data must come with TMDB's attribution")
    }

    func testTheTitlePageShowsTheTMDBSectionsWhenAKeyIsStored() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openServices()
        type("fixture-tmdb-key", into: "service.tmdb.key")
        element("service.tmdb.save").tap()
        XCTAssertTrue(element("service.tmdb.saved").waitForExistence(timeout: 20))

        openSparseMovie()
        scrollTo("detail.cast")
        XCTAssertTrue(element(labelContaining: "Attrice TMDB Uno, La pilota").exists, "an actor is read with the character")
        scrollTo("detail.trailer.1")
        XCTAssertTrue(element("detail.trailer.0").exists, "both trailers are listed")
        scrollTo("detail.companies")
        XCTAssertTrue(element(labelContaining: "Studio di Prova").exists)
        scrollTo("detail.financials")
        XCTAssertTrue(element(labelContaining: "12.000.000 $").exists, "the budget of a film")
        XCTAssertTrue(element(labelContaining: "34.500.000 $").exists, "the revenue of a film")
        scrollTo("detail.facts")
        XCTAssertTrue(element(labelContaining: "Uscito").exists, "the status row")
        scrollTo("detail.similar")
        XCTAssertTrue(element("detail.similar.0").exists)
        scrollTo("detail.tmdbCredit")
        XCTAssertTrue(element(labelContaining: "Offerto da TMDB").exists)
    }

    func testTheTitlePageOffersTheKeyWhenNoneIsStored() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openSparseMovie()
        scrollTo("detail.tmdbHint")
        XCTAssertFalse(element("detail.cast").exists)
        XCTAssertFalse(element("detail.financials").exists)
    }

    /// Scrolls the title page until the element is on screen (at most a few swipes).
    private func scrollTo(_ identifier: String) {
        let target = element(identifier)
        var swipes = 0
        while !target.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(identifier) never appeared on the title page")
    }

    func testRemovingTheKeyStopsTheEnrichment() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openServices()
        type("fixture-tmdb-key", into: "service.tmdb.key")
        element("service.tmdb.save").tap()
        XCTAssertTrue(element("service.tmdb.saved").waitForExistence(timeout: 20))
        element("service.tmdb.remove").tap()
        XCTAssertTrue(element("service.tmdb.key").waitForExistence(timeout: 10), "after removal the key field is back")

        Fixture.control("/__control/reset")
        openSparseMovie()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(element(labelContaining: tmdbOverview).exists)
        XCTAssertFalse(Fixture.requestedPaths().contains { $0.hasPrefix("/tmdb/") }, "a removed key must not be used again")
    }

    func testTVDBKeyIsCheckedWithItsLogin() {
        launchWithFixtureAddon(extraArguments: metadataArguments)
        openServices()
        type("wrong-key", into: "service.tvdb.key")
        element("service.tvdb.save").tap()
        XCTAssertTrue(status(of: "tvdb").contains("rifiutato"), "TheTVDB's InvalidAPIKey answer should be reported")
        XCTAssertFalse(element("service.tvdb.saved").exists)

        type("fixture-tvdb-key", into: "service.tvdb.key")
        element("service.tvdb.save").tap()
        XCTAssertTrue(element("service.tvdb.saved").waitForExistence(timeout: 20), "the accepted key is kept")
        XCTAssertTrue(status(of: "tvdb").contains("accetta"))
    }
}
