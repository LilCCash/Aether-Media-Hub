import XCTest
import AetherCore
@testable import Aether

// The logic behind Discover's filters and the Settings > Scopri page: what a catalog's `genre` extra means, which
// catalogs need a year to be listed, how the loaded titles are filtered by year, and how types are reordered.

private enum DiscoverTestKit {
    static func extra(_ name: String, required: Bool = false, options: [String] = []) -> ExtraProperty {
        return ExtraProperty(name: name, isRequired: required, options: options)
    }

    static func catalog(_ type: String, _ id: String, extras: [ExtraProperty]) -> ManifestCatalog {
        return ManifestCatalog(type: type, id: id, name: id, extra: extras)
    }

    static func handle(_ name: String, catalogs: [ManifestCatalog], adult: Bool = false, enabled: Bool = true,
                       hidden: [String] = []) -> AddonHandle {
        let manifest = AddonManifest(id: "test.\(name)", version: "1.0.0", name: name,
                                     resources: [ManifestResource(name: "catalog")], catalogs: catalogs,
                                     behaviorHints: ManifestBehaviorHints(adult: adult))
        let addon = InstalledAddon(manifest: manifest, host: "\(name).test", fingerprint: "fp-\(name)",
                                   isEnabled: enabled, hiddenCatalogs: hidden)
        let url = URL(string: "https://\(name).test/manifest.json")!
        return AddonHandle(addon: addon, transportURL: url)
    }

    /// The shape of the official Cinemeta manifest (API probe 2026-10-20): a browsable `top`, a `year` catalog whose
    /// required `genre` is a list of years, and `last-videos` that needs ids Discover cannot supply.
    static func cinemetaLike(_ name: String = "cinemeta", adult: Bool = false, enabled: Bool = true,
                             hidden: [String] = []) -> AddonHandle {
        let top = catalog("movie", "top", extras: [
            extra("genre", options: ["Action", "Comedy"]), extra("search"), extra("skip")])
        let year = catalog("movie", "year", extras: [
            extra("genre", required: true, options: ["2024", "2026", "2025"]), extra("skip")])
        let lastVideos = catalog("movie", "last-videos", extras: [extra("lastVideosIds", required: true)])
        let seriesTop = catalog("series", "top", extras: [extra("genre", options: ["Drama"]), extra("skip")])
        return handle(name, catalogs: [top, year, lastVideos, seriesTop], adult: adult, enabled: enabled, hidden: hidden)
    }

    static func item(_ number: Int, release: String? = nil) -> MetaItem {
        return MetaItem(id: "tt\(2000000 + number)", type: "movie", name: "Title \(number)", releaseInfo: release)
    }

    static func keys(_ refs: [CatalogRef]) -> [String] {
        return refs.map { (ref: CatalogRef) -> String in ref.catalog.key }
    }

    static func ids(_ items: [MetaItem]) -> [String] {
        return items.map { (item: MetaItem) -> String in item.id }
    }
}

final class DiscoverServerFilterTests: XCTestCase {
    func testACatalogWithoutGenreHasNoServerFilter() {
        let catalog = DiscoverTestKit.catalog("movie", "plain", extras: [DiscoverTestKit.extra("skip")])
        XCTAssertNil(DiscoverFiltering.serverFilter(for: catalog))
    }

    func testOptionalGenresAreOfferedWithTheAddonsOwnSpelling() {
        let catalog = DiscoverTestKit.catalog("movie", "top", extras: [
            DiscoverTestKit.extra("genre", options: ["Action", "Sci-Fi", "action", " "]), DiscoverTestKit.extra("skip")])
        guard let filter = DiscoverFiltering.serverFilter(for: catalog) else {
            XCTFail("a genre list was declared")
            return
        }
        XCTAssertEqual(filter.kind, DiscoverServerFilter.Kind.genre)
        XCTAssertEqual(filter.options, ["Action", "Sci-Fi", "action"], "blank options are dropped, spellings are not rewritten")
        XCTAssertFalse(filter.isRequired)
        XCTAssertEqual(filter.title, "Genere")
        XCTAssertEqual(filter.allTitle, "Tutti i generi")
    }

