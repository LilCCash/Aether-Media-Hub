import XCTest

/// Connection to the stand-in for the TorBox API started by CI (Tools/FixtureTorBoxServer/server.js, port 7778). It is a test
/// double built from the public documentation, not the real service; its key `test-key` is a fixture, not a secret.
enum TorBoxFixture {
    static let base = "http://127.0.0.1:7778"
    static let key = "test-key"

    /// Calls a control endpoint; retried because a busy CI machine occasionally drops the first request.
    @discardableResult
    static func control(_ path: String) -> Bool {
        guard let url = URL(string: base + path) else { return false }
        for attempt in 0..<4 {
            let done = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: url) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 8)
            if ok { return true }
            Thread.sleep(forTimeInterval: Double(attempt + 1) * 0.5)
        }
        return false
    }

    /// Every path the fixture was asked for since the last reset, query strings removed (so the key never shows up here).
    static func requestedPaths() -> [String] {
        guard let url = URL(string: base + "/__control/requests") else { return [] }
        let done = DispatchSemaphore(value: 0)
        var paths: [String] = []
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let decoded = try? JSONDecoder().decode([String].self, from: data) { paths = decoded }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return paths
    }

    static func count(of path: String) -> Int {
        return requestedPaths().filter { $0 == path }.count
    }

    static func setMode(_ name: String) {
        control("/__control/mode?name=\(name)")
    }
}

/// TorBox end to end: the key typed in Impostazioni > Servizi, the connection status, the cache badge in the source list,
/// playing a cached torrent, the confirmation before a download, and the messages of every kind of failure. All of it against
/// the stand-in server: the real service is never contacted.
final class TorBoxUITests: AetherUITestCase {
    private let cachedMovie = "Torbox Cached Film"
    private let downloadMovie = "Torbox Download Film"
    private let cachedSeries = "Torbox Cached Series"

    private var torboxArguments: [String] { ["-AETHER_UITEST_TORBOX_URL", TorBoxFixture.base] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(TorBoxFixture.control("/__control/reset"), "the TorBox fixture server is not running on \(TorBoxFixture.base)")
    }

