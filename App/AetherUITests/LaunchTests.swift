import XCTest

final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsTheFiveTabs() {
        let app = XCUIApplication()
        app.launchArguments = ["-AETHER_UITEST"]
        app.launch()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20), "tab bar did not appear")
        for title in ["Home", "Scopri", "Libreria", "Cerca", "Altro"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "missing tab \(title)")
        }
    }
}
