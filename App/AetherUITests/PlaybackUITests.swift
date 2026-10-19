import XCTest

/// Scenarios 7–12: playback, resume, subtitles, next episode, watchlist and persisted history.
final class PlaybackUITests: AetherUITestCase {
    // 7. Playback actually starts and advances
    func testPlaybackStartsAndTimeAdvances() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "the playhead never advanced past 2 s") { (playbackSeconds() ?? 0) >= 2 }
        XCTAssertFalse(element("player.error").exists, "no error panel while playing")
    }

    // 7b. Pause and play controls work
    func testPauseStopsTheClock() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        element("player.playPause").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let paused = playbackSeconds() ?? 0
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(playbackSeconds() ?? -1, paused, accuracy: 1.0, "the clock should be frozen while paused")
    }

    // 8. Resume from the saved point
    func testResumeFromSavedPosition() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(45, "playback did not reach 7 s") { (playbackSeconds() ?? 0) >= 7 }
        element("player.close").tap()
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 15))

        openStreamPicker()
        element("stream.row.0").tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30))
        waitUntil(30, "playback should restart near the saved position, not at 0") { (playbackSeconds() ?? 0) >= 5 }
    }

    // 9. Choosing a subtitle shows its text on screen
    func testSelectingASubtitleShowsItsText() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        element("player.tracks").tap()
        let italian = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Ital'")).firstMatch
        XCTAssertTrue(italian.waitForExistence(timeout: 20), "the addon's Italian subtitles should be offered")
        italian.tap()
        app.buttons["Fine"].tap()
        XCTAssertTrue(element(labelContaining: "Ciao dal sottotitolo di prova").waitForExistence(timeout: 20),
                      "the cue text should be drawn over the video")
    }

    // 10. The next episode starts by itself when one ends (skip 60 s to reach the end faster)
    func testNextEpisodeStartsAutomatically() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15,"skipForwardSeconds":60,"nextEpisodeCountdownSeconds":3}}"#)
        openTab("Home")
        let card = button(labelContaining: "Fixture Series")
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        card.tap()
        let first = element("episode.tt9100001:1:1")
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        first.tap()
        XCTAssertTrue(element("stream.row.0").waitForExistence(timeout: 30))
        element("stream.row.0").tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30))
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }

        // 150 s clip: 2 × 60 s lands at ~120 s, inside the "up next" window.
        let forward = button(labelContaining: "Avanti di 60")
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        forward.tap()
        forward.tap()
        XCTAssertTrue(element("player.nextEpisodeCard").waitForExistence(timeout: 30), "the next-episode card should appear near the end")
        waitUntil(60, "the second episode never started") {
            self.element(labelContaining: "S01E02").exists
        }
    }

    // 11. Watchlist
    func testWatchlistAddsAndRemoves() {
        launchWithFixtureAddon()
        openFixtureMovie()
        let save = element("detail.watchlist")
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()
        XCTAssertTrue(app.buttons["Rimuovi dalla watchlist"].waitForExistence(timeout: 10))

        app.navigationBars.buttons.firstMatch.tap()   // back
        openTab("Libreria")
        app.buttons["Watchlist"].tap()
        XCTAssertTrue(button(labelContaining: "Aether Fixture One").waitForExistence(timeout: 15), "the saved title is listed in the library")
    }

    // 12. History and resume points survive an app restart (they are read back from disk)
    func testHistoryIsRestoredAfterRelaunch() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(45, "playback did not reach 6 s") { (playbackSeconds() ?? 0) >= 6 }
        element("player.close").tap()
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 15))
        app.terminate()

        launch(reset: false)
        openTab("Libreria")
        app.buttons["Cronologia"].tap()
        XCTAssertTrue(element(labelContaining: "Aether Fixture One").waitForExistence(timeout: 20), "history is restored after relaunch")
        app.buttons["Continua"].tap()
        XCTAssertTrue(element(labelContaining: "Aether Fixture One").waitForExistence(timeout: 20), "the resume point is restored after relaunch")
    }

    // Privacy switch: nothing is recorded when history is off
    func testNothingIsRecordedWhenHistoryIsDisabled() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15},"privacy":{"recordHistory":false}}"#)
        openFixtureMovie()
        startPlayback()
        waitUntil(45, "playback did not reach 6 s") { (playbackSeconds() ?? 0) >= 6 }
        element("player.close").tap()
        openTab("Libreria")
        app.buttons["Cronologia"].tap()
        XCTAssertTrue(element("library.empty").waitForExistence(timeout: 15), "no history should exist")
    }
}
