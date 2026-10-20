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

    /// Progress below this many seconds is deliberately not recorded (LibraryPolicy.minimumRecordedSeconds = 10).
    private let recordedThreshold: Double = 13

    // 8. Resume from the saved point
    func testResumeFromSavedPosition() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(60, "playback did not reach the recording threshold") { (playbackSeconds() ?? 0) >= recordedThreshold }
        closePlayer()
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 15))

        openStreamPicker()
        element("stream.row.0").tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30))
        // Playing from 0 could not reach 10 s this quickly: only a real resume gets here.
        waitUntil(8, "playback should restart near the saved position, not at 0") { (playbackSeconds() ?? 0) >= 10 }
    }

    // MARK: Subtitle helpers

    /// Both cues of each fixture subtitle: the first one is on screen until 30 s, the second from 30.5 s to 120 s.
    private let italianCues = ["Ciao dal sottotitolo di prova", "Secondo sottotitolo italiano"]
    private let englishCues = ["Hello from the test subtitle", "Second English subtitle"]

    private func cueIsShown(_ texts: [String]) -> Bool {
        for text in texts where element(labelContaining: text).exists { return true }
        return false
    }

    private func waitForCue(_ texts: [String], timeout: TimeInterval = 20, _ message: String) {
        waitUntil(timeout, message) { self.cueIsShown(texts) }
    }

    private func waitForNoCue(_ texts: [String], timeout: TimeInterval = 10, _ message: String) {
        waitUntil(timeout, message) { !self.cueIsShown(texts) }
    }

    /// Opens "Audio e sottotitoli". The controls hide themselves, so a tap on the picture brings them back first.
    private func openTracksSheet() {
        let tracks = element("player.tracks")
        if !tracks.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = tracks.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(tracks.exists, "the tracks button is not reachable")
        tracks.tap()
        XCTAssertTrue(element("subtitle.off").waitForExistence(timeout: 20), "the tracks sheet did not open")
    }

    private func closeTracksSheet() {
        app.buttons["Fine"].tap()
    }

    /// Picks the first subtitle of a language in the open sheet. The language chip narrows the list to that language first, so
    /// the row is on screen whatever the size of the sheet.
    private func chooseSubtitle(_ code: String) {
        let chip = element("subtitle.filter.\(code)")
        if chip.waitForExistence(timeout: 10) { chip.tap() }
        let row = element("subtitle.option.\(code).0")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no \(code) subtitle is offered")
        row.tap()
    }

    /// Opens the first episode of "Fixture Series" and starts it.
    private func playFirstEpisodeOfTheSeries() {
        openTab("Home")
        let card = button(labelContaining: "Fixture Series")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the series is not on Home")
        card.tap()
        let first = element("episode.tt9100001:1:1")
        XCTAssertTrue(first.waitForExistence(timeout: 30))
        first.tap()
        XCTAssertTrue(element("stream.row.0").waitForExistence(timeout: 30))
        element("stream.row.0").tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30), "the player did not open")
        waitUntil(40, "playback did not start") { (self.playbackSeconds() ?? 0) >= 1 }
    }

    /// Moves to the next episode with the player's own button and waits until the second one is on.
    private func goToTheNextEpisode() {
        let next = element("player.next")
        if !next.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(next.waitForExistence(timeout: 20), "the player offers no next episode")
        next.tap()
        waitUntil(60, "the second episode never started") { self.element(labelContaining: "S01E02").exists }
    }

    /// OpenSubtitles hash of the media file, computed here from the bytes the fixture serves and independently of the app:
    /// size + the first and the last 64 KiB read as little-endian 64 bit words.
    private func openSubtitlesHashOfTheSample() -> (hash: String, size: Int64)? {
        guard let url = URL(string: Fixture.base + "/media/sample.mp4") else { return nil }
        func fetch(_ range: String) -> (data: Data, total: Int64)? {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let done = DispatchSemaphore(value: 0)
            var result: (data: Data, total: Int64)?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data = data, let http = response as? HTTPURLResponse, http.statusCode == 206,
                   let header = http.value(forHTTPHeaderField: "Content-Range"),
                   let totalText = header.split(separator: "/").last, let total = Int64(totalText) {
                    result = (data, total)
                }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 10)
            return result
        }
        guard let head = fetch("bytes=0-65535"), head.data.count == 65536, head.total >= 131072 else { return nil }
        guard let tail = fetch("bytes=\(head.total - 65536)-\(head.total - 1)"), tail.data.count == 65536 else { return nil }
        var sum = UInt64(head.total)
        for block in [head.data, tail.data] {
            block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset + 8 <= raw.count {
                    sum = sum &+ UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                    offset += 8
                }
            }
        }
        return (String(format: "%016llx", sum), head.total)
    }

    // 9. Choosing a subtitle shows its text on screen
    func testSelectingASubtitleShowsItsText() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        openTracksSheet()
        // The language chips are buttons too, so the Italian subtitle is picked by the identifier of its row.
        chooseSubtitle("it")
        closeTracksSheet()
        waitForCue(italianCues, "the cue text should be drawn over the video")
    }

    // 9b. Subtitles are grouped by language and each language shows its own text; nothing is on until the viewer asks
    func testEachLanguageShowsItsOwnTextAndSubtitlesCanBeTurnedOff() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        openTracksSheet()

        // Both languages are offered, as chips, once the list is there. The settings ask for none, so nothing is switched on.
        XCTAssertTrue(element("subtitle.filter.all").waitForExistence(timeout: 20), "there should be a chip for all languages")
        XCTAssertTrue(element("subtitle.filter.it").exists)
        XCTAssertTrue(element("subtitle.filter.en").exists)
        XCTAssertTrue(element("subtitle.off").isSelected, "subtitles are off by default")
        XCTAssertTrue(element("subtitle.filter.all").isSelected)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(cueIsShown(italianCues + englishCues), "no subtitle may be drawn when none was asked for")

        // Each row names its language and the addon it comes from.
        element("subtitle.filter.en").tap()
        let english = element("subtitle.option.en.0")
        XCTAssertTrue(english.waitForExistence(timeout: 20))
        XCTAssertTrue(english.label.contains("Inglese"), english.label)
        XCTAssertTrue(english.label.contains("Aether Fixture"), english.label)
        english.tap()
        XCTAssertTrue(english.isSelected, "the chosen row is marked")
        XCTAssertFalse(element("subtitle.off").isSelected)
        closeTracksSheet()
        waitForCue(englishCues, "the English text should be drawn")
        XCTAssertFalse(cueIsShown(italianCues))

        openTracksSheet()
        chooseSubtitle("it")
        closeTracksSheet()
        waitForCue(italianCues, "the Italian text should replace the English one")
        waitForNoCue(englishCues, "the English text should be gone")

        openTracksSheet()
        element("subtitle.off").tap()
        closeTracksSheet()
        waitForNoCue(italianCues + englishCues, "turning subtitles off removes the text")
    }

    // 9c. The language chips narrow the list
    func testLanguageChipsNarrowTheSubtitleList() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        openTracksSheet()

        let all = element("subtitle.filter.all")
        let italianChip = element("subtitle.filter.it")
        let englishChip = element("subtitle.filter.en")
        XCTAssertTrue(all.waitForExistence(timeout: 20))
        XCTAssertTrue(all.isSelected)

        italianChip.tap()
        XCTAssertTrue(element("subtitle.option.it.0").waitForExistence(timeout: 10))
        waitUntil(10, "the English row should leave the list") { !self.element("subtitle.option.en.0").exists }
        XCTAssertTrue(italianChip.isSelected)
        XCTAssertFalse(all.isSelected)

        englishChip.tap()
        XCTAssertTrue(element("subtitle.option.en.0").waitForExistence(timeout: 10))
        waitUntil(10, "the Italian row should leave the list") { !self.element("subtitle.option.it.0").exists }

        all.tap()
        XCTAssertTrue(all.isSelected)
        XCTAssertFalse(englishChip.isSelected)
    }

    // 9d. The addons are asked with the file name at once, and again with the hash computed on this device
    func testSubtitleRequestsCarryTheFileNameAndTheHashComputedOnThisDevice() throws {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }

        waitUntil(30, "no subtitle request carried the file name of the stream") {
            Fixture.requestedPaths().contains(where: { $0.hasPrefix("/subtitles/movie/tt9000001/") && $0.contains("filename=sample.mp4") })
        }
        waitUntil(40, "the addon was never asked again with the hash computed on this device") {
            Fixture.requestedPaths().contains(where: { $0.contains("/subtitles/") && $0.contains("videoHash=") && $0.contains("videoSize=") })
        }

        let hashed = try XCTUnwrap(Fixture.requestedPaths().first(where: { $0.contains("videoHash=") }))
        let expected = try XCTUnwrap(openSubtitlesHashOfTheSample(), "the test could not read the sample video from the fixture server")
        XCTAssertTrue(hashed.contains("videoHash=\(expected.hash)"), "the app's hash differs from the OpenSubtitles hash of the file: \(hashed) vs \(expected.hash)")
        XCTAssertTrue(hashed.contains("videoSize=\(expected.size)"), "the app's size differs from the size of the file: \(hashed) vs \(expected.size)")
        XCTAssertTrue(hashed.contains("filename=sample.mp4"), hashed)
        // The hash never held playback back.
        XCTAssertFalse(element("player.error").exists)
    }

    // 9e. A title the addon has no subtitles for says so
    func testATitleWithoutSubtitlesSaysSoHonestly() {
        launchWithFixtureAddon()
        openTitleViaSearch("Silent", expecting: "Silent Feature")
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        openTracksSheet()

        let empty = element("subtitle.empty.none")
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "the sheet should explain that nothing was found")
        XCTAssertTrue(empty.label.contains("Nessun sottotitolo trovato per questo titolo"), empty.label)
        XCTAssertFalse(element("subtitle.empty.noAddons").exists, "an addon for subtitles is installed")
        XCTAssertFalse(element("subtitle.option.it.0").exists)
        XCTAssertFalse(element("subtitle.filter.all").exists, "there is no language to filter by")
        XCTAssertTrue(element("subtitle.off").isSelected)
        XCTAssertFalse(element("subtitle.loading").exists, "the search is over")
    }

    // 9f. Without an addon for subtitles the sheet says that, and nobody is asked
    func testWithoutASubtitlesAddonTheSheetSaysItIsNotInstalled() {
        launchWithFixtureAddon(manifestURL: Fixture.base + "/nosubs/manifest.json")
        openTitleViaSearch("Silent", expecting: "Silent Feature")
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        openTracksSheet()

        let empty = element("subtitle.empty.noAddons")
        XCTAssertTrue(empty.waitForExistence(timeout: 30), "the sheet should say that no addon provides subtitles")
        XCTAssertTrue(empty.label.contains("Nessun addon di sottotitoli installato"), empty.label)
        XCTAssertFalse(element("subtitle.empty.none").exists)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(Fixture.requestedPaths().contains(where: { $0.hasPrefix("/subtitles/") }),
                       "no addon declares subtitles, so none may be asked")
    }

    // 9g. A subtitle that cannot be downloaded or read: message, selection cleared, playback unaffected
    func testBrokenSubtitleFilesShowAnErrorAndPlaybackKeepsGoing() {
        launchWithFixtureAddon()
        openTitleViaSearch("Broken", expecting: "Broken Captions")
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        openTracksSheet()

        // The Italian file answers 404.
        chooseSubtitle("it")
        let error = element("subtitle.error")
        XCTAssertTrue(error.waitForExistence(timeout: 20), "the failure should be reported in the sheet")
        XCTAssertTrue(error.label.contains("Sottotitoli non scaricabili"), error.label)
        XCTAssertTrue(error.label.contains("404"), error.label)
        XCTAssertFalse(element("subtitle.option.it.0").isSelected, "a subtitle that failed must not look selected")
        XCTAssertTrue(element("subtitle.off").isSelected)

        // The English file downloads but is not a subtitle.
        element("subtitle.filter.en").tap()
        let english = element("subtitle.option.en.0")
        XCTAssertTrue(english.waitForExistence(timeout: 10))
        english.tap()
        waitUntil(20, "the message for the unusable file never appeared") {
            self.element("subtitle.error").exists && self.element("subtitle.error").label.contains("Formato di sottotitoli non riconosciuto")
        }
        XCTAssertFalse(english.isSelected)
        XCTAssertTrue(element("subtitle.off").isSelected)

        // Playback was never affected: the clock keeps running and no cue was drawn.
        closeTracksSheet()
        let before = playbackSeconds() ?? 0
        waitUntil(30, "playback stopped after the subtitle failed") { (self.playbackSeconds() ?? 0) > before + 2 }
        XCTAssertFalse(element("player.error").exists)
        XCTAssertFalse(cueIsShown(italianCues + englishCues))
    }

    // 9h. The preferred language is switched on by itself, the secondary one when the first is missing
    func testThePreferredLanguageIsSwitchedOnWithoutOpeningTheSheet() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15,"preferredSubtitleLanguage":"it"}}"#)
        openFixtureMovie()
        startPlayback()
        waitForCue(italianCues, timeout: 40, "the preferred language should be on without any interaction")
        XCTAssertFalse(cueIsShown(englishCues))
        openTracksSheet()
        XCTAssertFalse(element("subtitle.off").isSelected)
        // The sheet lists the preferred language first (alphabetically English would come before Italian).
        let italianChip = element("subtitle.filter.it")
        let englishChip = element("subtitle.filter.en")
        XCTAssertTrue(italianChip.waitForExistence(timeout: 20))
        XCTAssertTrue(englishChip.exists)
        XCTAssertLessThan(italianChip.frame.minX, englishChip.frame.minX, "the preferred language must come first")
    }

    func testTheSecondaryLanguageIsUsedWhenThePrimaryOneIsNotAvailable() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15,"preferredSubtitleLanguage":"fr","secondarySubtitleLanguage":"en"}}"#)
        openFixtureMovie()
        startPlayback()
        waitForCue(englishCues, timeout: 40, "French is not offered: English should be on")
        XCTAssertFalse(cueIsShown(italianCues))
    }

    // 9i. What the viewer picks by hand is kept for the next episode, instead of the settings
    func testASubtitleLanguagePickedByHandIsKeptForTheNextEpisode() {
        launchWithFixtureAddon()   // the settings ask for no subtitles at all
        playFirstEpisodeOfTheSeries()
        openTracksSheet()
        chooseSubtitle("en")
        closeTracksSheet()
        waitForCue(englishCues, "the English text should be drawn")

        goToTheNextEpisode()
        waitUntil(30, "the subtitles of the second episode were never requested") {
            Fixture.requestedPaths().contains(where: { $0.hasPrefix("/subtitles/series/") && $0.contains("tt9100001:1:2") })
        }
        waitForCue(englishCues, timeout: 40, "English should come back in the next episode, chosen by the earlier choice and not by the settings")
        openTracksSheet()
        XCTAssertFalse(element("subtitle.off").isSelected)
    }

    func testTurningSubtitlesOffByHandIsKeptForTheNextEpisode() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15,"preferredSubtitleLanguage":"it"}}"#)
        playFirstEpisodeOfTheSeries()
        waitForCue(italianCues, timeout: 40, "the preferred language should be on by itself")
        openTracksSheet()
        element("subtitle.off").tap()
        closeTracksSheet()
        waitForNoCue(italianCues, "turning subtitles off removes the text")

        goToTheNextEpisode()
        // The new episode has its subtitles (the list is there) and the settings say Italian, but the viewer said no.
        waitUntil(30, "the subtitles of the second episode were never requested") {
            Fixture.requestedPaths().contains(where: { $0.hasPrefix("/subtitles/series/") && $0.contains("tt9100001:1:2") })
        }
        openTracksSheet()
        XCTAssertTrue(element("subtitle.filter.it").waitForExistence(timeout: 20), "the second episode has Italian subtitles")
        XCTAssertTrue(element("subtitle.off").isSelected, "the viewer's choice must outlive the episode")
        closeTracksSheet()
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertFalse(cueIsShown(italianCues + englishCues), "no subtitle may come back by itself")
    }

    // 9j. The delay moves the text; the clock is stopped so the position is the same before and after
    func testTheSubtitleDelayMovesTheCueOutOfAndBackIntoView() {
        launchWithFixtureAddon()
        openFixtureMovie()
        startPlayback()
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
        // Pause first: the position must not run on while the sheet is used (the cue is due from 0.5 s to 30 s).
        element("player.playPause").tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let pausedAt = playbackSeconds() ?? 0
        XCTAssertLessThan(pausedAt, 8, "the test needs the playhead before the shifted cue")
        openTracksSheet()
        chooseSubtitle("it")
        closeTracksSheet()
        waitForCue(italianCues, "the cue should be on before the delay is changed")

        // 16 × 0.5 s = 8 s: the cue that starts at 0.5 s now starts at 8.5 s, later than the paused position.
        openTracksSheet()
        let later = element("subtitle.delay.later")
        XCTAssertTrue(later.waitForExistence(timeout: 10))
        for _ in 0..<16 { later.tap() }
        let value = element("subtitle.delay.value")
        XCTAssertTrue(((value.value as? String) ?? "").contains("+8.0"), "the sheet shows the delay: \(String(describing: value.value))")
        closeTracksSheet()
        waitForNoCue(italianCues, "with the text 8 s late the cue is not due at the paused position")

        openTracksSheet()
        element("subtitle.delay.reset").tap()
        closeTracksSheet()
        waitForCue(italianCues, "back at zero the cue is due again")
    }

    // 9k. The recommended subtitles addon is offered in the Addons screen until it is installed
    func testOpenSubtitlesIsRecommendedUntilAnAddonWithItsIdIsInstalled() {
        launch()
        openTab("Altro")
        let addons = element("more.addons")
        XCTAssertTrue(addons.waitForExistence(timeout: 10))
        addons.tap()
        let entry = element("addons.recommended.opensubtitles")
        XCTAssertTrue(entry.waitForExistence(timeout: 20), "OpenSubtitles v3 should be recommended")
        XCTAssertTrue(entry.label.contains("OpenSubtitles v3"), entry.label)
        XCTAssertTrue(element("addons.recommended").exists, "Cinemeta is recommended next to it")
        app.terminate()

        // An addon that carries the official id (the fixture server poses as it) makes the recommendation go away.
        let encoded = (Fixture.base + "/opensubs/manifest.json").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        launch(openURL: "aether://install?url=\(encoded)")
        let confirm = element("addon.install.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "the install preview did not appear")
        confirm.tap()
        XCTAssertTrue(element("addon.row.org.stremio.opensubtitlesv3").waitForExistence(timeout: 20), "the addon was not listed after install")
        XCTAssertFalse(element("addons.recommended.opensubtitles").exists, "an addon with that id is installed: do not offer it again")
        XCTAssertTrue(element("addons.recommended").exists, "Cinemeta is still on offer")
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
        waitUntil(60, "playback did not reach the recording threshold") { (playbackSeconds() ?? 0) >= recordedThreshold }
        closePlayer()
        XCTAssertTrue(element("detail.play").waitForExistence(timeout: 15))

        // Same session first: the library screen lists it right away.
        openTab("Libreria")
        app.buttons["Cronologia"].tap()
        XCTAssertTrue(element(labelContaining: "Aether Fixture One").waitForExistence(timeout: 20), "history shows the title in the same session")
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
        waitUntil(60, "playback did not reach the recording threshold") { (playbackSeconds() ?? 0) >= recordedThreshold }
        closePlayer()
        openTab("Libreria")
        app.buttons["Cronologia"].tap()
        XCTAssertTrue(element("library.empty").waitForExistence(timeout: 15), "no history should exist")
    }
}
