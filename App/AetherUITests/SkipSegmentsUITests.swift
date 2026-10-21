import XCTest

/// "Salta intro" / "Salta riassunto", end to end against the fixture server's stand-in for IntroDB (Tools/FixtureAddonServer/metadata.js).
/// The fixture series tt9100001 has an intro at 6–30 s in episode 1, and a recap at 2–20 s and an intro at 40–70 s in episode 2.
final class SkipSegmentsUITests: AetherUITestCase {
    private var arguments: [String] { ["-AETHER_UITEST_METADATA_BASE", Fixture.base] }

    private func playFixtureEpisode(_ id: String) {
        openTab("Home")
        let card = button(labelContaining: "Fixture Series")
        XCTAssertTrue(card.waitForExistence(timeout: 30), "the fixture series is not on the Home screen")
        card.tap()
        let episode = element("episode.\(id)")
        XCTAssertTrue(episode.waitForExistence(timeout: 30), "episode \(id) is not listed")
        episode.tap()
        XCTAssertTrue(element("stream.row.0").waitForExistence(timeout: 30), "no source was offered")
        element("stream.row.0").tap()
        XCTAssertTrue(element("player.playPause").waitForExistence(timeout: 30), "the player did not open")
        waitUntil(40, "playback did not start") { (playbackSeconds() ?? 0) >= 1 }
    }

    private func introDBRequests() -> [String] {
        return Fixture.requestedPaths().filter { $0.hasPrefix("/introdb/") }
    }

    func testTheIntroButtonAppearsInsideTheIntroAndJumpsToItsEnd() {
        launchWithFixtureAddon(extraArguments: arguments)
        playFixtureEpisode("tt9100001:1:1")
        let skip = element("player.skipSegment")
        XCTAssertTrue(skip.waitForExistence(timeout: 40), "the intro button should appear once playback reaches 5 s")
        XCTAssertEqual(skip.label, "Salta intro")
        let asked = introDBRequests()
        XCTAssertTrue(asked.contains { $0.contains("imdb_id=tt9100001") && $0.contains("season=1") && $0.contains("episode=1") },
                      "IntroDB should have been asked for this episode, saw \(asked)")
        skip.tap()
        waitUntil(30, "the playhead did not jump to the end of the intro") { (playbackSeconds() ?? 0) >= 29 }
        waitUntil(15, "the button should leave once the intro is over") { !self.element("player.skipSegment").exists }
    }

    func testTheRecapButtonComesFirstAndTheIntroButtonAfterIt() {
        launchWithFixtureAddon(extraArguments: arguments)
        playFixtureEpisode("tt9100001:1:2")
        let recap = element("player.skipSegment")
        XCTAssertTrue(recap.waitForExistence(timeout: 30), "the recap button should be there from the start")
        XCTAssertEqual(recap.label, "Salta riassunto")
        recap.tap()
        waitUntil(30, "the playhead did not jump to the end of the recap") { (playbackSeconds() ?? 0) >= 19 }
        waitUntil(60, "the intro button never appeared at 40 s") {
            self.element("player.skipSegment").exists && self.element("player.skipSegment").label == "Salta intro"
        }
    }

    func testNothingIsAskedAndNoButtonShownWhenTheSettingIsOff() {
        launchWithFixtureAddon(settings: #"{"playback":{"controlsAutoHideSeconds":15,"skipSegmentsEnabled":false}}"#,
                               extraArguments: arguments)
        playFixtureEpisode("tt9100001:1:1")
        waitUntil(40, "playback did not pass the start of the intro") { (playbackSeconds() ?? 0) >= 9 }
        XCTAssertFalse(element("player.skipSegment").exists, "the setting is off")
        XCTAssertTrue(introDBRequests().isEmpty, "the setting is off: IntroDB must not be asked, saw \(introDBRequests())")
    }
}
