import XCTest
import SwiftUI
import AetherCore
@testable import Aether

final class AetherStyleTests: XCTestCase {
    func testDefaultStyleIsTheOneDotZeroLook() {
        let style = AetherStyle(AppearanceSettings())
        XCTAssertEqual(style, AetherStyle())
        XCTAssertEqual(style.posterRadius, 14)
        XCTAssertEqual(style.landscapeRadius, 16, "the radius of the Continue Watching card in 1.0")
        XCTAssertEqual(style.thumbnailRadius, 12, "the radius of the next-episode thumbnail in 1.0")
        XCTAssertEqual(style.glassCardRadius, 18, "the radius of the next-episode card in 1.0")
        XCTAssertEqual(style.heroRadius, 28, "the radius of the featured card in 1.0")
    }

    func testRadiiFollowTheCornerChoice() {
        for corner in CornerStyle.allCases {
            var appearance = AppearanceSettings()
            appearance.cornerStyle = corner
            let style = AetherStyle(appearance)
            XCTAssertEqual(style.posterRadius, CGFloat(corner.radius))
            XCTAssertGreaterThanOrEqual(style.thumbnailRadius, 2)
            XCTAssertLessThanOrEqual(style.heroRadius, 36)
            XCTAssertGreaterThan(style.landscapeRadius, style.posterRadius)
        }
    }

    func testStyleCarriesTheOtherChoices() {
        var appearance = AppearanceSettings()
        appearance.palette = .ocean
        appearance.backdrop = .flow
        appearance.cardChrome = .glow
        appearance.titleFont = .serif
        let style = AetherStyle(appearance)
        XCTAssertEqual(style.palette, .ocean)
        XCTAssertEqual(style.backdrop, .flow)
        XCTAssertEqual(style.chrome, .glow)
        XCTAssertEqual(style.titleFont, .serif)
    }

    func testEveryTitleFontMapsToADistinctDesign() {
        let designs = TitleFont.allCases.map { AetherTypography.fontDesign(for: $0) }
        XCTAssertEqual(Set(designs.map { "\($0)" }).count, TitleFont.allCases.count)
        XCTAssertEqual(AetherTypography.fontDesign(for: .rounded), .rounded)
    }
}

final class HomeCardMetricsTests: XCTestCase {
    func testPosterWidthsAreTheGeneralPosterSizes() {
        for size in PosterSize.allCases {
            XCTAssertEqual(HomeCardMetrics.width(style: .poster, size: size), CGFloat(size.rowWidth))
        }
    }

    func testWideCardsDefaultToTheContinueWatchingWidth() {
        XCTAssertEqual(HomeCardMetrics.width(style: .landscape, size: .medium), 240)
        XCTAssertEqual(HomeCardMetrics.width(style: .compact, size: .medium), 240)
    }

    func testWideCardsAreWiderThanPostersAndGrowWithTheSize() {
        for size in PosterSize.allCases {
            XCTAssertGreaterThan(HomeCardMetrics.width(style: .landscape, size: size), HomeCardMetrics.width(style: .poster, size: size))
        }
        XCTAssertLessThan(HomeCardMetrics.width(style: .landscape, size: .small), HomeCardMetrics.width(style: .landscape, size: .large))
    }

    /// At least one and a half wide cards must be visible at the largest size on the narrowest iPhone, so a swipe is the obvious
    /// next gesture and the row does not look like a single oversized card.
    func testTheLargestWideCardLeavesRoomForTheNextOne() {
        let narrowest: CGFloat = 320
        XCTAssertLessThan(HomeCardMetrics.width(style: .landscape, size: .large), narrowest - 16 - 14)
    }

    func testAspectRatios() {
        XCTAssertEqual(HomeCardMetrics.aspectRatio(style: .poster), 0.675, accuracy: 0.0001)
        XCTAssertEqual(HomeCardMetrics.aspectRatio(style: .landscape), 16.0 / 9.0, accuracy: 0.0001)
    }
}

@MainActor
final class AppearanceStoreTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "aether.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    override func tearDown() {
        AetherTypography.design = .rounded
        super.tearDown()
    }

    func testNewChoicesPersistAcrossInstances() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.appearance.heroStyle = .fullBleed
        store.value.appearance.palette = .sunset
        store.value.appearance.backdrop = .spotlight
        store.value.appearance.cardChrome = .outline
        store.value.appearance.cornerStyle = .bubble
        store.value.appearance.homeSections[3].style = .landscape
        store.value.appearance.homeSections[3].size = .large
        store.value.appearance.homeSections = HomeSectionOrdering.moved(store.value.appearance.homeSections, id: "catalogs", by: -4)

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.value.appearance.heroStyle, .fullBleed)
        XCTAssertEqual(reloaded.value.appearance.palette, .sunset)
        XCTAssertEqual(reloaded.value.appearance.backdrop, .spotlight)
        XCTAssertEqual(reloaded.value.appearance.cardChrome, .outline)
        XCTAssertEqual(reloaded.value.appearance.cornerStyle, .bubble)
        XCTAssertEqual(reloaded.value.appearance.homeSections.first?.id, "catalogs")
        XCTAssertEqual(reloaded.value.appearance.section("watchlist").style, .landscape)
        XCTAssertEqual(reloaded.value.appearance.section("watchlist").size, .large)
    }

    /// A settings file written by 1.0, with the section list in the old shape, keeps the viewer's order and hidden sections.
    func testSettingsStoredByOneDotZeroAreReadBack() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"{"appearance":{"accent":"jade","homeSections":[{"id":"watchlist","isVisible":true},{"id":"hero","isVisible":false},{"id":"continue","isVisible":true},{"id":"nextUp","isVisible":true},{"id":"catalogs","isVisible":true}]}}"#
        defaults.set(Data(old.utf8), forKey: "aether.settings.v1")
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.value.appearance.accent, .jade)
        XCTAssertEqual(store.value.appearance.homeSections.map { $0.id }, ["watchlist", "hero", "continue", "nextUp", "catalogs"])
        XCTAssertEqual(store.value.appearance.section("hero").isVisible, false)
    }

    func testAnUnlockedSecretPersistsAndResetLocksItAgain() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var appearance = store.value.appearance
        XCTAssertTrue(appearance.unlock(.popcorn))
        appearance.palette = .popcorn
        store.value.appearance = appearance

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.value.appearance.isUnlocked(.popcorn))
        XCTAssertEqual(reloaded.value.appearance.palette, .popcorn)

        reloaded.resetToDefaults()
        XCTAssertFalse(reloaded.value.appearance.isUnlocked(.popcorn))
        XCTAssertEqual(SettingsStore(defaults: defaults).value.appearance.palette, .aether)
    }

    func testTheTitleFontIsAppliedAtOnce() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.appearance.titleFont = .serif
        XCTAssertEqual(AetherTypography.design, .serif)
        store.value.appearance.titleFont = .rounded
        XCTAssertEqual(AetherTypography.design, .rounded)
    }

    func testTheSavedTitleFontIsAppliedAtLaunch() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = SettingsStore(defaults: defaults)
        first.value.appearance.titleFont = .mono
        AetherTypography.design = .rounded
        _ = SettingsStore(defaults: defaults)
        XCTAssertEqual(AetherTypography.design, .monospaced)
    }
}
