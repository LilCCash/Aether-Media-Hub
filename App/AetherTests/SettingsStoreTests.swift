import XCTest
import SwiftUI
import AetherCore
@testable import Aether

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "aether.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testChangesPersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.playback.skipForwardSeconds = 30
        store.value.appearance.accent = .jade
        store.value.privacy.allowLocalNetwork = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.value.playback.skipForwardSeconds, 30)
        XCTAssertEqual(reloaded.value.appearance.accent, .jade)
        XCTAssertTrue(reloaded.value.privacy.allowLocalNetwork)
    }

    func testOnChangeReportsOldAndNewValues() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var seen: [(Bool, Bool)] = []
        store.onChange = { new, old in seen.append((old.privacy.recordHistory, new.privacy.recordHistory)) }
        store.value.privacy.recordHistory = false
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].0)
        XCTAssertFalse(seen[0].1)
        // Writing the same value again must not notify.
        store.value.privacy.recordHistory = false
        XCTAssertEqual(seen.count, 1)
    }

    func testSnapshotFollowsStore() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.storage.maxConcurrentDownloads = 4
        XCTAssertEqual(store.snapshot.get().storage.maxConcurrentDownloads, 4)
    }

    func testBindingWritesThrough() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let binding = store.binding(\.playback.autoplayNextEpisode)
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(store.value.playback.autoplayNextEpisode)
    }

    func testResetRestoresDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.appearance.theme = .dark
        store.resetToDefaults()
        XCTAssertEqual(store.value, AppSettings())
        XCTAssertEqual(SettingsStore(defaults: defaults).value, AppSettings())
    }

    func testResolvedLanguage() {
        XCTAssertNil(SettingsStore.resolvedLanguage("off"))
        XCTAssertEqual(SettingsStore.resolvedLanguage("ita"), "it")
        XCTAssertEqual(SettingsStore.resolvedLanguage("en"), "en")
    }

    func testColorSchemeMapping() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertNil(store.colorScheme)
        store.value.appearance.theme = .light
        XCTAssertEqual(store.colorScheme, .light)
        store.value.appearance.theme = .dark
        XCTAssertEqual(store.colorScheme, .dark)
    }
}