    func testAGenreExtraWithoutOptionsOffersNothing() {
        let catalog = DiscoverTestKit.catalog("movie", "free", extras: [DiscoverTestKit.extra("genre")])
        XCTAssertNil(DiscoverFiltering.serverFilter(for: catalog), "free text cannot be turned into a menu")
    }

    func testAListOfYearsIsAYearFilterNewestFirst() {
        let catalog = DiscoverTestKit.catalog("movie", "year", extras: [
            DiscoverTestKit.extra("genre", required: true, options: ["2024", "2026", "2025"])])
        guard let filter = DiscoverFiltering.serverFilter(for: catalog) else {
            XCTFail("a year list was declared")
            return
        }
        XCTAssertEqual(filter.kind, DiscoverServerFilter.Kind.year)
        XCTAssertEqual(filter.options, ["2026", "2025", "2024"])
        XCTAssertTrue(filter.isRequired)
        XCTAssertEqual(filter.title, "Anno")
        XCTAssertEqual(filter.allTitle, "Tutti gli anni")
    }

    func testAnOptionalYearListIsStillAYearFilter() {
        let catalog = DiscoverTestKit.catalog("movie", "year", extras: [
            DiscoverTestKit.extra("genre", options: ["1999", "2001"])])
        let filter = DiscoverFiltering.serverFilter(for: catalog)
        XCTAssertEqual(filter?.kind, DiscoverServerFilter.Kind.year)
        XCTAssertEqual(filter?.isRequired, false)
    }

    func testARequiredListOfGenreNamesCannotBeBrowsed() {
        let catalog = DiscoverTestKit.catalog("movie", "pick", extras: [
            DiscoverTestKit.extra("genre", required: true, options: ["Action", "Comedy"])])
        XCTAssertNil(DiscoverFiltering.serverFilter(for: catalog))
    }

    func testNumbersThatAreNotYearsStayGenres() {
        let catalog = DiscoverTestKit.catalog("movie", "mixed", extras: [
            DiscoverTestKit.extra("genre", options: ["2024", "Drama"])])
        XCTAssertEqual(DiscoverFiltering.serverFilter(for: catalog)?.kind, DiscoverServerFilter.Kind.genre)
        XCTAssertNil(DiscoverFiltering.sortedYears(["2024", "Drama"]))
        XCTAssertNil(DiscoverFiltering.sortedYears(["1080", "2160"]), "1080 and 2160 are resolutions, not release years")
        XCTAssertNil(DiscoverFiltering.sortedYears([]))
    }

    func testDefaultSelectionIsTheNewestYearOfAMandatoryList() {
        let mandatory = DiscoverServerFilter(kind: .year, options: ["2026", "2025"], isRequired: true)
        let optional = DiscoverServerFilter(kind: .year, options: ["2026", "2025"], isRequired: false)
        let genres = DiscoverServerFilter(kind: .genre, options: ["Action"], isRequired: false)
        XCTAssertEqual(DiscoverFiltering.defaultSelection(for: mandatory), "2026")
        XCTAssertNil(DiscoverFiltering.defaultSelection(for: optional))
        XCTAssertNil(DiscoverFiltering.defaultSelection(for: genres))
        XCTAssertNil(DiscoverFiltering.defaultSelection(for: nil))
    }
}

final class DiscoverYearCatalogTests: XCTestCase {
    func testOnlyTheCatalogWhoseRequiredGenreIsAYearListIsAdded() {
        let handles = [DiscoverTestKit.cinemetaLike()]
        let movies = DiscoverFiltering.yearCatalogs(handles: handles, typeID: "movie", hideAdultCatalogs: true)
        XCTAssertEqual(DiscoverTestKit.keys(movies), ["movie/year"],
                       "top is a plain feed already, last-videos needs ids nobody can supply")
        XCTAssertTrue(DiscoverFiltering.yearCatalogs(handles: handles, typeID: "series", hideAdultCatalogs: true).isEmpty)
        XCTAssertTrue(DiscoverFiltering.yearCatalogs(handles: handles, typeID: "tv", hideAdultCatalogs: true).isEmpty)
    }

