import XCTest
import AetherCore
@testable import Aether

// The logic behind the filter bar of Search: which choices survive a change of addons, and how the answers of the
// catalogs are filtered, sorted and counted. No views, no network.

private enum SearchTestKit {
    static func extra(_ name: String, required: Bool = false, options: [String] = []) -> ExtraProperty {
        return ExtraProperty(name: name, isRequired: required, options: options)
    }

    static func catalog(_ type: String, _ id: String, extras: [ExtraProperty]) -> ManifestCatalog {
        return ManifestCatalog(type: type, id: id, name: id, extra: extras)
    }

    static func handle(_ name: String, catalogs: [ManifestCatalog]) -> AddonHandle {
        let manifest = AddonManifest(id: "test.\(name)", version: "1.0.0", name: name,
                                     resources: [ManifestResource(name: "catalog")], catalogs: catalogs)
        let addon = InstalledAddon(manifest: manifest, host: "\(name).test", fingerprint: "fp-\(name)")
        let url = URL(string: "https://\(name).test/manifest.json")!
        return AddonHandle(addon: addon, transportURL: url)
    }

    /// Films and series that can be searched (with genres) plus, optionally, an addon with live TV (searchable, with
    /// genres) and sports (browse only).
    static func capabilities(withExtraAddon: Bool) -> CatalogCapabilities {
        let movies = catalog("movie", "top", extras: [
            extra("genre", options: ["Action", "Comedy"]), extra("search"), extra("skip")])
        let series = catalog("series", "top", extras: [
            extra("genre", options: ["Drama", "Action & Adventure"]), extra("search"), extra("skip")])
        var handles: [AddonHandle] = [handle("main", catalogs: [movies, series])]
        if withExtraAddon {
            let tv = catalog("tv", "channels", extras: [
                extra("genre", options: ["News", "Kids"]), extra("search"), extra("skip")])
            let sports = catalog("sports", "events", extras: [
                extra("genre", options: ["Calcio"]), extra("skip")])
            handles.append(handle("extra", catalogs: [tv, sports]))
        }
        return CatalogCapabilities.build(handles: handles, hideAdultCatalogs: true)
    }

    static func item(_ number: Int, type: String = "movie", release: String? = nil, genres: [String] = [],
                     name: String? = nil) -> MetaItem {
        return MetaItem(id: "tt\(1000000 + number)", type: type, name: name ?? "Title \(number)",
                        releaseInfo: release, genres: genres)
    }

    static func result(_ id: String, order: Int, items: [MetaItem], type: String = "movie",
                       hidden: ResultFilterOutcome = ResultFilterOutcome(kept: [])) -> SearchCatalogResult {
        return SearchCatalogResult(id: id, title: "Catalogo \(id)", addonName: "Addon", typeID: type, order: order,
                                   items: items, hiddenByPlan: hidden)
    }

    static func ids(_ items: [MetaItem]) -> [String] {
        return items.map { (item: MetaItem) -> String in item.id }
    }

    static func titles(_ items: [MetaItem]) -> [String] {
        return items.map { (item: MetaItem) -> String in item.name }
    }
}

final class SearchFilterStateTests: XCTestCase {
    func testResetClearsTheFiltersButNotTheSort() {
        var state = SearchFilterState(typeID: "movie", genre: "Action", year: YearFilter.decade(containing: 2020),
                                      sort: SearchSort.title)
        XCTAssertTrue(state.hasActiveFilters)
        state.reset()
        XCTAssertFalse(state.hasActiveFilters)
        XCTAssertNil(state.typeID)
        XCTAssertNil(state.genre)
        XCTAssertNil(state.year)
        XCTAssertEqual(state.sort, SearchSort.title, "sorting never hides anything, so resetting the filters keeps it")
    }

    func testSortAloneIsNotAFilter() {
        let state = SearchFilterState(sort: SearchSort.ratingDescending)
        XCTAssertFalse(state.hasActiveFilters)
    }

