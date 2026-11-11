import XCTest
@testable import AetherCore

final class GlassHomeTests: XCTestCase {
    func testDefaultsAreTheClassicHomeAndFourCategories() {
        let appearance = AppearanceSettings()
        XCTAssertEqual(appearance.homeLayout, .classic)
        let visible = appearance.glassHome.categories.filter { $0.isVisible }.map { $0.title }
        XCTAssertEqual(visible, ["Film", "Serie TV", "Anime", "Live TV"])
        XCTAssertEqual(appearance.glassHome.sections.first?.id, GlassHomeSettings.search)
        XCTAssertEqual(appearance.glassHome.sections.first(where: { $0.id == HomeSectionConfig.hero })?.isVisible, false)
    }

    func testAnOlderInstallWithoutTheGlassHomeKeepsTheClassicOne() throws {
        let json = #"{"schema":2,"theme":"dark","homeSections":[{"id":"catalogs"},{"id":"hero","isVisible":false}]}"#
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.homeLayout, .classic)
        XCTAssertEqual(decoded.glassHome, GlassHomeSettings())
        XCTAssertEqual(decoded.homeSections.first?.id, "catalogs")
    }

    func testChoicesSurviveARoundTrip() throws {
        var appearance = AppearanceSettings()
        appearance.homeLayout = .glass
        appearance.glassHome.showAvatar = false
        appearance.glassHome.categories[0].title = "Cinema"
        appearance.glassHome.categories[0].symbol = "popcorn"
        appearance.glassHome.categories.swapAt(0, 3)
        appearance.glassHome.sections.swapAt(0, 2)
        appearance.glassHome.sections[1].isVisible = false
        let data = try JSONEncoder().encode(appearance)
        let decoded = try JSONDecoder().decode(AppearanceSettings.self, from: data)
        XCTAssertEqual(decoded.homeLayout, .glass)
        XCTAssertEqual(decoded.glassHome, appearance.glassHome)
    }

    func testUnknownAndDuplicateEntriesAreDroppedAndNewOnesAppendedHidden() {
        let stored = [HomeCategory(id: "live", title: "  TV  ", symbol: "tv"), HomeCategory(id: "live", title: "x", symbol: "x"),
                      HomeCategory(id: "nope", title: "?", symbol: "?"), HomeCategory(id: "movie", title: "", symbol: "film")]
        let result = HomeCategory.normalise(stored)
        XCTAssertEqual(result.prefix(2).map { $0.id }, ["live", "movie"])
        XCTAssertEqual(result[0].title, "TV")
        XCTAssertEqual(result[1].title, "Film")
        XCTAssertEqual(Set(result.map { $0.id }).count, result.count)
        XCTAssertFalse(result.contains { $0.id == "nope" })
        XCTAssertTrue(result.dropFirst(2).allSatisfy { !$0.isVisible })
        let sections = GlassHomeSettings.normalise([HomeSectionConfig(id: "catalogs"), HomeSectionConfig(id: "nope")])
        XCTAssertEqual(sections.first?.id, "catalogs")
        XCTAssertEqual(sections.count, GlassHomeSettings.defaultSections.count)
    }
}