    override func tearDownWithError() throws {
        TorBoxFixture.control("/__control/reset")
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func launchApp() {
        launchWithFixtureAddon(extraArguments: torboxArguments)
    }

    private func openServices() {
        openMoreRoot()
        element("more.settings").tap()
        let services = element("settings.Servizi")
        var swipes = 0
        while !services.waitForExistence(timeout: 5) && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(services.exists, "the Servizi page is not listed in the settings")
        services.tap()
    }

    private func enterText(_ text: String, into identifier: String) {
        let field = element(identifier)
        if !field.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(identifier) missing")
        field.tap()
        field.typeText(text)
    }

    /// The text of the status line, once `done` accepts it (or after the timeout, whatever it said last).
    private func statusText(timeout: TimeInterval = 25, until done: (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let status = element("service.torbox.status")
            if status.exists {
                last = status.label
                if done(last) { return last }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return last
    }

    /// Types the key, saves it and waits for the connection check to end well.
    private func connect() {
        openServices()
        enterText(TorBoxFixture.key, into: "service.torbox.key")
        element("service.torbox.save").tap()
        XCTAssertTrue(element("service.torbox.saved").waitForExistence(timeout: 30), "the key was not kept")
        let status = statusText { $0.contains("Connesso a TorBox") }
        XCTAssertTrue(status.contains("Connesso a TorBox"), "TorBox should be connected, the status says: \(status)")
    }

    /// Taps "Verifica connessione" once the button is usable again.
    private func verifyAgain() {
        let verify = element("service.torbox.verify")
        XCTAssertTrue(verify.waitForExistence(timeout: 10), "the verify button is missing")
        waitUntil(20, "the verify button stayed disabled") { verify.isEnabled }
        verify.tap()
    }

    private func openPicker(forTitle query: String, named name: String) {
        openTitleViaSearch(query, expecting: name)
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 20), "no play button")
        play.tap()
    }

    private func label(of identifier: String) -> String {
        let item = element(identifier)
        return item.exists ? item.label : ""
    }

    private func waitForLabel(of identifier: String, toContain text: String, timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label(of: identifier).contains(text) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return false
    }

    private func waitForPlaybackToAdvance(seconds: Double = 2) {
        let opened = element("player.playPause").waitForExistence(timeout: 50)
        XCTAssertTrue(opened, "the player did not open. error: \(label(of: "player.error")) picker error: \(label(of: "stream.debrid.error"))")
        waitUntil(45, "the playhead never advanced past \(seconds) s") { (playbackSeconds() ?? 0) >= seconds }
        XCTAssertFalse(element("player.error").exists, "no error panel while playing")
    }

    // MARK: Without a key

    func testWithoutAKeyATorrentIsNotPlayableAndPointsToTheSettings() {
        launchApp()
        openPicker(forTitle: "Cached Film", named: cachedMovie)
        let group = button(labelContaining: "Non riproducibili")
        XCTAssertTrue(group.waitForExistence(timeout: 30), "a torrent without TorBox should be listed as not playable")
        XCTAssertFalse(element("stream.row.0").exists, "there is nothing playable to start")
        group.tap()
        XCTAssertTrue(element(labelContaining: "configura TorBox").waitForExistence(timeout: 10),
                      "the row should say where to set TorBox up")
        XCTAssertTrue(element(labelContaining: "Servizi").exists, "and name the page: Impostazioni > Servizi")
        XCTAssertTrue(TorBoxFixture.requestedPaths().isEmpty, "without a key TorBox must not be contacted at all")
    }

    // MARK: Settings > Servizi

    func testTheFixtureKeyConnectsAndTheStatusShowsThePlanButNeverTheKeyOrTheEmail() {
        launchApp()
        connect()
        let status = label(of: "service.torbox.status")
        XCTAssertTrue(status.contains("Pro"), "the plan should be shown, got: \(status)")
        XCTAssertTrue(status.contains("Scade il"), "the expiry is shown because the API returned one, got: \(status)")
        XCTAssertTrue(element(labelContaining: "Chiave salvata nel Portachiavi").exists)
        XCTAssertFalse(element("service.torbox.key").exists, "the key field is gone once the key is saved: it is never echoed back")
        for field in app.secureTextFields.allElementsBoundByIndex where field.exists {
            XCTAssertFalse(((field.value as? String) ?? "").contains(TorBoxFixture.key), "no field may hold the saved key")
        }
        XCTAssertFalse(element(labelContaining: TorBoxFixture.key).exists, "the key must not appear anywhere on screen")
        XCTAssertFalse(element(labelContaining: "fixture.user@example.com").exists, "the e-mail address of the account is never shown")
        XCTAssertGreaterThanOrEqual(TorBoxFixture.count(of: "/v1/api/user/me"), 1, "the connection was really checked with TorBox")
        XCTAssertEqual(TorBoxFixture.count(of: "/v1/api/torrents/createtorrent"), 0, "checking the key adds nothing to the account")
    }

    func testAWrongKeyShowsTheInvalidKeyMessageAndIsNotKept() {
        launchApp()
        openServices()
        enterText("wrong-key", into: "service.torbox.key")
        element("service.torbox.save").tap()
        let message = statusText { $0.contains("non è stata salvata") }
        XCTAssertTrue(message.contains("Chiave non valida"), "the refusal should be explained, got: \(message)")
        XCTAssertTrue(message.contains("non è stata salvata"), "a refused key must not be kept, got: \(message)")
        XCTAssertFalse(element("service.torbox.saved").exists)
        XCTAssertTrue(element("service.torbox.key").waitForExistence(timeout: 10), "the field is offered again")

        enterText(TorBoxFixture.key, into: "service.torbox.key")
        element("service.torbox.save").tap()
        XCTAssertTrue(element("service.torbox.saved").waitForExistence(timeout: 30), "the right key is kept")
        let status = statusText { $0.contains("Connesso a TorBox") }
        XCTAssertTrue(status.contains("Connesso a TorBox"), "got: \(status)")
    }

    func testRemovingTheKeyForgetsItAndStopsEveryCall() {
        launchApp()
        connect()
        element("service.torbox.remove").tap()
        XCTAssertTrue(element("service.torbox.key").waitForExistence(timeout: 10), "after removal the key field is back")
        XCTAssertFalse(element("service.torbox.saved").exists)
        let before = TorBoxFixture.requestedPaths().count

        openPicker(forTitle: "Cached Film", named: cachedMovie)
        XCTAssertTrue(button(labelContaining: "Non riproducibili").waitForExistence(timeout: 30),
                      "without the key the torrent is not playable again")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(TorBoxFixture.requestedPaths().count, before, "a removed key must not be used again")
        XCTAssertFalse(TorBoxFixture.requestedPaths().contains { $0.contains("control") }, "nothing is ever deleted on TorBox")
    }

    func testRateLimitingAndAnUnreachableServiceHaveTheirOwnMessages() {
        launchApp()
        connect()

        TorBoxFixture.setMode("rate_limit")
        verifyAgain()
        let limited = statusText(timeout: 40) { $0.contains("limitando") }
        XCTAssertTrue(limited.contains("limitando"), "rate limiting should be explained, got: \(limited)")
        XCTAssertTrue(element("service.torbox.saved").exists, "a rate limit does not remove the key")

        TorBoxFixture.setMode("offline")
        verifyAgain()
        let unreachable = statusText { $0.contains("raggiungere") }
        XCTAssertTrue(unreachable.contains("Impossibile raggiungere TorBox"), "an unreachable service should be said so, got: \(unreachable)")

        TorBoxFixture.setMode("normal")
        verifyAgain()
        let recovered = statusText { $0.contains("Connesso a TorBox") }
        XCTAssertTrue(recovered.contains("Connesso a TorBox"), "the status recovers once TorBox answers, got: \(recovered)")
    }

    func testAGatewayPageAndARevokedKeyAreToldApart() {
        launchApp()
        connect()

        TorBoxFixture.setMode("html_error")
        verifyAgain()
        let gateway = statusText(timeout: 40) { $0.contains("non risponde correttamente") }
        XCTAssertTrue(gateway.contains("non risponde correttamente"), "a gateway page is a service problem, got: \(gateway)")

        TorBoxFixture.setMode("bad_token")
        verifyAgain()
        let revoked = statusText { $0.contains("Chiave non valida") }
        XCTAssertTrue(revoked.contains("Chiave non valida"), "a key TorBox no longer accepts is reported as invalid, got: \(revoked)")
        XCTAssertTrue(element("service.torbox.saved").exists, "the user decides whether to remove it")
    }

    func testTheFreePlanIsSaidAndThePickerExplainsThatTheCacheCheckIsNotAllowed() {
        launchApp()
        connect()
        TorBoxFixture.setMode("plan_restricted")
        verifyAgain()
        let status = statusText { $0.contains("Piano Free") }
        XCTAssertTrue(status.contains("Free"), "the plan should be shown, got: \(status)")
        XCTAssertTrue(status.contains("Piano Free"), "the limits of the free plan should be mentioned, got: \(status)")

        openPicker(forTitle: "Cached Film", named: cachedMovie)
        XCTAssertTrue(element("stream.debrid.cacheError").waitForExistence(timeout: 30), "the failed cache check should be explained")
        XCTAssertTrue(label(of: "stream.debrid.cacheError").contains("non è inclusa nel tuo piano"),
                      "got: \(label(of: "stream.debrid.cacheError"))")
        XCTAssertFalse(element("stream.debrid.cacheRetry").exists, "retrying cannot fix a plan problem")
        let row = label(of: "stream.row.0")
        XCTAssertFalse(row.localizedCaseInsensitiveContains("in cache"), "a failed check is never shown as 'non in cache': \(row)")
    }

    // MARK: The source list

    func testACachedTorrentIsBadgedPlaysAndItsClockAdvances() {
        launchApp()
        connect()
        openPicker(forTitle: "Cached Film", named: cachedMovie)
        tapRowWhenBadged(expecting: "In cache su TorBox")
        waitForPlaybackToAdvance()

        let paths = TorBoxFixture.requestedPaths()
        XCTAssertTrue(paths.contains("/v1/api/torrents/checkcached"), "the cache was checked before anything else")
        XCTAssertEqual(paths.filter { $0 == "/v1/api/torrents/createtorrent" }.count, 1, "the cached torrent is added to the account once")
        XCTAssertTrue(paths.contains("/cdn/Cached.Movie.2024.1080p.mp4"), "the player fetched the file TorBox returned")
        XCTAssertFalse(paths.contains { $0.contains("control") }, "Aether never deletes, pauses or repairs the user's items")
        XCTAssertFalse(Fixture.requestedPaths().contains { $0.hasPrefix("/cdn") }, "the addon server never serves the torrent")
    }

    /// Waits for the first row's cache badge to say `text` (the comparison is case sensitive: "In cache" is not "Non in cache"),
    /// then taps the row.
    private func tapRowWhenBadged(expecting text: String) {
        XCTAssertTrue(element("stream.row.0").waitForExistence(timeout: 30), "the torrent is not listed as playable with TorBox on")
        XCTAssertTrue(waitForLabel(of: "stream.row.0", toContain: text), "the cache badge never said '\(text)': \(label(of: "stream.row.0"))")
        element("stream.row.0").tap()
    }

    func testANotCachedTorrentAsksBeforeDownloadingThenShowsProgressAndPlays() {
        launchApp()
        connect()
        openPicker(forTitle: "Download Film", named: downloadMovie)
        XCTAssertTrue(element("stream.row.0").waitForExistence(timeout: 30))
        XCTAssertTrue(waitForLabel(of: "stream.row.0", toContain: "Non in cache su TorBox"),
                      "the badge should say it is not in cache: \(label(of: "stream.row.0"))")

        // The question comes first, and "no" adds nothing to the account.
        element("stream.row.0").tap()
        XCTAssertTrue(element(labelContaining: "Avvia il download su TorBox").waitForExistence(timeout: 10), "no confirmation was asked")
        XCTAssertEqual(TorBoxFixture.count(of: "/v1/api/torrents/createtorrent"), 0, "nothing is added before the user says yes")
        let cancel = app.buttons["Annulla"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertFalse(app.buttons["Avvia il download"].waitForExistence(timeout: 2), "the question should be gone")
        XCTAssertEqual(TorBoxFixture.count(of: "/v1/api/torrents/createtorrent"), 0, "'Annulla' adds nothing to the account")

        // "Yes" starts the download and shows what TorBox reports.
        element("stream.row.0").tap()
        let start = app.buttons["Avvia il download"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "the question did not come back")
        start.tap()
        XCTAssertTrue(element("stream.debrid.progress").waitForExistence(timeout: 20), "no progress was shown")
        XCTAssertTrue(element(labelContaining: "Download su TorBox in corso").waitForExistence(timeout: 20),
                      "the state reported by TorBox should be shown")
        let percent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "%")).firstMatch
        XCTAssertTrue(percent.waitForExistence(timeout: 15), "the percentage reported by TorBox should be shown")
        waitForPlaybackToAdvance()

        let paths = TorBoxFixture.requestedPaths()
        XCTAssertEqual(paths.filter { $0 == "/v1/api/torrents/createtorrent" }.count, 1)
        XCTAssertTrue(paths.contains("/cdn/Slow.Download.2024.720p.mp4"))
        XCTAssertFalse(paths.contains { $0.contains("control") }, "Aether never deletes, pauses or repairs the user's items")
    }

