import XCTest

/// Downloads end to end: queue a direct MP4, wait for completion, then play it with the server's media offline.
/// Needs the CI machine's LAN address (the app refuses to download from loopback), so it is skipped elsewhere.
final class DownloadUITests: AetherUITestCase {
    func testDownloadThenPlayOffline() throws {
        guard let manifest = Fixture.lanManifestURL else {
            throw XCTSkip("AETHER_FIXTURE_LAN_HOST is not set: no LAN address available to download from")
        }
        launchWithFixtureAddon(
            settings: #"{"playback":{"controlsAutoHideSeconds":15},"privacy":{"allowLocalNetwork":true}}"#,
            manifestURL: manifest)
        openFixtureMovie()
        openStreamPicker()

        element("stream.row.0").swipeLeft()
        let download = app.buttons["Scarica"]
        XCTAssertTrue(download.waitForExistence(timeout: 10), "the swipe action 'Scarica' should be offered")
        download.tap()
        XCTAssertTrue(element(labelContaining: "Download avviato").waitForExistence(timeout: 15), "the app confirms the download started")
        app.buttons["Chiudi"].tap()

        openTab("Libreria")
        app.buttons["Download"].tap()
        let playOffline = app.buttons["Riproduci offline"]
        XCTAssertTrue(playOffline.waitForExistence(timeout: 90), "the download should complete")

        // From here on the server refuses media: only the local copy can play.
        XCTAssertTrue(Fixture.control("/__control/media?on=0"))
        playOffline.tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30))
        waitUntil(40, "offline playback never advanced") { (playbackSeconds() ?? 0) >= 2 }
        XCTAssertFalse(element("player.error").exists)
    }

    func testLoopbackSourcesAreRefusedWithAnExplanation() {
        launchWithFixtureAddon()
        openFixtureMovie()
        openStreamPicker()
        element("stream.row.0").swipeLeft()
        let download = app.buttons["Scarica"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "a refusal is explained, not silent")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'questo dispositivo'")).firstMatch.exists)
        alert.buttons["OK"].tap()
    }
}
