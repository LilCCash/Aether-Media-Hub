import XCTest

/// A tour of the main screens, photographed in light and in dark, so the look of every change can be checked without a phone.
/// The pictures go into the result bundle and, when `AETHER_SCREENSHOT_DIR` is set (CI passes it as TEST_RUNNER_…), into that
/// folder as PNG files. A screen that cannot be reached is skipped: the tour is for looking, not for testing behaviour.
final class ScreenshotTourUITests: AetherUITestCase {
    private var theme = "dark"

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
    }

    func testTourDark() { tour(theme: "dark") }
    func testTourLight() { tour(theme: "light") }

    private func tour(theme: String) {
        self.theme = theme
        let settings = #"{"playback":{"controlsAutoHideSeconds":15},"appearance":{"schema":2,"theme":"\#(theme)"}}"#
        launchWithFixtureAddon(settings: settings)
        pause(3)
        snap("01-home")
        app.swipeUp()
        pause(1.5)
        snap("02-home-sotto")
        app.swipeDown()

        openTab("Scopri")
        pause(3)
        snap("03-scopri")

        openTab("Libreria")
        pause(2)
        snap("04-libreria")

        openTab("Profilo")
        pause(2)
        snap("05-profilo")
        if tap(element("profile.settings")) {
            pause(1.5)
            snap("06-impostazioni")
            if tap(button(labelContaining: "Aspetto")) {
                pause(1.5)
                snap("07-impostazioni-aspetto")
                back()
            }
            if tap(element("settings.streams")) {
                pause(1.5)
                snap("08-impostazioni-sorgenti")
                back()
            }
            back()
        }

        openTab("Cerca")
        pause(2)
        snap("09-cerca")

        openTab("Home")
        let movie = button(labelContaining: "Aether Fixture One")
        if tap(movie, timeout: 30), element("detail.title").waitForExistence(timeout: 20) {
            pause(2.5)
            snap("10-scheda-film")
            app.swipeUp()
            pause(1)
            snap("11-scheda-film-sotto")
            app.swipeDown()
            if tap(element("detail.play")), element("stream.row.0").waitForExistence(timeout: 30) {
                pause(2)
                snap("12-sorgenti")
                _ = tap(app.buttons["Chiudi"].firstMatch, timeout: 3)
            }
        }

        openTab("Cerca")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("Fixture Series")
            pause(2)
            snap("13-cerca-risultati")
            if tap(button(labelContaining: "Fixture Series"), timeout: 30), element("detail.title").waitForExistence(timeout: 20) {
                pause(2.5)
                snap("14-scheda-serie")
                app.swipeUp()
                pause(1)
                snap("15-scheda-serie-episodi")
            }
        }
    }

    // MARK: Helpers

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        guard element.waitForExistence(timeout: timeout), element.isHittable else { return false }
        element.tap()
        return true
    }

    private func back() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists && back.isHittable { back.tap() }
        pause(0.8)
    }

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(theme)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["AETHER_SCREENSHOT_DIR"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(theme)-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url)
    }
}
