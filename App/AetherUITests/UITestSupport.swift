import XCTest

/// Connection to the controlled addon server started by CI (Tools/FixtureAddonServer/server.js).
enum Fixture {
    static let base = "http://127.0.0.1:7777"
    static var manifestURL: String { base + "/manifest.json" }
    static var badManifestURL: String { base + "/bad/manifest.json" }
    static var htmlManifestURL: String { base + "/html/manifest.json" }

    /// The CI machine's LAN address (passed as TEST_RUNNER_AETHER_FIXTURE_LAN_HOST). Downloads refuse loopback
    /// addresses by design, so the download test reaches the same server through this address.
    static var lanManifestURL: String? {
        guard let host = ProcessInfo.processInfo.environment["AETHER_FIXTURE_LAN_HOST"], !host.isEmpty else { return nil }
        return "http://\(host):7777/manifest.json"
    }

    @discardableResult
    static func control(_ path: String) -> Bool {
        guard let url = URL(string: base + path) else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return ok
    }

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
}

class AetherUITestCase: XCTestCase {
    var app: XCUIApplication!
    /// One storage namespace per test; relaunching with the same id keeps data (persistence tests).
    let session = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCTAssertTrue(Fixture.control("/__control/reset"), "the fixture addon server is not running on \(Fixture.base)")
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: Launching

    /// Settings used by every test unless it overrides them: controls stay up long enough to be tapped.
    static let defaultSettings = #"{"playback":{"controlsAutoHideSeconds":15}}"#

    func launch(reset: Bool = true, settings: String? = AetherUITestCase.defaultSettings, openURL: String? = nil) {
        app = XCUIApplication()
        var arguments = ["-AETHER_UITEST", "-AETHER_UITEST_SESSION", session]
        if reset { arguments.append("-AETHER_UITEST_RESET") }
        if let settings = settings { arguments += ["-AETHER_UITEST_SETTINGS", settings] }
        if let openURL = openURL { arguments += ["-AETHER_UITEST_OPENURL", openURL] }
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 40), "the tab bar did not appear")
    }

    /// Launches and installs the fixture addon through the `aether://install` deep link (no keyboard needed).
    func launchWithFixtureAddon(settings: String? = AetherUITestCase.defaultSettings, manifestURL: String = Fixture.manifestURL) {
        let encoded = manifestURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? manifestURL
        launch(settings: settings, openURL: "aether://install?url=\(encoded)")
        let confirm = element("addon.install.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "the install preview did not appear")
        confirm.tap()
        XCTAssertTrue(element("addon.row.org.aether.fixture").waitForExistence(timeout: 20), "the addon was not listed after install")
        openTab("Home")
    }

    // MARK: Queries

    func element(_ identifier: String) -> XCUIElement {
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func element(labelContaining text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    func button(labelContaining text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        return app.buttons.matching(predicate).firstMatch
    }

    func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "tab \(name) missing")
        tab.tap()
    }

    func waitUntil(_ timeout: TimeInterval = 20, _ message: String = "condition not met", _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail(message)
    }

    // MARK: Navigation shortcuts

    func openFixtureMovie(named name: String = "Aether Fixture One") {
        openTab("Home")
        let card = button(labelContaining: name)
        XCTAssertTrue(card.waitForExistence(timeout: 30), "poster \(name) not shown on Home")
        card.tap()
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 20), "detail screen did not open")
    }

    /// Opens a title through the search tab, which (unlike a horizontally scrolling Home row) always shows the match on screen.
    func openTitleViaSearch(_ query: String, expecting name: String) {
        openTab("Cerca")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(query)
        let result = button(labelContaining: name)
        XCTAssertTrue(result.waitForExistence(timeout: 30), "search did not return \(name)")
        result.tap()
        XCTAssertTrue(element("detail.title").waitForExistence(timeout: 20), "detail screen did not open")
    }

    func openStreamPicker() {
        let play = element("detail.play")
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        XCTAssertTrue(element("stream.row.0").waitForExistence(timeout: 30), "no source listed")
    }

    func startPlayback() {
        openStreamPicker()
        element("stream.row.0").tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30), "the player did not open")
    }

    /// The overlay auto-hides after at most 15 s; bring it back (a tap toggles it) before using its buttons.
    func closePlayer() {
        let close = element("player.close")
        if !close.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = close.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(close.exists, "the player's close button is not reachable")
        close.tap()
    }

    /// "0:07 di 2:30" → 7
    func playbackSeconds() -> Double? {
        let scrubber = element("player.scrubber")
        guard scrubber.exists, let value = scrubber.value as? String else { return nil }
        let first = value.components(separatedBy: " di ").first ?? ""
        let parts = first.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
