import XCTest
@testable import AetherCore

final class NextGenOptionsTests: XCTestCase {
    private func ranked(_ details: String) -> RankedStream {
        let stream = AddonStream(source: .url("https://cdn.example/\(UUID().uuidString).mkv"), name: "Addon", details: details)
        return RankedStream(stream: stream, info: StreamAnalyzer.analyze(stream), score: 0)
    }

    func testQuickFiltersNarrowAndNeverWiden() {
        let list = [ranked("Film 2160p HDR10 ITA ENG"), ranked("Film 1080p ITA"), ranked("Film 1080p ENG"), ranked("Film 720p")]
        XCTAssertEqual(StreamQuickFilter().apply(list).count, list.count, "no filter, untouched")
        XCTAssertEqual(StreamQuickFilter(quality: .fullHD1080).apply(list).count, 2)
        XCTAssertEqual(StreamQuickFilter(hdrOnly: true).apply(list).count, 1)
        let qualities = StreamQuickFilter.qualities(in: list)
        XCTAssertEqual(qualities.first, .uhd2160)
        XCTAssertFalse(qualities.contains(.unknown))
        XCTAssertTrue(StreamQuickFilter.hasHDR(in: list))
        let languages = StreamQuickFilter.languages(in: list)
        if let first = languages.first {
            let narrowed = StreamQuickFilter(language: first).apply(list)
            XCTAssertFalse(narrowed.isEmpty)
            XCTAssertLessThanOrEqual(narrowed.count, list.count)
        }
        let combined = StreamQuickFilter(quality: .uhd2160, hdrOnly: true).apply(list)
        XCTAssertEqual(combined.count, 1)
    }

    func testNewAppearanceSwitchesDefaultAndSurviveOlderFiles() throws {
        let fresh = AppearanceSettings()
        XCTAssertTrue(fresh.adaptiveHeroHeight && fresh.legibilityScrims && fresh.streamQuickFilters && fresh.settingsSearch)
        XCTAssertFalse(fresh.glassDiscoverTab, "the glass Home keeps its own bar unless the viewer asks")
        XCTAssertFalse(fresh.essentialSettings)

        // A file written before these switches existed decodes with the defaults.
        var data = try JSONEncoder().encode(fresh)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["adaptiveHeroHeight", "legibilityScrims", "streamQuickFilters", "glassDiscoverTab", "settingsSearch", "essentialSettings"] {
            object.removeValue(forKey: key)
        }
        data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: data), fresh)

        // Turned off, they stay off.
        var off = fresh
        off.adaptiveHeroHeight = false; off.legibilityScrims = false; off.streamQuickFilters = false
        off.settingsSearch = false; off.glassDiscoverTab = true; off.essentialSettings = true
        XCTAssertEqual(try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(off)), off)
    }

    func testBalancedPresetTonesEffectsDownAndOtherPresetsBringThemBack() {
        var a = AppearanceSettings()
        LookPreset.balanced.apply(to: &a)
        XCTAssertFalse(a.cardSheen)
        XCTAssertFalse(a.buttonGlow)
        XCTAssertEqual(a.cardChrome, .shadow)
        LookPreset.aether.apply(to: &a)
        XCTAssertTrue(a.cardSheen)
        XCTAssertTrue(a.buttonGlow)
    }
}