    func testStoppingTheWaitStopsAskingTorBoxAndLeavesTheAccountAlone() {
        launchApp()
        connect()
        openPicker(forTitle: "Download Film", named: downloadMovie)
        XCTAssertTrue(waitForLabel(of: "stream.row.0", toContain: "Non in cache su TorBox"))
        element("stream.row.0").tap()
        let start = app.buttons["Avvia il download"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "no confirmation was asked")
        start.tap()
        XCTAssertTrue(element("stream.debrid.progress").waitForExistence(timeout: 20), "no progress was shown")
        let cancel = element("stream.debrid.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the wait cannot be cancelled")
        cancel.tap()
        waitUntil(10, "the progress did not go away") { !self.element("stream.debrid.progress").exists }
        XCTAssertFalse(element("player.playPause").exists, "cancelling must not open the player")

        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let polled = TorBoxFixture.count(of: "/v1/api/torrents/mylist")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(TorBoxFixture.count(of: "/v1/api/torrents/mylist"), polled, "TorBox is not asked again once the user stopped waiting")
        XCTAssertFalse(TorBoxFixture.requestedPaths().contains { $0.contains("control") }, "the item stays in the account: nothing is deleted")
        XCTAssertTrue(element("stream.row.0").exists, "the list is still there to choose again")
    }

