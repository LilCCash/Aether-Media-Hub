import XCTest
@testable import AetherCore

final class GlassHomeTests: XCTestCase {
    func testDefaultsAreTheClassicHomeAndFourCategories() {
        let appearance = AppearanceSettings()
        XCTAssertEqual(appearance.homeLayout, .classic)
        let visible = appearance.glassHome.categories.filter { $0.isVisible }.map { $0.title }
        XCTAssertEqual(visible, ["Film", "Serie TV", "Anime", "Live TV"])
        XCTAssertEqual(appearance.glassHome.sections.first?.id, HomeSectionConfig.hero, "«In evidenza» opens the page when switched on")
        XCTAssertEqual(appearance.glassHome.sections.first(where: { $0.id == HomeSectionConfig.hero })?.isVisible, false)
        XCTAssertEqual(appearance.glassHome.sections.map { $0.id }.prefix(3), [HomeSectionConfig.hero, GlassHomeSettings.search, GlassHomeSettings.categoriesID])
        XCTAssertEqual(HomeLayout.glass.title, "Vetrina")
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
        XCTAssertEqual(sections.map { $0.id }.prefix(2), [HomeSectionConfig.hero, "catalogs"], "a missing «In evidenza» goes on top")
        XCTAssertEqual(sections.count, GlassHomeSettings.defaultSections.count)
    }

    func testFeaturedSectionLeftAtTheBottomByOlderVersionsMovesToTheTop() {
        // What older versions stored: «In evidenza» appended after every other section, then switched on by the viewer.
        var stored = GlassHomeSettings.defaultSections.filter { $0.id != HomeSectionConfig.hero }
        stored.append(HomeSectionConfig(id: HomeSectionConfig.hero, isVisible: true))
        let sections = GlassHomeSettings.normalise(stored)
        XCTAssertEqual(sections.first?.id, HomeSectionConfig.hero)
        XCTAssertEqual(sections.first?.isVisible, true, "the choice is kept, only the place changes")
        // A place the viewer chose in the middle is respected.
        var middle = GlassHomeSettings.defaultSections
        middle.swapAt(0, 3)
        XCTAssertEqual(GlassHomeSettings.normalise(middle).map(\.id), middle.map(\.id))
    }
}