    func testChoosingATypeKeepsAGenreThatTypeListsAndFixesItsSpelling() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: false)
        var state = SearchFilterState(genre: "action")
        state.select(type: "movie", capabilities: capabilities)
        XCTAssertEqual(state.typeID, "movie")
        XCTAssertEqual(state.genre, "Action", "the addons' own spelling is used")
    }

    func testChoosingATypeDropsAGenreThatTypeDoesNotList() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: false)
        var state = SearchFilterState(genre: "Comedy")
        state.select(type: "series", capabilities: capabilities)
        XCTAssertEqual(state.typeID, "series")
        XCTAssertNil(state.genre, "series do not list Comedy: the genre is dropped, not silently kept")
    }

    func testAllTypesOfferTheUnionOfTheGenres() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: true)
        var state = SearchFilterState(typeID: "tv", genre: "News")
        state.select(type: nil, capabilities: capabilities)
        XCTAssertNil(state.typeID)
        XCTAssertEqual(state.genre, "News", "with no type chosen every searchable type's genres are offered")
    }

    func testTypeSpellingsAreFoldedOntoTheCanonicalId() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: true)
        var state = SearchFilterState()
        state.select(type: "Sport", capabilities: capabilities)
        XCTAssertEqual(state.typeID, "sports")
    }

    func testATypeNobodyProvidesIsDroppedWhenAddonsChange() {
        let withExtra = SearchTestKit.capabilities(withExtraAddon: true)
        let without = SearchTestKit.capabilities(withExtraAddon: false)
        var state = SearchFilterState(sort: SearchSort.title)
        state.select(type: "tv", capabilities: withExtra)
        state.genre = "Kids"
        XCTAssertEqual(state.typeID, "tv")

        let after = state.reconciled(with: without)
        XCTAssertNil(after.typeID, "the addon that provided TV was removed")
        XCTAssertNil(after.genre, "and its genre went with it")
        XCTAssertEqual(after.sort, SearchSort.title, "unrelated choices are kept")
    }

    func testReconcilingWithUnchangedAddonsChangesNothing() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: true)
        let state = SearchFilterState(typeID: "tv", genre: "Kids", year: YearFilter.decade(containing: 2010),
                                      sort: SearchSort.yearDescending)
        XCTAssertEqual(state.reconciled(with: capabilities), state)
    }

    func testNothingIsKeptWithoutAddons() {
        let state = SearchFilterState(typeID: "movie", genre: "Action")
        let after = state.reconciled(with: CatalogCapabilities.empty)
        XCTAssertNil(after.typeID)
        XCTAssertNil(after.genre)
    }

    func testATypeThatCannotBeSearchedExplainsItself() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: true)
        var state = SearchFilterState()
        state.select(type: "sports", capabilities: capabilities)
        XCTAssertEqual(state.typeID, "sports", "the type exists, it is only not searchable")
        XCTAssertEqual(state.unsupportedTypeNotice(capabilities: capabilities),
                       "Nessun addon installato supporta la ricerca per «Sport».")
        XCTAssertNil(state.genre)
    }

    func testSearchableTypesAndNoTypeHaveNoNotice() {
        let capabilities = SearchTestKit.capabilities(withExtraAddon: true)
        XCTAssertNil(SearchFilterState().unsupportedTypeNotice(capabilities: capabilities))
        XCTAssertNil(SearchFilterState(typeID: "tv").unsupportedTypeNotice(capabilities: capabilities))
        XCTAssertNil(SearchFilterState(typeID: "movie").unsupportedTypeNotice(capabilities: capabilities))
        XCTAssertNil(SearchFilterState(typeID: "ghost").unsupportedTypeNotice(capabilities: capabilities),
                     "an unknown type is reconciled away, it is not announced as unsupported")
    }

    func testGenreMatchingIgnoresCaseAndAccents() {
        XCTAssertEqual(SearchFilterState.matchingGenre("DRAMMATICO", in: ["Commedia", "Drammatico"]), "Drammatico")
        XCTAssertEqual(SearchFilterState.matchingGenre("azione", in: ["Azione"]), "Azione")
        XCTAssertNil(SearchFilterState.matchingGenre("Horror", in: ["Azione"]))
        XCTAssertNil(SearchFilterState.matchingGenre("   ", in: ["Azione"]))
    }
}

