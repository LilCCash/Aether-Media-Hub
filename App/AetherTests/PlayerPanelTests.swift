import XCTest
@testable import Aether

final class PlayerPanelTests: XCTestCase {
    func testThePanelTakesAboutTwoFifthsOfALandscapePhone() {
        let width = PlayerPanelHost.panelWidth(screenWidth: 932)       // iPhone Pro Max, landscape
        XCTAssertEqual(width, 932 * 0.4, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(PlayerPanelHost.panelWidth(screenWidth: 844), 340, "never narrower than a readable list")
    }

    func testThePanelStopsGrowingOnABigScreen() {
        XCTAssertEqual(PlayerPanelHost.panelWidth(screenWidth: 1366), 520)
        XCTAssertEqual(PlayerPanelHost.panelWidth(screenWidth: 2000), 520)
    }

    func testThePanelNeverCoversTheWholeScreen() {
        XCTAssertEqual(PlayerPanelHost.panelWidth(screenWidth: 320), 320 * 0.92, accuracy: 0.01)
        XCTAssertLessThan(PlayerPanelHost.panelWidth(screenWidth: 390), 390)
    }

    func testEveryPanelHasATitle() {
        XCTAssertEqual(PlayerPanel.subtitles.title, "Sottotitoli")
        XCTAssertEqual(PlayerPanel.audio.title, "Audio")
        XCTAssertEqual(PlayerPanel.sources.title, "Sorgenti")
    }
}