    func testASeasonPackPlaysTheEpisodeThatWasChosenNotTheLargestFile() {
        launchApp()
        connect()
        openTitleViaSearch("Cached Series", expecting: cachedSeries)
        let second = element("episode.tt9400003:1:2")
        XCTAssertTrue(second.waitForExistence(timeout: 30), "the second episode is not listed")
        second.tap()
        tapRowWhenBadged(expecting: "In cache su TorBox")
        waitForPlaybackToAdvance()

        let paths = TorBoxFixture.requestedPaths()
        XCTAssertTrue(paths.contains("/cdn/Cached.Series.S01E02.1080p.mp4"), "episode 2 was asked for: \(paths)")
        XCTAssertFalse(paths.contains("/cdn/Cached.Series.S01E01.1080p.mp4"), "the larger first episode must not be picked")
    }

    // MARK: Large text

    func testTheServicesPageFitsTheScreenAtTheLargestTextSize() {
        launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openServices()
        let window = app.windows.firstMatch.frame
        for identifier in ["service.torbox.key", "service.torbox.save", "service.torbox.site"] {
            let item = element(identifier)
            var swipes = 0
            while !item.exists && swipes < 8 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(item.exists, "\(identifier) is not reachable at the largest text size")
            let frame = item.frame
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 0.5, "\(identifier) starts left of the screen")
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(identifier) ends right of the screen")
        }
    }
}