    func testThePlainFeedsStayWithCapabilitiesAndTheYearCatalogComesOnTop() {
        let handles = [DiscoverTestKit.cinemetaLike()]
        let capabilities = CatalogCapabilities.build(handles: handles, hideAdultCatalogs: true)
        XCTAssertEqual(DiscoverTestKit.keys(capabilities.catalogsToBrowse(forType: "movie")), ["movie/top"],
                       "Core does not list the year catalog by itself")
        let extra = DiscoverFiltering.yearCatalogs(handles: handles, typeID: "movie", hideAdultCatalogs: true)
        XCTAssertEqual(DiscoverTestKit.keys(extra), ["movie/year"])
    }

    func testDisabledAdultAndHiddenCatalogsAreLeftOut() {
        let disabled = DiscoverFiltering.yearCatalogs(handles: [DiscoverTestKit.cinemetaLike(enabled: false)],
                                                      typeID: "movie", hideAdultCatalogs: true)
        XCTAssertTrue(disabled.isEmpty)

        let adult = DiscoverTestKit.cinemetaLike(adult: true)
        XCTAssertTrue(DiscoverFiltering.yearCatalogs(handles: [adult], typeID: "movie", hideAdultCatalogs: true).isEmpty)
        XCTAssertEqual(DiscoverFiltering.yearCatalogs(handles: [adult], typeID: "movie", hideAdultCatalogs: false).count, 1,
                       "the setting is honoured, not the manifest alone")

        let hidden = DiscoverTestKit.cinemetaLike(hidden: ["movie/year"])
        XCTAssertTrue(DiscoverFiltering.yearCatalogs(handles: [hidden], typeID: "movie", hideAdultCatalogs: true).isEmpty)
    }

    func testAYearCatalogThatAlsoNeedsAnotherExtraCannotBeListed() {
        let both = DiscoverTestKit.catalog("movie", "both", extras: [
            DiscoverTestKit.extra("genre", required: true, options: ["2025", "2024"]),
            DiscoverTestKit.extra("region", required: true)])
        let handle = DiscoverTestKit.handle("odd", catalogs: [both])
        XCTAssertTrue(DiscoverFiltering.yearCatalogs(handles: [handle], typeID: "movie", hideAdultCatalogs: true).isEmpty)
    }

    func testTypesAreMatchedBySpellingInsensitively() {
        let year = DiscoverTestKit.catalog("Sport", "by-year", extras: [
            DiscoverTestKit.extra("genre", required: true, options: ["2024", "2023"])])
        let handle = DiscoverTestKit.handle("sportsaddon", catalogs: [year])
        XCTAssertEqual(DiscoverFiltering.yearCatalogs(handles: [handle], typeID: "sports", hideAdultCatalogs: true).count, 1)
    }
}

final class DiscoverGridStateTests: XCTestCase {
    private func sample() -> [MetaItem] {
        return [DiscoverTestKit.item(1, release: "2021"), DiscoverTestKit.item(2, release: "2015"),
                DiscoverTestKit.item(3), DiscoverTestKit.item(4, release: "2024")]
    }

    func testWithoutAYearChoiceEverythingIsShownAndTheDecadesAreOffered() {
        let state = DiscoverFiltering.gridState(items: sample(), year: nil, usesLocalYear: true)
        XCTAssertEqual(state.items.count, 4)
        XCTAssertEqual(state.yearOptions.map { (option: YearFilter) -> String in option.label }, ["2020–2029", "2010–2019"])
        XCTAssertNil(state.hiddenSummary)
        XCTAssertEqual(state.hiddenCount, 0)
    }