final class SearchPresenterTests: XCTestCase {
    private func present(_ results: [SearchCatalogResult], library: [MetaItem] = [],
                         filters: SearchFilterState = SearchFilterState()) -> SearchPresentation {
        return SearchPresenter.present(results: results, library: library, filters: filters)
    }

    func testWithoutFiltersEverythingIsShownAndTheYearMenuOffersTheDecadesPresent() {
        let items = [SearchTestKit.item(1, release: "2021"), SearchTestKit.item(2, release: "2018"),
                     SearchTestKit.item(3, release: "1994"), SearchTestKit.item(4)]
        let presentation = present([SearchTestKit.result("a", order: 0, items: items)])
        XCTAssertEqual(presentation.merged.count, 4)
        XCTAssertEqual(presentation.rows.count, 1)
        let labels = presentation.yearOptions.map { (option: YearFilter) -> String in option.label }
        XCTAssertEqual(labels, ["2020–2029", "2010–2019", "1990–1999"], "newest decade first; items without a year add none")
        XCTAssertNil(presentation.missingDataSummary)
        XCTAssertEqual(presentation.filteredOutCount, 0)
    }

    func testNoYearsInTheResultsMeansNoYearMenu() {
        let presentation = present([SearchTestKit.result("a", order: 0, items: [SearchTestKit.item(1), SearchTestKit.item(2)])])
        XCTAssertTrue(presentation.yearOptions.isEmpty)
    }

    func testYearFilterHidesOtherDecadesAndCountsTheItemsWithoutAYear() {
        let items = [SearchTestKit.item(1, release: "2021"), SearchTestKit.item(2, release: "2018"),
                     SearchTestKit.item(3), SearchTestKit.item(4, release: "2023")]
        var filters = SearchFilterState()
        filters.year = YearFilter.decade(containing: 2020)
        let presentation = present([SearchTestKit.result("a", order: 0, items: items)], filters: filters)

        XCTAssertEqual(SearchTestKit.ids(presentation.merged), ["tt1000001", "tt1000004"])
        XCTAssertEqual(SearchTestKit.ids(presentation.rows[0].items), ["tt1000001", "tt1000004"])
        XCTAssertEqual(presentation.hidden.hiddenWithoutYear, 1)
        XCTAssertEqual(presentation.hidden.hiddenMismatch, 1, "2018 is a mismatch, not missing data")
        XCTAssertEqual(presentation.missingDataSummary, "1 risultato senza anno nascosto")
        XCTAssertEqual(presentation.filteredOutCount, 2)
        XCTAssertEqual(presentation.yearOptions.count, 2, "the menu keeps offering the decades of the unfiltered results")
    }

    func testSeveralCatalogsAreCountedTogether() {
        let first = SearchTestKit.result("a", order: 0, items: [SearchTestKit.item(1, release: "2020"), SearchTestKit.item(2)])
        let second = SearchTestKit.result("b", order: 1, items: [SearchTestKit.item(3), SearchTestKit.item(4), SearchTestKit.item(5, release: "2020")])
        var filters = SearchFilterState()
        filters.year = YearFilter.decade(containing: 2020)
        let presentation = present([first, second], filters: filters)
        XCTAssertEqual(presentation.missingDataSummary, "3 risultati senza anno nascosti")
        XCTAssertEqual(presentation.merged.count, 2)
    }

    func testWhatThePlanHidAddsToTheSummary() {
        let planHidden = ResultFilterOutcome(kept: [], hiddenMissingData: 2, hiddenMismatch: 0,
                                             hiddenWithoutYear: 0, hiddenWithoutGenre: 2, hiddenWithoutRating: 0)
        var filters = SearchFilterState()
        filters.year = YearFilter.decade(containing: 2020)
        let result = SearchTestKit.result("a", order: 0, items: [SearchTestKit.item(1, release: "2021"), SearchTestKit.item(2)],
                                          hidden: planHidden)
        let presentation = present([result], filters: filters)
        XCTAssertEqual(presentation.missingDataSummary, "1 risultato senza anno nascosto · 2 risultati senza genere nascosti")
    }

