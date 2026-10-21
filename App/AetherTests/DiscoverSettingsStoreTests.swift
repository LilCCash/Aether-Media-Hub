import XCTest
import AetherCore
@testable import Aether

// What Settings > Scopri writes is what Discover reads back, through the real SettingsStore and UserDefaults.
@MainActor
final class DiscoverSettingsStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "aether.tests.discover.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func ids(_ settings: [DiscoverTypeSetting]) -> [String] {
        return settings.map { (setting: DiscoverTypeSetting) -> String in setting.id }
    }

    func testNothingIsStoredUntilTheUserChoosesSomething() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.value.content.discoverTypes.isEmpty)
        let state = DiscoverLayout.normalise(stored: store.value.content.discoverTypes, available: ["tv", "movie"])
        XCTAssertEqual(state.visibleTypes, ["movie", "tv"], "first launch: everything visible, canonical order")
    }

    func testOrderAndVisibilityPersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        let available = ["movie", "series", "tv"]
        var state = DiscoverLayout.normalise(stored: store.value.content.discoverTypes, available: available)
        state.setVisible(false, for: "series")
        state.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        store.value.content.discoverTypes = state.entries

        let reloaded = SettingsStore(defaults: defaults)
        let again = DiscoverLayout.normalise(stored: reloaded.value.content.discoverTypes, available: available)
        XCTAssertEqual(again, state)
        XCTAssertEqual(again.visibleTypes, ["tv", "movie"], "tv first, series hidden")
        XCTAssertEqual(ids(reloaded.value.content.discoverTypes), ["tv", "movie", "series"])
    }

    func testTheChoiceForARemovedAddonsTypeIsRememberedAndComesBack() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        var state = DiscoverLayout.normalise(stored: [], available: ["movie", "sports"])
        state.setVisible(false, for: "sports")
        store.value.content.discoverTypes = state.entries

        // The addon providing sports is removed, and the user changes something else meanwhile.
        var without = DiscoverLayout.normalise(stored: store.value.content.discoverTypes, available: ["movie"])
        XCTAssertEqual(without.visibleTypes, ["movie"])
        without.setVisible(true, for: "movie")
        store.value.content.discoverTypes = without.entries

        let reloaded = SettingsStore(defaults: defaults)
        let back = DiscoverLayout.normalise(stored: reloaded.value.content.discoverTypes, available: ["movie", "sports"])
        XCTAssertEqual(back.exposed.count, 2)
        XCTAssertFalse(back.isVisible("sports"), "reinstalling the addon restores the user's choice: hidden")
        XCTAssertEqual(back.visibleTypes, ["movie"])
    }

    func testWritingTheSameListAgainDoesNotNotify() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var notifications = 0
        store.onChange = { _, _ in notifications += 1 }

        let state = DiscoverLayout.normalise(stored: [], available: ["movie", "series"])
        store.value.content.discoverTypes = state.entries
        XCTAssertEqual(notifications, 1)
        store.value.content.discoverTypes = state.entries
        XCTAssertEqual(notifications, 1, "toggling a switch to the value it already has must not rewrite the settings")
    }

    func testDiscoverTypesTravelWithTheSettingsAsABackupWould() throws {
        var settings = AppSettings()
        settings.content.discoverTypes = [DiscoverTypeSetting(id: "music", isVisible: false), DiscoverTypeSetting(id: "movie")]
        let data = try JSONEncoder.aether().encode(settings)
        let restored = try JSONDecoder.aether().decode(AppSettings.self, from: data)
        XCTAssertEqual(restored.content.discoverTypes, settings.content.discoverTypes)
    }
}
