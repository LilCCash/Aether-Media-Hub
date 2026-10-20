import XCTest

/// TMDB / TheTVDB keys and the enrichment they enable, end to end, against the fixture server's stand-ins for the two
/// services (Tools/FixtureAddonServer/metadata.js). Nothing here talks to the real services.
final class MetadataUITests: AetherUITestCase {
    private let tmdbOverview = "Trama fornita dal servizio TMDB di prova."

    private var metadataArguments: [String] { ["-AETHER_UITEST_METADATA_BASE", Fixture.base] }

    private func openServices() {
        openTab("Altro")
        let settings = element("more.settings")
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Impostazioni missing")
        settings.tap()
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