    func testRowsFollowThePlanOrderNotTheOrderOfArrival() {
        let late = SearchTestKit.result("second", order: 1, items: [SearchTestKit.item(2)])
        let early = SearchTestKit.result("first", order: 0, items: [SearchTestKit.item(1)])
        let presentation = present([late, early])
        XCTAssertEqual(presentation.rows.map { (row: PresentedSearchRow) -> String in row.id }, ["first", "second"])
        XCTAssertEqual(SearchTestKit.ids(presentation.merged), ["tt1000001", "tt1000002"])
    }

    func testCatalogsWithNothingToShowGetNoRow() {
        let empty = SearchTestKit.result("empty", order: 0, items: [])
        let full = SearchTestKit.result("full", order: 1, items: [SearchTestKit.item(1)])
        let presentation = present([empty, full])
        XCTAssertEqual(presentation.rows.map { (row: PresentedSearchRow) -> String in row.id }, ["full"])
    }

    func testTheSameTitleFromTwoCatalogsIsMergedOnce() {
        let shared = SearchTestKit.item(7, release: "2021")
        let first = SearchTestKit.result("a", order: 0, items: [shared, SearchTestKit.item(1, release: "2021")])
        let second = SearchTestKit.result("b", order: 1, items: [shared])
        let presentation = present([first, second])
        XCTAssertEqual(presentation.merged.count, 2)
        XCTAssertEqual(presentation.rows.count, 2, "each catalog still lists its own answer")
    }

    func testSortAppliesToTheMergedRowAndToEveryRow() {
        let items = [SearchTestKit.item(1, release: "2022", name: "Zeta"), SearchTestKit.item(2, release: "2019", name: "Alfa"),
                     SearchTestKit.item(3, release: "2020", name: "Mira")]
        let result = SearchTestKit.result("a", order: 0, items: items)

        var byTitle = SearchFilterState()
        byTitle.sort = SearchSort.title
        let titled = present([result], filters: byTitle)
        XCTAssertEqual(SearchTestKit.titles(titled.merged), ["Alfa", "Mira", "Zeta"])
        XCTAssertEqual(SearchTestKit.titles(titled.rows[0].items), ["Alfa", "Mira", "Zeta"])

        var byYear = SearchFilterState()
        byYear.sort = SearchSort.yearDescending
        let dated = present([result], filters: byYear)
        XCTAssertEqual(SearchTestKit.titles(dated.merged), ["Zeta", "Mira", "Alfa"])
        XCTAssertEqual(SearchTestKit.titles(dated.rows[0].items), ["Zeta", "Mira", "Alfa"])

        let relevance = present([result])
        XCTAssertEqual(SearchTestKit.titles(relevance.merged), ["Zeta", "Alfa", "Mira"], "relevance keeps the addon's order")
    }

    func testRowsAreCappedForDisplay() {
        var items: [MetaItem] = []
        for number in 1...(SearchPresenter.displayLimit + 25) {
            items.append(SearchTestKit.item(number, release: "2020"))
        }
        let presentation = present([SearchTestKit.result("a", order: 0, items: items)])
        XCTAssertEqual(presentation.merged.count, SearchPresenter.displayLimit)
        XCTAssertEqual(presentation.rows[0].items.count, SearchPresenter.displayLimit)
    }

    func testTheYearFilterSeesBeyondTheDisplayCap() {
        var items: [MetaItem] = []
        for number in 1...60 {
            items.append(SearchTestKit.item(number, release: number > 55 ? "1999" : "2020"))
        }
        var filters = SearchFilterState()
        filters.year = YearFilter.decade(containing: 1990)
        let presentation = present([SearchTestKit.result("a", order: 0, items: items)], filters: filters)
        XCTAssertEqual(presentation.merged.count, 5, "the 1990s titles sit after the first 40: the cap applies after the filter")
    }