    func testTheLocalYearFilterHidesAndCounts() {
        let state = DiscoverFiltering.gridState(items: sample(), year: YearFilter.decade(containing: 2020), usesLocalYear: true)
        XCTAssertEqual(DiscoverTestKit.ids(state.items), ["tt2000001", "tt2000004"])
        XCTAssertEqual(state.hiddenSummary, "1 risultato senza anno nascosto")
        XCTAssertEqual(state.hiddenCount, 2, "one outside the decade, one without a year")
        XCTAssertEqual(state.yearOptions.count, 2, "the menu still offers the decades of everything loaded")
    }

    func testWhenTheYearIsChosenOnTheServerNothingIsFilteredHere() {
        let state = DiscoverFiltering.gridState(items: sample(), year: YearFilter.decade(containing: 2020), usesLocalYear: false)
        XCTAssertEqual(state.items.count, 4)
        XCTAssertTrue(state.yearOptions.isEmpty)
        XCTAssertNil(state.hiddenSummary)
    }

    func testNoItemsMeansNoOptions() {
        let state = DiscoverFiltering.gridState(items: [], year: nil, usesLocalYear: true)
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertTrue(state.yearOptions.isEmpty)
    }
}

final class DiscoverTypeOrderingTests: XCTestCase {
    private func state() -> DiscoverLayoutState {
        // "sports" is remembered from an addon that is gone: it sits between two available types and must stay there.
        let stored = [DiscoverTypeSetting(id: "movie"), DiscoverTypeSetting(id: "sports"),
                      DiscoverTypeSetting(id: "series"), DiscoverTypeSetting(id: "tv", isVisible: false)]
        return DiscoverLayout.normalise(stored: stored, available: ["movie", "series", "tv"])
    }

    private func ids(_ settings: [DiscoverTypeSetting]) -> [String] {
        return settings.map { (setting: DiscoverTypeSetting) -> String in setting.id }
    }

    func testMovingDownSwapsWithTheNextAvailableType() {
        let moved = DiscoverTypeOrdering.moved(state(), id: "movie", by: 1)
        XCTAssertEqual(ids(moved.exposed), ["series", "movie", "tv"])
    }

    func testMovingUpSwapsWithThePreviousAvailableType() {
        let moved = DiscoverTypeOrdering.moved(state(), id: "tv", by: -1)
        XCTAssertEqual(ids(moved.exposed), ["movie", "tv", "series"])
        XCTAssertFalse(moved.isVisible("tv"), "visibility travels with the type")
    }

    func testTheEndsCannotMoveFurther() {
        let original = state()
        XCTAssertEqual(DiscoverTypeOrdering.moved(original, id: "movie", by: -1), original)
        XCTAssertEqual(DiscoverTypeOrdering.moved(original, id: "tv", by: 1), original)
    }

    func testAnUnavailableOrUnknownTypeIsNotMoved() {
        let original = state()
        XCTAssertEqual(DiscoverTypeOrdering.moved(original, id: "sports", by: 1), original)
        XCTAssertEqual(DiscoverTypeOrdering.moved(original, id: "ghost", by: -1), original)
    }

    func testRememberedTypesStayInTheStoredList() {
        let moved = DiscoverTypeOrdering.moved(state(), id: "series", by: -1)
        XCTAssertTrue(ids(moved.entries).contains("sports"), "a removed addon's choice is not forgotten")
        XCTAssertEqual(ids(moved.exposed), ["series", "movie", "tv"])
    }

    func testTheKeyboardAndTheDragGiveTheSameOrder() {
        // Dragging "movie" below "series" is onMove(source: 0, destination: 2); the accessibility action must agree.
        var dragged = state()
        dragged.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let stepped = DiscoverTypeOrdering.moved(state(), id: "movie", by: 1)
        XCTAssertEqual(ids(stepped.exposed), ids(dragged.exposed))
    }
}
