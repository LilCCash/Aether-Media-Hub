import XCTest
@testable import AetherCore

// The Discover order/visibility is stored in `ContentSettings.discoverTypes`. Like every setting it must survive
// older files, hand-edited files and backups made by other versions, and it must plug into `DiscoverLayout`.
final class ContentSettingsDiscoverTests: XCTestCase {
    private func decodeContent(_ json: String) throws -> ContentSettings {
        return try JSONDecoder.aether().decode(ContentSettings.self, from: Data(json.utf8))
    }

    private func ids(_ settings: [DiscoverTypeSetting]) -> [String] {
        return settings.map { (setting: DiscoverTypeSetting) -> String in setting.id }
    }

    private func visibility(_ settings: [DiscoverTypeSetting]) -> [Bool] {
        return settings.map { (setting: DiscoverTypeSetting) -> Bool in setting.isVisible }
    }

    func testNothingIsStoredByDefault() {
        XCTAssertEqual(ContentSettings().discoverTypes, [])
        XCTAssertEqual(AppSettings().content.discoverTypes, [])
    }

    func testFilesWrittenBeforeTheSettingExistedDecodeToTheDefault() throws {
        let content = try decodeContent("{\"hideAdultCatalogs\":false,\"searchSort\":\"title\"}")
        XCTAssertEqual(content.discoverTypes, [])
        XCTAssertFalse(content.hideAdultCatalogs, "the rest of the file is still read")
        XCTAssertEqual(content.searchSort, .title)
    }

    func testOrderAndVisibilitySurviveEncodingAndDecoding() throws {
        var settings = AppSettings()
        settings.content.discoverTypes = [
            DiscoverTypeSetting(id: "sports", isVisible: true),
            DiscoverTypeSetting(id: "movie", isVisible: false),
            DiscoverTypeSetting(id: "tv", isVisible: true)
        ]
        let data = try JSONEncoder.aether().encode(settings)
        let decoded = try JSONDecoder.aether().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.content.discoverTypes, settings.content.discoverTypes)
        XCTAssertEqual(ids(decoded.content.discoverTypes), ["sports", "movie", "tv"], "the user's order is kept")
        XCTAssertEqual(visibility(decoded.content.discoverTypes), [true, false, true])
    }

    func testUnreadableEntriesAreDroppedAndTheRestIsKept() throws {
        let json = "{\"discoverTypes\":[{\"id\":\"tv\",\"isVisible\":false},{\"isVisible\":true},42,"
            + "{\"id\":\"  \"},{\"id\":\"movie\"}]}"
        let content = try decodeContent(json)
        XCTAssertEqual(ids(content.discoverTypes), ["tv", "movie"])
        XCTAssertEqual(visibility(content.discoverTypes), [false, true], "a missing flag means visible")
    }

    func testAWrongShapeFallsBackToTheDefaultInsteadOfFailing() throws {
        XCTAssertEqual(try decodeContent("{\"discoverTypes\":\"nope\"}").discoverTypes, [])
        XCTAssertEqual(try decodeContent("{\"discoverTypes\":{\"id\":\"tv\"}}").discoverTypes, [])
        XCTAssertEqual(try decodeContent("{\"discoverTypes\":null}").discoverTypes, [])
    }

    func testAPartialSettingsFileFromAnotherVersionStillDecodes() throws {
        let json = "{\"content\":{\"discoverTypes\":[{\"id\":\"music\",\"isVisible\":false}]},\"playback\":{\"engine\":\"invented\"}}"
        let settings = try JSONDecoder.aether().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(ids(settings.content.discoverTypes), ["music"])
        XCTAssertEqual(settings.playback.engine, .automatic, "unrelated invalid values fall back to their defaults")
    }

    func testStoredEntriesFeedTheLayoutAndKeepTypesOfRemovedAddons() throws {
        let json = "{\"discoverTypes\":[{\"id\":\"sports\",\"isVisible\":false},{\"id\":\"tv\"},{\"id\":\"movie\"}]}"
        let content = try decodeContent(json)

        // The addon serving "sports" is gone: its entry is remembered, not shown.
        let withoutSports = DiscoverLayout.normalise(stored: content.discoverTypes, available: ["movie", "series", "tv"])
        XCTAssertEqual(withoutSports.visibleTypes, ["tv", "movie", "series"],
                       "stored order first, then the type seen for the first time")
        XCTAssertEqual(ids(withoutSports.entries), ["sports", "tv", "movie", "series"])

        // Reinstalling it restores the choice the user made (hidden, first in order).
        let withSports = DiscoverLayout.normalise(stored: withoutSports.entries,
                                                  available: ["movie", "series", "tv", "sports"])
        XCTAssertEqual(ids(withSports.exposed), ["sports", "tv", "movie", "series"])
        XCTAssertFalse(withSports.isVisible("sports"))
        XCTAssertEqual(withSports.visibleTypes, ["tv", "movie", "series"])
    }

    func testWhatTheSettingsPageWritesComesBackUnchanged() throws {
        // The settings page persists `entries` of the state it edited; reading them back must give the same state.
        var state = DiscoverLayout.normalise(stored: [], available: ["movie", "series", "tv", "sports"])
        state.setVisible(false, for: "series")
        state.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        var settings = AppSettings()
        settings.content.discoverTypes = state.entries

        let data = try JSONEncoder.aether().encode(settings)
        let decoded = try JSONDecoder.aether().decode(AppSettings.self, from: data)
        let reread = DiscoverLayout.normalise(stored: decoded.content.discoverTypes,
                                              available: ["movie", "series", "tv", "sports"])
        XCTAssertEqual(reread, state)
        XCTAssertEqual(reread.visibleTypes, ["sports", "movie", "tv"])
    }
}