    func testLibraryMatchesAreFilteredByTypeGenreAndYear() {
        let library = [
            SearchTestKit.item(1, type: "movie", release: "2021", genres: ["Action"]),
            SearchTestKit.item(2, type: "series", release: "2022", genres: ["Action"]),
            SearchTestKit.item(3, type: "movie"),
            SearchTestKit.item(4, type: "movie", release: "1999", genres: ["Action"])
        ]
        var filters = SearchFilterState()
        filters.typeID = "movie"
        filters.genre = "Action"
        filters.year = YearFilter.decade(containing: 2020)
        let presentation = present([], library: library, filters: filters)

        XCTAssertEqual(SearchTestKit.ids(presentation.library), ["tt1000001"])
        XCTAssertEqual(presentation.libraryTypeMismatches, 1, "the series is left out by type")
        XCTAssertEqual(presentation.hidden.hiddenWithoutGenre, 1, "the movie without genres is hidden for missing data")
        XCTAssertEqual(presentation.hidden.hiddenMismatch, 1, "1999 is outside 2020-2029")
        XCTAssertEqual(presentation.missingDataSummary, "1 risultato senza genere nascosto")
        XCTAssertEqual(presentation.filteredOutCount, 3)
    }

    func testFiltersThatHideEverythingAreToldApartFromNoResults() {
        let result = SearchTestKit.result("a", order: 0, items: [SearchTestKit.item(1, release: "2021"), SearchTestKit.item(2, release: "2022")])
        var filters = SearchFilterState()
        filters.year = YearFilter.decade(containing: 1980)
        let hiddenAll = present([result], filters: filters)
        XCTAssertEqual(hiddenAll.visibleCount, 0)
        XCTAssertEqual(hiddenAll.filteredOutCount, 2, "the UI offers to reset the filters")

        let nothing = present([SearchTestKit.result("a", order: 0, items: [])])
        XCTAssertEqual(nothing.visibleCount, 0)
        XCTAssertEqual(nothing.filteredOutCount, 0, "the UI says there are no results at all")
    }

    func testAnActiveYearFilterStaysInTheMenuEvenWhenTheResultsNoLongerHaveIt() {
        var filters = SearchFilterState()
        filters.year = YearFilter.decade(containing: 1970)
        let presentation = present([SearchTestKit.result("a", order: 0, items: [SearchTestKit.item(1, release: "2021")])], filters: filters)
        let options = YearBuckets.menuOptions(presentation.yearOptions, selected: filters.year)
        XCTAssertEqual(options.map { (option: YearFilter) -> String in option.label }, ["2020–2029", "1970–1979"])
    }
}

final class YearBucketsTests: XCTestCase {
    func testDecadesAreNewestFirstAndSkipItemsWithoutYear() {
        let items = [SearchTestKit.item(1, release: "2011–2019"), SearchTestKit.item(2, release: "1987"),
                     SearchTestKit.item(3, release: "N/A"), SearchTestKit.item(4, release: "2024")]
        let decades = YearBuckets.decades(in: items)
        XCTAssertEqual(decades.map { (option: YearFilter) -> String in option.label }, ["2020–2029", "2010–2019", "1980–1989"])
    }

    func testKeysRoundTrip() {
        let options = [YearFilter.decade(containing: 2020), YearFilter.decade(containing: 2010)]
        for option in options {
            XCTAssertEqual(YearBuckets.filter(forKey: YearBuckets.key(option), in: options), option)
        }
        XCTAssertEqual(YearBuckets.key(nil), YearBuckets.allKey)
        XCTAssertNil(YearBuckets.filter(forKey: YearBuckets.allKey, in: options))
        XCTAssertNil(YearBuckets.filter(forKey: "1800-1809", in: options))
    }

    func testOpenEndedFiltersHaveDistinctKeys() {
        XCTAssertNotEqual(YearBuckets.key(YearFilter.since(2000)), YearBuckets.key(YearFilter.through(2000)))
        XCTAssertNotEqual(YearBuckets.key(YearFilter.since(2000)), YearBuckets.key(YearFilter.exact(2000)))
    }

    func testMenuOptionsAddTheSelectionOnlyWhenMissing() {
        let decades = [YearFilter.decade(containing: 2020), YearFilter.decade(containing: 2000)]
        XCTAssertEqual(YearBuckets.menuOptions(decades, selected: nil), decades)
        XCTAssertEqual(YearBuckets.menuOptions(decades, selected: YearFilter.decade(containing: 2000)), decades)
        let withExtra = YearBuckets.menuOptions(decades, selected: YearFilter.decade(containing: 2010))
        XCTAssertEqual(withExtra.map { (option: YearFilter) -> String in option.label }, ["2020–2029", "2010–2019", "2000–2009"])
    }
}
