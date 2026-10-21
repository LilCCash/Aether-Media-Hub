import XCTest
@testable import AetherCore

// Content types, capabilities, search plans, local result filters and the Discover layout. Everything except
// `PlannedSearchTests` is pure: manifests are built in memory, no HTTP is involved.

// MARK: - Test kit

private enum CatalogKit {
    static func extra(_ name: String, required: Bool = false, options: [String] = []) -> ExtraProperty {
        return ExtraProperty(name: name, isRequired: required, options: options)
    }

    static func catalog(_ type: String, _ id: String, extras: [ExtraProperty] = []) -> ManifestCatalog {
        return ManifestCatalog(type: type, id: id, name: id, extra: extras)
    }

    static func handle(_ name: String, catalogs: [ManifestCatalog], adult: Bool = false, enabled: Bool = true,
                       needsReinstall: Bool = false, hidden: [String] = []) -> AddonHandle {
        let manifest = AddonManifest(id: "test.\(name)", version: "1.0.0", name: name,
                                     resources: [ManifestResource(name: "catalog")], catalogs: catalogs,
                                     behaviorHints: ManifestBehaviorHints(adult: adult))
        let addon = InstalledAddon(manifest: manifest, host: "\(name).test", fingerprint: "fp-\(name)",
                                   isEnabled: enabled, hiddenCatalogs: hidden, needsReinstall: needsReinstall)
        let url = URL(string: "https://\(name).test/manifest.json")!
        return AddonHandle(addon: addon, transportURL: url)
    }

    /// The shape of the official Cinemeta manifest as the API probe of 2026-10-20 observed it: browsable `top` and
    /// `imdbRating`, `year` whose required `genre` is a list of years, and `last-videos` needing an id list.
    static func cinemetaLike(_ name: String = "cinemeta") -> AddonHandle {
        let movieTop = catalog("movie", "top", extras: [
            extra("genre", options: ["Action", "Comedy", "Drama"]), extra("search"), extra("skip")])
        let seriesTop = catalog("series", "top", extras: [
            extra("genre", options: ["Action & Adventure", "Drama"]), extra("search"), extra("skip")])
        let movieYear = catalog("movie", "year", extras: [
            extra("genre", required: true, options: ["2026", "2025", "2024"]), extra("skip")])
        let movieRated = catalog("movie", "imdbRating", extras: [
            extra("genre", options: ["Action", "Horror"]), extra("skip")])
        let lastVideos = catalog("movie", "last-videos", extras: [extra("lastVideosIds", required: true)])
        return handle(name, catalogs: [movieTop, seriesTop, movieYear, movieRated, lastVideos])
    }

    static func item(_ id: String, release: String? = nil, genres: [String] = [], rating: String? = nil) -> MetaItem {
        return MetaItem(id: id, type: "movie", name: "Title \(id)", releaseInfo: release, imdbRating: rating,
                        genres: genres)
    }

    static func metaJSON(_ id: String, release: String? = nil, genres: [String]? = nil) -> String {
        var parts: [String] = ["\"id\":\"\(id)\"", "\"type\":\"movie\"", "\"name\":\"Title \(id)\""]
        if let release = release {
            parts.append("\"releaseInfo\":\"\(release)\"")
        }
        if let genres = genres {
            let quoted: [String] = genres.map { (genre: String) -> String in "\"\(genre)\"" }
            parts.append("\"genres\":[\(quoted.joined(separator: ","))]")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func catalogJSON(_ metas: [String]) -> String {
        return "{\"metas\":[" + metas.joined(separator: ",") + "]}"
    }

    static func ids(_ settings: [DiscoverTypeSetting]) -> [String] {
        return settings.map { (setting: DiscoverTypeSetting) -> String in setting.id }
    }

    static func typeIDs(_ types: [CatalogTypeCapability]) -> [String] {
        return types.map { (type: CatalogTypeCapability) -> String in type.id }
    }

    static func keys(_ refs: [CatalogRef]) -> [String] {
        return refs.map { (ref: CatalogRef) -> String in ref.catalog.key }
    }

    static func itemIDs(_ items: [MetaItem]) -> [String] {
        return items.map { (item: MetaItem) -> String in item.id }
    }
}

// MARK: - Content types

final class ContentTypesTests: XCTestCase {
    private struct Row {
        var id: String
        var title: String
        var symbol: String
    }

    func testKnownTypesHaveItalianNamesAndSymbols() {
        let rows: [Row] = [
            Row(id: "movie", title: "Film", symbol: "film"),
            Row(id: "series", title: "Serie TV", symbol: "tv"),
            Row(id: "anime", title: "Anime", symbol: "sparkles"),
            Row(id: "tv", title: "TV in diretta", symbol: "antenna.radiowaves.left.and.right"),
            Row(id: "channel", title: "Canali", symbol: "play.rectangle"),
            Row(id: "sports", title: "Sport", symbol: "sportscourt"),
            Row(id: "sport", title: "Sport", symbol: "sportscourt"),
            Row(id: "events", title: "Eventi", symbol: "calendar"),
            Row(id: "event", title: "Eventi", symbol: "calendar"),
            Row(id: "music", title: "Musica", symbol: "music.note"),
            Row(id: "radio", title: "Radio", symbol: "radio"),
            Row(id: "podcast", title: "Podcast", symbol: "mic"),
            Row(id: "other", title: "Altro", symbol: "square.grid.2x2")
        ]
        for row in rows {
            let info = ContentTypes.info(for: row.id)
            XCTAssertEqual(info.title, row.title, row.id)
            XCTAssertEqual(info.symbolName, row.symbol, row.id)
            XCTAssertTrue(info.isKnown, row.id)
            XCTAssertEqual(info.id, row.id, "the id is never rewritten")
            XCTAssertEqual(ContentTypes.title(for: row.id), row.title)
            XCTAssertEqual(ContentTypes.symbolName(for: row.id), row.symbol)
        }
    }

    func testCanonicalOrderAndRanks() {
        XCTAssertEqual(ContentTypes.canonicalOrder,
                       ["movie", "series", "anime", "tv", "channel", "sports", "events", "music", "radio",
                        "podcast", "other"])
        XCTAssertEqual(ContentTypes.rank(of: "movie"), 0)
        XCTAssertEqual(ContentTypes.rank(of: "sport"), ContentTypes.rank(of: "sports"), "aliases share a position")
        XCTAssertEqual(ContentTypes.rank(of: "other"), 10)
        XCTAssertEqual(ContentTypes.rank(of: "games"), 11, "unknown types come after every known one")
    }

    func testLookupIsCaseInsensitiveButKeepsTheCallersSpelling() {
        let info = ContentTypes.info(for: "  Movie ")
        XCTAssertEqual(info.title, "Film")
        XCTAssertEqual(info.id, "  Movie ", "requests must use the addon's own spelling")
        XCTAssertEqual(ContentTypes.canonicalID("  Movie "), "movie")
        XCTAssertEqual(ContentTypes.canonicalID("SPORT"), "sports")
        XCTAssertEqual(ContentTypes.canonicalID("Event"), "events")
        XCTAssertEqual(ContentTypes.canonicalID("Games"), "games")
    }

    func testUnknownTypesAreCapitalisedNeverHidden() {
        let info = ContentTypes.info(for: "games")
        XCTAssertEqual(info.title, "Games")
        XCTAssertEqual(info.symbolName, ContentTypes.genericSymbolName)
        XCTAssertFalse(info.isKnown)
        XCTAssertFalse(ContentTypes.isKnown("games"))
        XCTAssertEqual(ContentTypes.title(for: "netflixOriginals"), "NetflixOriginals", "only the first letter changes")
        XCTAssertEqual(ContentTypes.title(for: "è-tv"), "È-tv")
    }

    func testBlankTypeFallsBackToOther() {
        XCTAssertEqual(ContentTypes.title(for: ""), "Altro")
        XCTAssertEqual(ContentTypes.title(for: "   "), "Altro")
        XCTAssertEqual(ContentTypes.canonicalID(""), "other")
    }

    func testSortingIsCanonicalThenAlphabeticalAndIndependentOfInputOrder() {
        let input: [String] = ["zeta", "podcast", "movie", "Alpha", "other", "series", "sport", "tv"]
        let expected: [String] = ["movie", "series", "tv", "sport", "podcast", "other", "Alpha", "zeta"]
        XCTAssertEqual(ContentTypes.sorted(input), expected)
        XCTAssertEqual(ContentTypes.sorted(Array(input.reversed())), expected)
        XCTAssertEqual(ContentTypes.sorted([]), [])
        XCTAssertEqual(ContentTypes.sorted(["b", "B", "a"]), ["a", "B", "b"], "ties on case are broken deterministically")
    }
}

// MARK: - Capabilities

final class CatalogCapabilitiesTests: XCTestCase {
    func testNoAddonsMeansNoTypesAndNoSearch() {
        let capabilities = CatalogCapabilities.build(handles: [])
        XCTAssertTrue(capabilities.isEmpty)
        XCTAssertEqual(capabilities, CatalogCapabilities.empty)
        XCTAssertTrue(capabilities.availableTypes.isEmpty)
        XCTAssertTrue(capabilities.searchableTypes.isEmpty)
        XCTAssertFalse(capabilities.canSearch)
        XCTAssertNil(capabilities.capability(forType: "movie"))
        XCTAssertEqual(capabilities.filterGenres(forType: nil), [])
        XCTAssertEqual(capabilities.browseGenres(forType: "movie"), [])
    }

    func testCinemetaShapeOffersOnlyWhatCanBeServed() {
        let capabilities = CatalogCapabilities.build(handles: [CatalogKit.cinemetaLike()])
        XCTAssertEqual(CatalogKit.typeIDs(capabilities.types), ["movie", "series"])
        XCTAssertEqual(CatalogKit.keys(capabilities.feedCatalogs), ["movie/top", "series/top", "movie/imdbRating"],
                       "year needs a genre and last-videos needs ids: neither is browsable")
        XCTAssertEqual(CatalogKit.keys(capabilities.searchCatalogs), ["movie/top", "series/top"])

        let movie = capabilities.capability(forType: "movie")
        XCTAssertEqual(movie?.feedCatalogCount, 2)
        XCTAssertEqual(movie?.searchCatalogCount, 1)
        XCTAssertEqual(movie?.searchWithGenreCatalogCount, 1)
        XCTAssertEqual(movie?.title, "Film")
        XCTAssertEqual(movie?.symbolName, "film")
        XCTAssertEqual(movie?.hasFeed, true)
        XCTAssertEqual(movie?.isSearchable, true)
        XCTAssertEqual(movie?.canSendGenreWithSearch, true)
        XCTAssertEqual(movie?.feedGenres, ["Action", "Comedy", "Drama", "Horror"],
                       "the years of the 'year' catalog are not genres")
        XCTAssertEqual(movie?.searchGenres, ["Action", "Comedy", "Drama", "Horror"])

        let series = capabilities.capability(forType: "series")
        XCTAssertEqual(series?.feedGenres, ["Action & Adventure", "Drama"])
        XCTAssertEqual(CatalogKit.typeIDs(capabilities.availableTypes), ["movie", "series"])
        XCTAssertEqual(CatalogKit.typeIDs(capabilities.searchableTypes), ["movie", "series"])
        XCTAssertTrue(capabilities.canSearch)
    }

    func testAgreesWithTheExistingPlannerOnWhichTypesExist() {
        let handles = [CatalogKit.cinemetaLike()]
        let legacy = RequestPlanner.availableTypes(handles: handles)
        let current = CatalogKit.typeIDs(CatalogCapabilities.build(handles: handles).availableTypes)
        XCTAssertEqual(legacy, current)
    }

    func testTypesWithOnlySearchAreSearchableButNotAvailableForDiscover() {
        let lyrics = CatalogKit.handle("lyrics", catalogs: [
            CatalogKit.catalog("music", "find", extras: [CatalogKit.extra("search", required: true)])])
        let capabilities = CatalogCapabilities.build(handles: [lyrics])
        XCTAssertTrue(capabilities.availableTypes.isEmpty, "nothing to browse, so no Discover category")
        XCTAssertEqual(CatalogKit.typeIDs(capabilities.searchableTypes), ["music"])
        let music = capabilities.capability(forType: "music")
        XCTAssertEqual(music?.title, "Musica")
        XCTAssertEqual(music?.hasFeed, false)
        XCTAssertEqual(music?.isSearchable, true)
        XCTAssertEqual(music?.canSendGenreWithSearch, false)
    }

    func testCatalogsNeedingOtherExtrasAreIgnoredEntirely() {
        let guide = CatalogKit.handle("epg", catalogs: [
            CatalogKit.catalog("tv", "guide", extras: [CatalogKit.extra("date", required: true)]),
            CatalogKit.catalog("tv", "find", extras: [CatalogKit.extra("search", required: true),
                                                      CatalogKit.extra("date", required: true)])])
        let capabilities = CatalogCapabilities.build(handles: [guide])
        XCTAssertTrue(capabilities.isEmpty, "no type is listed when nothing can fill it")
        XCTAssertTrue(capabilities.feedCatalogs.isEmpty)
        XCTAssertTrue(capabilities.searchCatalogs.isEmpty)
    }

    func testDisabledAndUnusableAddonsAreIgnored() {
        let plain = [CatalogKit.catalog("movie", "top")]
        let off = CatalogKit.handle("off", catalogs: plain, enabled: false)
        let broken = CatalogKit.handle("broken", catalogs: [CatalogKit.catalog("series", "top")], needsReinstall: true)
        XCTAssertTrue(CatalogCapabilities.build(handles: [off, broken]).isEmpty)
        let on = CatalogKit.handle("on", catalogs: plain)
        XCTAssertEqual(CatalogKit.typeIDs(CatalogCapabilities.build(handles: [off, on, broken]).types), ["movie"])
    }

    func testAdultAddonsAreHiddenUnlessAllowed() {
        let adult = CatalogKit.handle("adult", catalogs: [
            CatalogKit.catalog("movie", "hot", extras: [CatalogKit.extra("search")])], adult: true)
        let family = CatalogKit.handle("family", catalogs: [CatalogKit.catalog("series", "kids")])

        let defaults = CatalogCapabilities.build(handles: [adult, family])
        XCTAssertEqual(CatalogKit.typeIDs(defaults.types), ["series"], "hidden by default: the safe choice")
        XCTAssertFalse(defaults.canSearch, "adult catalogs are not searched either")

        let explicitHide = CatalogCapabilities.build(handles: [adult, family], hideAdultCatalogs: true)
        XCTAssertEqual(explicitHide, defaults)

        let shown = CatalogCapabilities.build(handles: [adult, family], hideAdultCatalogs: false)
        XCTAssertEqual(CatalogKit.typeIDs(shown.types), ["movie", "series"])
        XCTAssertTrue(shown.canSearch)
    }

    func testCatalogsHiddenByTheUserLeaveDiscoverButNotSearch() {
        let both = CatalogKit.handle("both", catalogs: [
            CatalogKit.catalog("movie", "top", extras: [CatalogKit.extra("search"), CatalogKit.extra("genre", options: ["Action"])]),
            CatalogKit.catalog("movie", "new", extras: [CatalogKit.extra("genre", options: ["Western"])])],
            hidden: ["movie/top"])
        let capabilities = CatalogCapabilities.build(handles: [both])
        XCTAssertEqual(CatalogKit.keys(capabilities.feedCatalogs), ["movie/new"])
        XCTAssertEqual(CatalogKit.keys(capabilities.searchCatalogs), ["movie/top"])
        let movie = capabilities.capability(forType: "movie")
        XCTAssertEqual(movie?.feedCatalogCount, 1)
        XCTAssertEqual(movie?.feedGenres, ["Western"], "Discover offers only genres of catalogs it will show")

        let onlyHidden = CatalogKit.handle("hid", catalogs: [
            CatalogKit.catalog("series", "top", extras: [CatalogKit.extra("search")])], hidden: ["series/top"])
        let hiddenOnly = CatalogCapabilities.build(handles: [onlyHidden])
        XCTAssertTrue(hiddenOnly.availableTypes.isEmpty)
        XCTAssertEqual(CatalogKit.typeIDs(hiddenOnly.searchableTypes), ["series"])
    }

    func testGenresAreMergedAcrossAddonsIgnoringCaseAndAccents() {
        let first = CatalogKit.handle("first", catalogs: [
            CatalogKit.catalog("movie", "a", extras: [
                CatalogKit.extra("genre", options: ["action", "Comedy", "  Drama  ", "Fantasía"])])])
        let second = CatalogKit.handle("second", catalogs: [
            CatalogKit.catalog("movie", "b", extras: [
                CatalogKit.extra("genre", options: ["Action", "comedy", "DRAMA", "fantasia", "Thriller", "", "   "])])])
        let capabilities = CatalogCapabilities.build(handles: [first, second])
        XCTAssertEqual(capabilities.browseGenres(forType: "movie"),
                       ["action", "Comedy", "Drama", "Fantasía", "Thriller"],
                       "first spelling wins, sorted case-insensitively, blanks dropped")
        let reversed = CatalogCapabilities.build(handles: [second, first])
        XCTAssertEqual(reversed.browseGenres(forType: "movie"), ["Action", "comedy", "DRAMA", "fantasia", "Thriller"])
        XCTAssertEqual(reversed.capability(forType: "movie")?.feedGenres.count, 5)
    }

    func testGenreListsMadeOfYearsOrRequiredGenresAreNotGenres() {
        let odd = CatalogKit.handle("odd", catalogs: [
            CatalogKit.catalog("movie", "byYear", extras: [CatalogKit.extra("genre", options: ["2020", "2021", " 1999 "])]),
            CatalogKit.catalog("movie", "byGenre", extras: [CatalogKit.extra("genre", required: true, options: ["Action"])]),
            CatalogKit.catalog("movie", "mixed", extras: [CatalogKit.extra("genre", options: ["2020", "Action"])])])
        let capabilities = CatalogCapabilities.build(handles: [odd])
        XCTAssertEqual(CatalogKit.keys(capabilities.feedCatalogs), ["movie/byYear", "movie/mixed"])
        XCTAssertEqual(capabilities.browseGenres(forType: "movie"), ["2020", "Action"],
                       "only a list made entirely of years is rejected; a required genre is not browsable at all")
        XCTAssertTrue(CatalogCapabilities.looksLikeYearList(["2020", "1999"]))
        XCTAssertFalse(CatalogCapabilities.looksLikeYearList([]))
        XCTAssertFalse(CatalogCapabilities.looksLikeYearList(["2020", "Action"]))
        XCTAssertFalse(CatalogCapabilities.looksLikeYearList(["0123"]))
    }

    func testUnknownTypesAreKeptAndAliasesMergeIntoOneEntry() {
        let handles = [
            CatalogKit.handle("a", catalogs: [CatalogKit.catalog("games", "top")]),
            CatalogKit.handle("b", catalogs: [CatalogKit.catalog("Games", "hot")]),
            CatalogKit.handle("c", catalogs: [CatalogKit.catalog("sport", "s1")]),
            CatalogKit.handle("d", catalogs: [CatalogKit.catalog("sports", "s2")])
        ]
        let capabilities = CatalogCapabilities.build(handles: handles)
        XCTAssertEqual(CatalogKit.typeIDs(capabilities.types), ["sports", "games"], "known first, unknown never dropped")

        let sports = capabilities.capability(forType: "Sport")
        XCTAssertEqual(sports?.memberIDs, ["sport", "sports"], "addons are still asked with their own spelling")
        XCTAssertEqual(sports?.title, "Sport")
        XCTAssertEqual(sports?.feedCatalogCount, 2)
        XCTAssertEqual(sports?.owns("SPORTS"), true)
        XCTAssertEqual(sports?.owns("games"), false)
        XCTAssertEqual(CatalogKit.keys(capabilities.catalogsToBrowse(forType: "sports")), ["sport/s1", "sports/s2"])

        let games = capabilities.capability(forType: "GAMES")
        XCTAssertEqual(games?.memberIDs, ["games", "Games"])
        XCTAssertEqual(games?.title, "Games")
        XCTAssertEqual(games?.isKnown, false)
        XCTAssertEqual(games?.symbolName, ContentTypes.genericSymbolName)
    }

    func testTypesAreInCanonicalOrderWhateverTheAddonOrder() {
        let order = ["podcast", "other", "anime", "movie", "tv", "series"]
        var handles: [AddonHandle] = []
        for type in order {
            handles.append(CatalogKit.handle("h-\(type)", catalogs: [CatalogKit.catalog(type, "c")]))
        }
        let capabilities = CatalogCapabilities.build(handles: handles)
        XCTAssertEqual(CatalogKit.typeIDs(capabilities.types), ["movie", "series", "anime", "tv", "podcast", "other"])
    }

    func testSearchGenresComeOnlyFromTypesThatCanBeSearched() {
        let searchable = CatalogKit.handle("s", catalogs: [
            CatalogKit.catalog("movie", "top", extras: [CatalogKit.extra("genre", options: ["Action"]), CatalogKit.extra("search")])])
        let feedOnly = CatalogKit.handle("f", catalogs: [
            CatalogKit.catalog("movie", "extra", extras: [CatalogKit.extra("genre", options: ["Western"])]),
            CatalogKit.catalog("music", "hits", extras: [CatalogKit.extra("genre", options: ["Pop"])])])
        let capabilities = CatalogCapabilities.build(handles: [searchable, feedOnly])
        XCTAssertEqual(capabilities.filterGenres(forType: "movie"), ["Action", "Western"],
                       "a searchable type also offers the genres of its other catalogs")
        XCTAssertEqual(capabilities.filterGenres(forType: "music"), [], "music cannot be searched")
        XCTAssertEqual(capabilities.filterGenres(forType: nil), ["Action", "Western"])
        XCTAssertEqual(capabilities.browseGenres(forType: "music"), ["Pop"])
        XCTAssertEqual(capabilities.browseGenres(forType: "movie"), ["Action", "Western"])
        XCTAssertEqual(capabilities.filterGenres(forType: "unknown"), [])
    }

    func testSearchWithGenreIsDetectedFromTheManifestOnly() {
        let both = CatalogKit.catalog("movie", "a", extras: [CatalogKit.extra("search"), CatalogKit.extra("genre")])
        let searchOnly = CatalogKit.catalog("movie", "b", extras: [CatalogKit.extra("search")])
        let genreOnly = CatalogKit.catalog("movie", "c", extras: [CatalogKit.extra("genre")])
        let requiredOther = CatalogKit.catalog("movie", "d", extras: [
            CatalogKit.extra("search"), CatalogKit.extra("genre"), CatalogKit.extra("date", required: true)])
        XCTAssertTrue(CatalogCapabilities.supportsSearchWithGenre(both))
        XCTAssertFalse(CatalogCapabilities.supportsSearchWithGenre(searchOnly))
        XCTAssertFalse(CatalogCapabilities.supportsSearchWithGenre(genreOnly))
        XCTAssertFalse(CatalogCapabilities.supportsSearchWithGenre(requiredOther))
    }

    func testRecomputingAfterAddonChangesIsCheapAndComparable() {
        let cinemeta = CatalogKit.cinemetaLike()
        let radio = CatalogKit.handle("radio", catalogs: [CatalogKit.catalog("radio", "top")])
        let one = CatalogCapabilities.build(handles: [cinemeta])
        XCTAssertEqual(one, CatalogCapabilities.build(handles: [cinemeta]), "same input, equal value: the UI can skip a refresh")
        let two = CatalogCapabilities.build(handles: [cinemeta, radio])
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(CatalogKit.typeIDs(two.availableTypes), ["movie", "series", "radio"])

        // 120 addons with 25 catalogs each: a plain pass over value types.
        var many: [AddonHandle] = []
        for index in 0..<120 {
            var catalogs: [ManifestCatalog] = []
            for number in 0..<25 {
                catalogs.append(CatalogKit.catalog("movie", "c\(number)", extras: [
                    CatalogKit.extra("genre", options: ["G\(number)", "Action"]), CatalogKit.extra("search")]))
            }
            many.append(CatalogKit.handle("bulk\(index)", catalogs: catalogs))
        }
        let big = CatalogCapabilities.build(handles: many)
        XCTAssertEqual(big.feedCatalogs.count, 3000)
        XCTAssertEqual(big.capability(forType: "movie")?.feedGenres.count, 26)
    }

    func testCapabilitiesFollowTheRegistry() async throws {
        let env = try TestEnvironment()
        let full = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        _ = try await env.install(manifestFixture: "manifest_p2p_adult.json", at: "https://p.test/manifest.json")
        let beforeHandles = await env.service.handles()
        let before = CatalogCapabilities.build(handles: beforeHandles)
        XCTAssertEqual(CatalogKit.typeIDs(before.availableTypes), ["movie", "series"])
        XCTAssertEqual(CatalogKit.keys(before.searchCatalogs), ["movie/top", "movie/search-only"])
        XCTAssertEqual(before.browseGenres(forType: "movie"), ["Azione", "Commedia"])
        XCTAssertEqual(before.capability(forType: "movie")?.searchWithGenreCatalogCount, 1)
        XCTAssertTrue(before.capability(forType: "series")?.isSearchable == false)

        await env.registry.setCatalogVisible(false, catalogKey: "series/top", id: full.id)
        let hiddenHandles = await env.service.handles()
        let hidden = CatalogCapabilities.build(handles: hiddenHandles)
        XCTAssertEqual(CatalogKit.typeIDs(hidden.availableTypes), ["movie"])
        XCTAssertNotEqual(before, hidden)

        await env.registry.setEnabled(false, id: full.id)
        let disabledHandles = await env.service.handles()
        let disabled = CatalogCapabilities.build(handles: disabledHandles)
        XCTAssertTrue(disabled.isEmpty, "no enabled addon with catalogs, no categories and no filters")
    }
}

// MARK: - Search plan

final class SearchPlanTests: XCTestCase {
    private func capabilities() -> CatalogCapabilities {
        let lyrics = CatalogKit.handle("lyrics", catalogs: [
            CatalogKit.catalog("music", "find", extras: [CatalogKit.extra("search", required: true)])])
        return CatalogCapabilities.build(handles: [CatalogKit.cinemetaLike(), lyrics])
    }

    /// Four catalogs of type movie that treat `search` and `genre` differently.
    private func genreHandles() -> [AddonHandle] {
        let both = CatalogKit.catalog("movie", "a", extras: [
            CatalogKit.extra("genre", options: ["Azione", "Commedia"]), CatalogKit.extra("search")])
        let plain = CatalogKit.catalog("movie", "b", extras: [CatalogKit.extra("search", required: true)])
        let foreign = CatalogKit.catalog("movie", "c", extras: [
            CatalogKit.extra("genre", options: ["Western"]), CatalogKit.extra("search")])
        let free = CatalogKit.catalog("movie", "d", extras: [CatalogKit.extra("genre"), CatalogKit.extra("search")])
        return [CatalogKit.handle("a", catalogs: [both]), CatalogKit.handle("b", catalogs: [plain]),
                CatalogKit.handle("c", catalogs: [foreign]), CatalogKit.handle("d", catalogs: [free])]
    }

    func testBlankQueryProducesNoRequests() {
        let plan = SearchPlan.make(query: "   \t ", capabilities: capabilities())
        XCTAssertEqual(plan.query, "")
        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertFalse(plan.isRunnable)
        XCTAssertNil(plan.emptyReason, "nothing typed yet: no complaint")
        XCTAssertNil(plan.genreNotice)
    }

    func testEveryUsableCatalogGetsOnlyTheSearchExtra() {
        let plan = SearchPlan.make(query: "  big   buck ", capabilities: capabilities())
        XCTAssertEqual(plan.query, "big buck")
        XCTAssertTrue(plan.isRunnable)
        XCTAssertEqual(CatalogKit.keys(plan.entries.map { (entry: SearchPlanEntry) -> CatalogRef in entry.ref }),
                       ["movie/top", "series/top", "music/find"],
                       "catalogs that need other extras or do not declare search are never asked")
        for entry in plan.entries {
            XCTAssertEqual(entry.extra, [ExtraValue(name: "search", value: "big buck")])
            XCTAssertEqual(entry.genreHandling, .notRequested)
        }
        XCTAssertNil(plan.genre)
        XCTAssertFalse(plan.localFilters.isActive)
        XCTAssertNil(plan.genreNotice)
    }

    func testTypeRestrictsTheCatalogsAndAcceptsAnySpelling() {
        let movie = SearchPlan.make(query: "x", type: "Movie", capabilities: capabilities())
        XCTAssertEqual(movie.typeID, "movie")
        XCTAssertEqual(CatalogKit.keys(movie.entries.map { (entry: SearchPlanEntry) -> CatalogRef in entry.ref }), ["movie/top"])
        let music = SearchPlan.make(query: "x", type: " music ", capabilities: capabilities())
        XCTAssertEqual(CatalogKit.keys(music.entries.map { (entry: SearchPlanEntry) -> CatalogRef in entry.ref }), ["music/find"])
        let blankType = SearchPlan.make(query: "x", type: "  ", capabilities: capabilities())
        XCTAssertNil(blankType.typeID)
        XCTAssertEqual(blankType.entries.count, 3)
    }

    func testTypeNobodySearchesExplainsItself() {
        let unknown = SearchPlan.make(query: "x", type: "games", capabilities: capabilities())
        XCTAssertTrue(unknown.entries.isEmpty)
        XCTAssertFalse(unknown.isRunnable)
        XCTAssertEqual(unknown.emptyReason, "Nessun addon attivo cerca tra i contenuti «Games».")

        let anime = SearchPlan.make(query: "x", type: "anime", capabilities: capabilities())
        XCTAssertEqual(anime.emptyReason, "Nessun addon attivo cerca tra i contenuti «Anime».")

        let none = SearchPlan.make(query: "x", capabilities: CatalogCapabilities.empty)
        XCTAssertEqual(none.emptyReason, "Nessun addon attivo dichiara la ricerca nei suoi cataloghi.")
    }

    func testEverySpellingOfATypeIsSearchedWithItsOwnSpelling() {
        let handles = [
            CatalogKit.handle("a", catalogs: [CatalogKit.catalog("sport", "s1", extras: [CatalogKit.extra("search")])]),
            CatalogKit.handle("b", catalogs: [CatalogKit.catalog("sports", "s2", extras: [CatalogKit.extra("search")])]),
            CatalogKit.handle("c", catalogs: [CatalogKit.catalog("movie", "m", extras: [CatalogKit.extra("search")])])
        ]
        let caps = CatalogCapabilities.build(handles: handles)
        XCTAssertEqual(CatalogKit.keys(caps.catalogsToSearch(forType: "Sports")), ["sport/s1", "sports/s2"])
        XCTAssertEqual(CatalogKit.keys(caps.catalogsToSearch(forType: nil)), ["sport/s1", "sports/s2", "movie/m"])
        XCTAssertTrue(caps.catalogsToSearch(forType: "games").isEmpty)

        let plan = SearchPlan.make(query: "derby", type: "SPORT", capabilities: caps)
        XCTAssertEqual(plan.typeID, "sports")
        XCTAssertEqual(plan.entries.count, 2)
        XCTAssertEqual(plan.entries[0].path.type, "sport", "the addon is asked with the spelling its manifest declares")
        XCTAssertEqual(plan.entries[1].path.type, "sports")
        for entry in plan.entries {
            let owner = handles.first(where: { (handle: AddonHandle) -> Bool in handle.id == entry.ref.addonID })
            XCTAssertEqual(owner?.addon.manifest.supports(entry.path), true)
        }
    }

    func testGenreIsSentOnlyToCatalogsThatDeclareBothAndKnowTheGenre() {
        let caps = CatalogCapabilities.build(handles: genreHandles())
        let plan = SearchPlan.make(query: "matrix", genre: " azione ", capabilities: caps)
        XCTAssertEqual(plan.genre, "azione")
        XCTAssertEqual(plan.entries.count, 4)

        let a = plan.entries[0]
        XCTAssertEqual(a.ref.catalog.id, "a")
        XCTAssertEqual(a.extra, [ExtraValue(name: "search", value: "matrix"), ExtraValue(name: "genre", value: "Azione")],
                       "the catalog's own spelling of the option is sent")
        XCTAssertEqual(a.genreHandling, .sentAndVerifiedLocally)

        let b = plan.entries[1]
        XCTAssertEqual(b.extra, [ExtraValue(name: "search", value: "matrix")], "no genre extra declared")
        XCTAssertEqual(b.genreHandling, .localOnly)

        let c = plan.entries[2]
        XCTAssertEqual(c.extra, [ExtraValue(name: "search", value: "matrix")], "'azione' is not one of its options")
        XCTAssertEqual(c.genreHandling, .localOnly)

        let d = plan.entries[3]
        XCTAssertEqual(d.extra, [ExtraValue(name: "search", value: "matrix"), ExtraValue(name: "genre", value: "azione")],
                       "free-form genre extra: the cleaned wanted value is sent")
        XCTAssertEqual(d.genreHandling, .sentAndVerifiedLocally)

        XCTAssertEqual(plan.genreSentCount, 2)
        XCTAssertEqual(plan.genreLocalOnlyCount, 2)
        XCTAssertEqual(plan.localFilters.genre, "azione", "the genre is always verified locally, never trusted")
        XCTAssertTrue(plan.localFilters.isActive)
    }

    func testEveryPlannedRequestIsAcceptedByItsManifest() {
        let handles = genreHandles() + [CatalogKit.cinemetaLike()]
        let caps = CatalogCapabilities.build(handles: handles)
        let plan = SearchPlan.make(query: "matrix", genre: "Action", capabilities: caps)
        XCTAssertFalse(plan.entries.isEmpty)
        for entry in plan.entries {
            let owner = handles.first(where: { (handle: AddonHandle) -> Bool in handle.id == entry.ref.addonID })
            XCTAssertNotNil(owner)
            XCTAssertEqual(owner?.addon.manifest.supports(entry.path), true,
                           "AddonService would reject \(entry.ref.id) otherwise")
        }
    }

    func testNoticeSaysWhoFiltersTheGenre() {
        let all = CatalogCapabilities.build(handles: genreHandles())
        let mixed = SearchPlan.make(query: "x", genre: "Azione", capabilities: all)
        XCTAssertEqual(mixed.genreNotice,
                       "Il filtro per genere è applicato da Aether sui risultati ricevuti: non tutti gli addon lo supportano nella ricerca.")

        let capable = CatalogCapabilities.build(handles: [genreHandles()[0], genreHandles()[3]])
        let sent = SearchPlan.make(query: "x", genre: "Azione", capabilities: capable)
        XCTAssertEqual(sent.genreNotice, "Il genere è richiesto agli addon e ricontrollato sui risultati ricevuti.")
        XCTAssertNil(SearchPlan.make(query: "x", capabilities: capable).genreNotice)
    }

    func testLocalOnlyStrategyNeverSendsTheGenre() {
        let caps = CatalogCapabilities.build(handles: genreHandles())
        let plan = SearchPlan.make(query: "matrix", genre: "Azione", capabilities: caps, genreStrategy: .localOnly)
        XCTAssertEqual(plan.entries.count, 4)
        for entry in plan.entries {
            XCTAssertEqual(entry.extra, [ExtraValue(name: "search", value: "matrix")])
            XCTAssertEqual(entry.genreHandling, .localOnly)
        }
        XCTAssertEqual(plan.genreSentCount, 0)
        XCTAssertEqual(plan.localFilters.genre, "Azione")
    }

    func testBlankGenreIsIgnored() {
        let caps = CatalogCapabilities.build(handles: genreHandles())
        let plan = SearchPlan.make(query: "x", genre: "  \n", capabilities: caps)
        XCTAssertNil(plan.genre)
        XCTAssertNil(plan.localFilters.genre)
        XCTAssertFalse(plan.localFilters.isActive)
        for entry in plan.entries {
            XCTAssertEqual(entry.genreHandling, .notRequested)
        }
    }

    func testYearAndRatingAreAlwaysLocalAndNeverSent() {
        let caps = CatalogCapabilities.build(handles: genreHandles())
        let plan = SearchPlan.make(query: "x", year: .range(2000, 2010), yearMatch: .overlapping,
                                   minimumRating: 7, capabilities: caps)
        XCTAssertEqual(plan.localFilters.year, YearFilter.range(2000, 2010))
        XCTAssertEqual(plan.localFilters.yearMatch, .overlapping)
        XCTAssertEqual(plan.localFilters.minimumRating, 7)
        for entry in plan.entries {
            XCTAssertEqual(entry.extra.count, 1)
        }

        let items: [MetaItem] = [
            CatalogKit.item("in", release: "2005", rating: "8.0"),
            CatalogKit.item("old", release: "1999", rating: "9.0"),
            CatalogKit.item("low", release: "2006", rating: "5.0"),
            CatalogKit.item("noyear", rating: "8.0")
        ]
        let outcome = plan.filter(items)
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["in"])
        XCTAssertEqual(outcome.hiddenMismatch, 2)
        XCTAssertEqual(outcome.hiddenWithoutYear, 1)
    }

    func testFilteringTheAnswerOfACatalogThatIgnoredTheGenre() {
        let caps = CatalogCapabilities.build(handles: genreHandles())
        let plan = SearchPlan.make(query: "x", genre: "Azione", capabilities: caps)
        let answer: [MetaItem] = [
            CatalogKit.item("match", genres: ["Azione", "Thriller"]),
            CatalogKit.item("other", genres: ["Commedia"]),
            CatalogKit.item("unknown")
        ]
        let outcome = plan.filter(answer)
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["match"])
        XCTAssertEqual(outcome.hiddenMismatch, 1)
        XCTAssertEqual(outcome.hiddenMissingData, 1)
        XCTAssertEqual(outcome.missingDataSummary, "1 risultato senza genere nascosto")
    }
}

// MARK: - Running a plan

final class PlannedSearchTests: XCTestCase {
    private func install(_ env: TestEnvironment) async throws {
        _ = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        _ = try await env.install(manifestFixture: "manifest_search_only.json", at: "https://s.test/manifest.json")
    }

    func testGenreTravelsOnlyWhereDeclaredAndEveryAnswerIsFilteredLocally() async throws {
        let env = try TestEnvironment()
        try await install(env)
        let handles = await env.service.handles()
        let capabilities = CatalogCapabilities.build(handles: handles)
        let plan = SearchPlan.make(query: "matrix", genre: "azione", capabilities: capabilities)
        XCTAssertEqual(plan.entries.count, 3)
        XCTAssertEqual(plan.genreSentCount, 1)

        env.server.set("https://a.test/catalog/movie/top/search=matrix&genre=Azione.json", json: CatalogKit.catalogJSON([
            CatalogKit.metaJSON("m1", release: "2010", genres: ["Azione"]),
            CatalogKit.metaJSON("m2", release: "2011", genres: ["Commedia"]),
            CatalogKit.metaJSON("m3", release: "2012")]))
        env.server.set("https://a.test/catalog/movie/search-only/search=matrix.json", json: CatalogKit.catalogJSON([
            CatalogKit.metaJSON("m4", genres: ["azione", "Thriller"]),
            CatalogKit.metaJSON("m5", genres: ["Drama"])]))
        env.server.set("https://s.test/catalog/movie/s/search=matrix.json", status: 500)

        var updates: [PlannedSearchUpdate] = []
        for await update in PlannedSearch(service: env.service).run(plan) {
            updates.append(update)
        }
        XCTAssertEqual(updates.count, 3)
        XCTAssertEqual(updates.map { (update: PlannedSearchUpdate) -> Int in update.completed }.sorted(), [1, 2, 3])
        for update in updates {
            XCTAssertEqual(update.total, 3)
        }

        let top = try XCTUnwrap(updates.first(where: { (update: PlannedSearchUpdate) -> Bool in update.row.ref.catalog.id == "top" }))
        XCTAssertEqual(CatalogKit.itemIDs(top.row.items), ["m1"])
        XCTAssertEqual(top.filtering.hiddenMismatch, 1)
        XCTAssertEqual(top.filtering.hiddenWithoutGenre, 1)
        XCTAssertNil(top.row.error)

        let searchOnly = try XCTUnwrap(updates.first(where: { (update: PlannedSearchUpdate) -> Bool in update.row.ref.catalog.id == "search-only" }))
        XCTAssertEqual(CatalogKit.itemIDs(searchOnly.row.items), ["m4"])
        XCTAssertEqual(searchOnly.filtering.hiddenMismatch, 1)

        let failing = try XCTUnwrap(updates.first(where: { (update: PlannedSearchUpdate) -> Bool in update.row.ref.catalog.id == "s" }))
        XCTAssertEqual(failing.row.error, AddonError.http(status: 500))
        XCTAssertTrue(failing.row.items.isEmpty)

        XCTAssertEqual(env.server.requestCount(containing: "genre="), 1, "only the catalog declaring both received the genre")
        XCTAssertEqual(env.server.requestCount(containing: "/catalog/"), 3)
    }

    func testPerCatalogLimitAppliesAfterTheFilters() async throws {
        let env = try TestEnvironment()
        try await install(env)
        let handles = await env.service.handles()
        let capabilities = CatalogCapabilities.build(handles: handles)
        let plan = SearchPlan.make(query: "q", type: "movie", year: .since(2000), capabilities: capabilities)
        XCTAssertEqual(plan.entries.count, 3)

        var metas: [String] = []
        for index in 0..<5 {
            metas.append(CatalogKit.metaJSON("old\(index)", release: "199\(index)"))
        }
        for index in 0..<5 {
            metas.append(CatalogKit.metaJSON("new\(index)", release: "200\(index)"))
        }
        metas.append(CatalogKit.metaJSON("undated"))
        env.server.set("https://a.test/catalog/movie/top/search=q.json", json: CatalogKit.catalogJSON(metas))
        env.server.set("https://a.test/catalog/movie/search-only/search=q.json", json: CatalogKit.catalogJSON([]))
        env.server.set("https://s.test/catalog/movie/s/search=q.json", json: CatalogKit.catalogJSON([]))

        var updates: [PlannedSearchUpdate] = []
        for await update in PlannedSearch(service: env.service).run(plan, perCatalogLimit: 2) {
            updates.append(update)
        }
        let top = try XCTUnwrap(updates.first(where: { (update: PlannedSearchUpdate) -> Bool in update.row.ref.catalog.id == "top" }))
        XCTAssertEqual(CatalogKit.itemIDs(top.row.items), ["new0", "new1"], "the cap is applied to what survived the filter")
        XCTAssertEqual(top.filtering.kept.count, 5)
        XCTAssertEqual(top.filtering.hiddenMismatch, 5)
        XCTAssertEqual(top.filtering.hiddenWithoutYear, 1)
        XCTAssertEqual(top.filtering.missingDataSummary, "1 risultato senza anno nascosto")
    }

    func testAnEmptyPlanMakesNoRequests() async throws {
        let env = try TestEnvironment()
        try await install(env)
        let handles = await env.service.handles()
        let capabilities = CatalogCapabilities.build(handles: handles)
        let blank = SearchPlan.make(query: "  ", capabilities: capabilities)
        var count = 0
        for await _ in PlannedSearch(service: env.service).run(blank) {
            count += 1
        }
        XCTAssertEqual(count, 0)
        let nobody = SearchPlan.make(query: "q", type: "games", capabilities: capabilities)
        for await _ in PlannedSearch(service: env.service).run(nobody) {
            count += 1
        }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(env.server.requestCount(containing: "/catalog/"), 0)
    }
}

// MARK: - Years

final class ReleaseYearsTests: XCTestCase {
    func testParsesSingleYearsAndRuns() {
        XCTAssertEqual(ReleaseYears.parse("2019"), ReleaseYears(start: 2019))
        XCTAssertEqual(ReleaseYears.parse("2011-2019"), ReleaseYears(start: 2011, end: 2019))
        XCTAssertEqual(ReleaseYears.parse("2011–2019"), ReleaseYears(start: 2011, end: 2019), "en dash")
        XCTAssertEqual(ReleaseYears.parse("2011—2019"), ReleaseYears(start: 2011, end: 2019), "em dash")
        XCTAssertEqual(ReleaseYears.parse(" 2011 – 2019 "), ReleaseYears(start: 2011, end: 2019))
        XCTAssertEqual(ReleaseYears.parse("2011 - 2019"), ReleaseYears(start: 2011, end: 2019))
        XCTAssertEqual(ReleaseYears.parse("Year 2020!"), ReleaseYears(start: 2020))
    }

    func testOpenEndedRunsAreOngoing() {
        let expected = ReleaseYears(start: 2019, end: nil, isOngoing: true)
        XCTAssertEqual(ReleaseYears.parse("2019–"), expected)
        XCTAssertEqual(ReleaseYears.parse("2019-"), expected)
        XCTAssertEqual(ReleaseYears.parse("2019 – "), expected)
        XCTAssertEqual(ReleaseYears.parse("(2019 - )"), expected)
        XCTAssertEqual(expected.lastYear, Int.max)
        XCTAssertFalse(expected.isSingleYear)
        XCTAssertEqual(expected.end, 2019)
    }

    func testDatesAndReversedRunsKeepOnlyTheFirstYear() {
        XCTAssertEqual(ReleaseYears.parse("2019-05-12"), ReleaseYears(start: 2019))
        XCTAssertEqual(ReleaseYears.parse("2019-2011"), ReleaseYears(start: 2019), "reversed runs are not trusted")
        XCTAssertEqual(ReleaseYears.parse("2019 2021"), ReleaseYears(start: 2019))
        XCTAssertTrue(ReleaseYears(start: 2019).isSingleYear)
    }

    func testRejectsTextThatIsNotAYear() {
        XCTAssertNil(ReleaseYears.parse(nil))
        XCTAssertNil(ReleaseYears.parse(""))
        XCTAssertNil(ReleaseYears.parse("   "))
        XCTAssertNil(ReleaseYears.parse("N/A"))
        XCTAssertNil(ReleaseYears.parse("1080p"))
        XCTAssertNil(ReleaseYears.parse("12345"))
        XCTAssertNil(ReleaseYears.parse("tt0111161"))
        XCTAssertNil(ReleaseYears.parse("1869"))
        XCTAssertNil(ReleaseYears.parse("2101"))
        XCTAssertEqual(ReleaseYears.parse("1870"), ReleaseYears(start: 1870))
        XCTAssertEqual(ReleaseYears.parse("2100"), ReleaseYears(start: 2100))
    }

    func testItemYearsComeFromReleaseInfoThenFromTheReleaseDateInUTC() {
        let withInfo = CatalogKit.item("a", release: "2011–2019")
        XCTAssertEqual(ReleaseYears.of(withInfo), ReleaseYears(start: 2011, end: 2019))

        // 2010-12-31T23:59:59Z: still 2010 whatever the device time zone is.
        let lateNewYearsEve = Date(timeIntervalSince1970: 1_293_839_999)
        var dated = CatalogKit.item("b")
        dated.released = lateNewYearsEve
        XCTAssertEqual(ReleaseYears.of(dated), ReleaseYears(start: 2010))

        dated.releaseInfo = "N/A"
        XCTAssertEqual(ReleaseYears.of(dated), ReleaseYears(start: 2010), "unusable releaseInfo falls back to the date")
        dated.releaseInfo = "2008"
        XCTAssertEqual(ReleaseYears.of(dated), ReleaseYears(start: 2008), "releaseInfo wins over the date")

        XCTAssertNil(ReleaseYears.of(CatalogKit.item("c")))
        XCTAssertNil(ReleaseYears.of(CatalogKit.item("d", release: "")))
    }

    func testYearFilterBoundsAndLabels() {
        XCTAssertTrue(YearFilter.exact(2010).contains(2010))
        XCTAssertFalse(YearFilter.exact(2010).contains(2011))
        XCTAssertTrue(YearFilter.range(2000, 2010).contains(2000))
        XCTAssertTrue(YearFilter.range(2000, 2010).contains(2010))
        XCTAssertFalse(YearFilter.range(2000, 2010).contains(1999))
        XCTAssertEqual(YearFilter.range(2010, 2000), YearFilter.range(2000, 2010), "reversed bounds are swapped")
        XCTAssertTrue(YearFilter.since(2010).contains(2500))
        XCTAssertFalse(YearFilter.since(2010).contains(2009))
        XCTAssertTrue(YearFilter.through(2010).contains(1900))
        XCTAssertFalse(YearFilter.through(2010).contains(2011))
        XCTAssertTrue(YearFilter(lowerBound: nil, upperBound: nil).isUnbounded)
        XCTAssertFalse(YearFilter.exact(2010).isUnbounded)
        XCTAssertEqual(YearFilter.decade(containing: 1994), YearFilter.range(1990, 1999))
        XCTAssertEqual(YearFilter.exact(2019).label, "2019")
        XCTAssertEqual(YearFilter.range(2011, 2019).label, "2011–2019")
        XCTAssertEqual(YearFilter.since(2011).label, "dal 2011")
        XCTAssertEqual(YearFilter.through(2019).label, "fino al 2019")
        XCTAssertEqual(YearFilter(lowerBound: nil, upperBound: nil).label, "Tutti gli anni")
    }

    func testPremiereVersusOverlappingForRuns() {
        let run = ReleaseYears(start: 2011, end: 2019)
        let ongoing = ReleaseYears(start: 2019, end: nil, isOngoing: true)
        let single = ReleaseYears(start: 2015)

        XCTAssertFalse(YearFilter.exact(2015).matches(run, mode: .premiere), "only the premiere year counts")
        XCTAssertTrue(YearFilter.exact(2015).matches(run, mode: .overlapping))
        XCTAssertTrue(YearFilter.exact(2011).matches(run, mode: .premiere))
        XCTAssertFalse(YearFilter.exact(2020).matches(run, mode: .overlapping))
        XCTAssertFalse(YearFilter.exact(2010).matches(run, mode: .overlapping))
        XCTAssertTrue(YearFilter.since(2024).matches(ongoing, mode: .overlapping), "an ongoing show reaches the present")
        XCTAssertFalse(YearFilter.since(2024).matches(ongoing, mode: .premiere))
        XCTAssertFalse(YearFilter.through(2018).matches(ongoing, mode: .overlapping))
        XCTAssertTrue(YearFilter.exact(2015).matches(single, mode: .overlapping))
        XCTAssertTrue(YearFilter.range(2012, 2013).matches(run, mode: .overlapping), "a range inside the run")
    }
}

// MARK: - Genres and result filters

final class ResultFiltersTests: XCTestCase {
    /// a: 2008 Animation 7.6 / b: 2010 no genres 7,4 / c: no year, Action, no rating
    /// d: 2011–2019 action 9.0 / e: 2019– Drama, rating "0" (unrated)
    private func dataset() -> [MetaItem] {
        return [
            CatalogKit.item("a", release: "2008", genres: ["Animation"], rating: "7.6"),
            CatalogKit.item("b", release: "2010", rating: "7,4"),
            CatalogKit.item("c", genres: ["Action"]),
            CatalogKit.item("d", release: "2011–2019", genres: ["action"], rating: "9.0"),
            CatalogKit.item("e", release: "2019–", genres: ["Drama"], rating: "0")
        ]
    }

    func testGenreNamesCompareIgnoringCaseAccentsAndSpacing() {
        XCTAssertEqual(GenreNames.clean("  Sci-Fi   &  Fantasy \n"), "Sci-Fi & Fantasy")
        XCTAssertEqual(GenreNames.key("ANIMAZIONE"), GenreNames.key("animazione"))
        XCTAssertEqual(GenreNames.key("Fantasía"), GenreNames.key(" fantasia "))
        XCTAssertTrue(GenreNames.contains(["Thriller", "Azione"], "AZIONE "))
        XCTAssertFalse(GenreNames.contains(["Thriller"], "Azione"))
        XCTAssertFalse(GenreNames.contains(["Thriller"], "  "))
        XCTAssertEqual(GenreNames.mergedSorted([["b", "A"], ["a", "B", " c ", ""]]), ["A", "b", "c"])
        XCTAssertEqual(GenreNames.mergedSorted([]), [])
    }

    func testMergedSortedKeepsTheFirstSpelling() {
        XCTAssertEqual(GenreNames.mergedSorted([["Action", "drama"], ["action", "Drama", "Comedy"]]),
                       ["Action", "Comedy", "drama"])
    }

    func testGenresPresentInResults() {
        let present = GenreNames.present(in: dataset())
        XCTAssertEqual(present, ["Action", "Animation", "Drama"])
        XCTAssertEqual(GenreNames.present(in: []), [])
    }

    func testNoActiveFilterKeepsEverythingEvenWhenDataIsMissing() {
        let inactive = ResultFilters(year: YearFilter(lowerBound: nil, upperBound: nil), genre: "  ", minimumRating: 0)
        XCTAssertFalse(inactive.isActive)
        XCTAssertFalse(ResultFilters.none.isActive)
        XCTAssertFalse(ResultFilters(minimumRating: Double.nan).isActive)
        XCTAssertFalse(ResultFilters(minimumRating: -3).isActive)
        for filters in [inactive, ResultFilters.none] {
            let outcome = filters.apply(to: dataset())
            XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["a", "b", "c", "d", "e"])
            XCTAssertEqual(outcome.totalHidden, 0)
            XCTAssertNil(outcome.missingDataSummary)
        }
        XCTAssertTrue(ResultFilters.none.apply(to: []).kept.isEmpty)
    }

    func testYearFilterCountsItemsWithoutAYear() {
        let filters = ResultFilters(year: .exact(2010))
        let outcome = filters.apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["b"])
        XCTAssertEqual(outcome.hiddenMismatch, 3)
        XCTAssertEqual(outcome.hiddenMissingData, 1)
        XCTAssertEqual(outcome.hiddenWithoutYear, 1)
        XCTAssertEqual(outcome.hiddenWithoutGenre, 0)
        XCTAssertEqual(outcome.missingDataMessages, ["1 risultato senza anno nascosto"])
        XCTAssertEqual(outcome.totalHidden, 4)
    }

    func testYearRangeModesOnSeries() {
        let overlapping = ResultFilters(year: .exact(2015), yearMatch: .overlapping).apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(overlapping.kept), ["d"], "2011–2019 covers 2015")
        let sinceNow = ResultFilters(year: .since(2020), yearMatch: .overlapping).apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(sinceNow.kept), ["e"], "2019– is still running")
        let premiere = ResultFilters(year: .range(2008, 2011)).apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(premiere.kept), ["a", "b", "d"])
        XCTAssertEqual(premiere.hiddenWithoutYear, 1)
    }

    func testGenreFilterIgnoresCaseAndCountsItemsWithoutGenres() {
        let outcome = ResultFilters(genre: "ACTION").apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["c", "d"])
        XCTAssertEqual(outcome.hiddenMismatch, 2)
        XCTAssertEqual(outcome.hiddenMissingData, 1)
        XCTAssertEqual(outcome.hiddenWithoutGenre, 1)
        XCTAssertEqual(outcome.missingDataSummary, "1 risultato senza genere nascosto")

        let accents = ResultFilters(genre: "fantasia").apply(to: [CatalogKit.item("x", genres: ["Fantasía"]),
                                                                  CatalogKit.item("y", genres: ["  "])])
        XCTAssertEqual(CatalogKit.itemIDs(accents.kept), ["x"])
        XCTAssertEqual(accents.hiddenWithoutGenre, 1, "a blank genre is no data")
    }

    func testRatingFilterTreatsZeroAndGarbageAsUnrated() {
        let outcome = ResultFilters(minimumRating: 7.5).apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["a", "d"])
        XCTAssertEqual(outcome.hiddenMismatch, 1, "b has 7,4")
        XCTAssertEqual(outcome.hiddenWithoutRating, 2, "c has none, e has 0")
        XCTAssertEqual(outcome.missingDataMessages, ["2 risultati senza valutazione nascosti"])

        XCTAssertEqual(ResultFilters.rating(of: CatalogKit.item("r", rating: "7,5")), 7.5)
        XCTAssertNil(ResultFilters.rating(of: CatalogKit.item("r", rating: "85")), "not on a 0-10 scale")
        XCTAssertNil(ResultFilters.rating(of: CatalogKit.item("r", rating: "N/A")))
        XCTAssertNil(ResultFilters.rating(of: CatalogKit.item("r", rating: "0")))
        XCTAssertEqual(ResultFilters.rating(of: CatalogKit.item("r", rating: "10")), 10)

        let strict = ResultFilters(minimumRating: 12).apply(to: [CatalogKit.item("ten", rating: "10"),
                                                                 CatalogKit.item("nine", rating: "9.9")])
        XCTAssertEqual(CatalogKit.itemIDs(strict.kept), ["ten"], "a floor above 10 is clamped to 10")
    }

    func testCombinedFiltersSeparateMismatchFromMissingData() {
        let filters = ResultFilters(year: .since(2010), genre: "action", minimumRating: 8)
        XCTAssertTrue(filters.isActive)
        let outcome = filters.apply(to: dataset())
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["d"])
        XCTAssertEqual(outcome.hiddenMismatch, 3, "a: too old, b: rating too low, e: wrong genre")
        XCTAssertEqual(outcome.hiddenMissingData, 1, "c lacks year and rating but is not rejected by what it has")
        XCTAssertEqual(outcome.hiddenWithoutYear, 1)
        XCTAssertEqual(outcome.hiddenWithoutRating, 1)
        XCTAssertEqual(outcome.hiddenWithoutGenre, 0)
        XCTAssertEqual(outcome.totalHidden, 4)
        XCTAssertEqual(outcome.missingDataMessages, ["1 risultato senza anno nascosto", "1 risultato senza valutazione nascosto"])
        XCTAssertEqual(outcome.missingDataSummary, "1 risultato senza anno nascosto · 1 risultato senza valutazione nascosto")
    }

    func testOrderIsPreservedAndOutcomesCombine() {
        let items = dataset()
        let reversed = Array(items.reversed())
        let outcome = ResultFilters(year: .since(2008)).apply(to: reversed)
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["e", "d", "b", "a"])

        let first = ResultFilters(genre: "action").apply(to: items)
        let second = ResultFilters(genre: "action").apply(to: items)
        let total = ResultFilterOutcome.combine([first, second])
        XCTAssertEqual(CatalogKit.itemIDs(total.kept), ["c", "d", "c", "d"])
        XCTAssertEqual(total.hiddenMismatch, 4)
        XCTAssertEqual(total.hiddenWithoutGenre, 2)
        XCTAssertEqual(total.missingDataSummary, "2 risultati senza genere nascosti")
        XCTAssertEqual(ResultFilterOutcome.combine([]).kept.count, 0)
    }

    func testReleaseDateFeedsTheYearFilterWhenReleaseInfoIsMissing() {
        var dated = CatalogKit.item("dated")
        dated.released = Date(timeIntervalSince1970: 1_262_304_000)
        let outcome = ResultFilters(year: .exact(2010)).apply(to: [dated, CatalogKit.item("bare")])
        XCTAssertEqual(CatalogKit.itemIDs(outcome.kept), ["dated"])
        XCTAssertEqual(outcome.hiddenWithoutYear, 1)
    }
}

// MARK: - Discover layout

final class DiscoverLayoutTests: XCTestCase {
    private struct Holder: Decodable {
        var types: [DiscoverTypeSetting]

        private enum CodingKeys: String, CodingKey {
            case types
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            types = container.lossyArray(DiscoverTypeSetting.self, forKey: .types)
        }
    }

    private func setting(_ id: String, _ visible: Bool = true) -> DiscoverTypeSetting {
        return DiscoverTypeSetting(id: id, isVisible: visible)
    }

    func testDecodingIsLenientLikeAppSettings() throws {
        let json = "{\"types\":[{\"id\":\"movie\",\"isVisible\":false},{\"id\":\"series\"},{\"isVisible\":true},"
            + "{\"id\":\"  \"},{\"id\":\"anime\",\"isVisible\":\"no\"},{\"id\":\"tv\",\"isVisible\":0},"
            + "{\"id\":\"radio\",\"isVisible\":\"maybe\"},42,{\"id\":7}]}"
        let holder = try JSONDecoder().decode(Holder.self, from: Data(json.utf8))
        XCTAssertEqual(CatalogKit.ids(holder.types), ["movie", "series", "anime", "tv", "radio", "7"])
        let visibility: [Bool] = holder.types.map { (setting: DiscoverTypeSetting) -> Bool in setting.isVisible }
        XCTAssertEqual(visibility, [false, true, false, false, true, true],
                       "a missing or unreadable flag means visible; entries without an id are dropped")
    }

    func testRoundTripsThroughJSON() throws {
        let original: [DiscoverTypeSetting] = [setting("movie"), setting("anime", false), setting("games")]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([DiscoverTypeSetting].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFirstLaunchShowsEverythingInCanonicalOrder() {
        let state = DiscoverLayout.normalise(stored: [], available: ["tv", "movie", "Games", "series", "movie"])
        XCTAssertEqual(CatalogKit.ids(state.entries), ["movie", "series", "tv", "games"])
        XCTAssertEqual(state.visibleTypes, ["movie", "series", "tv", "games"])
        XCTAssertEqual(CatalogKit.ids(state.exposed), ["movie", "series", "tv", "games"])
        XCTAssertFalse(state.isEverythingHidden)
    }

    func testNothingAvailableMeansNothingExposed() {
        let state = DiscoverLayout.normalise(stored: [], available: [])
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertTrue(state.visibleTypes.isEmpty)
        XCTAssertFalse(state.isEverythingHidden, "nothing to hide: the UI shows the 'no addons' state instead")
        let kept = DiscoverLayout.normalise(stored: [setting("movie")], available: [])
        XCTAssertEqual(CatalogKit.ids(kept.entries), ["movie"], "the choice survives an empty moment")
        XCTAssertTrue(kept.exposed.isEmpty)
        XCTAssertTrue(kept.visibleTypes.isEmpty)
    }

    func testUserOrderAndVisibilityWinNewTypesAreAppendedVisible() {
        let stored: [DiscoverTypeSetting] = [setting("series", false), setting("movie")]
        let state = DiscoverLayout.normalise(stored: stored, available: ["movie", "series", "tv", "anime"])
        XCTAssertEqual(CatalogKit.ids(state.entries), ["series", "movie", "anime", "tv"],
                       "new types follow the user's order, in canonical order among themselves")
        XCTAssertEqual(state.visibleTypes, ["movie", "anime", "tv"])
        XCTAssertEqual(CatalogKit.ids(state.exposed), ["series", "movie", "anime", "tv"], "hidden types stay listed for the settings screen")
        XCTAssertFalse(state.isVisible("series"))
        XCTAssertTrue(state.isVisible("Movie"))
    }

    func testUnavailableTypesAreKeptButNotExposedAndComeBack() {
        let stored: [DiscoverTypeSetting] = [setting("movie"), setting("anime", false), setting("series")]
        let without = DiscoverLayout.normalise(stored: stored, available: ["movie", "series"])
        XCTAssertEqual(CatalogKit.ids(without.entries), ["movie", "anime", "series"])
        XCTAssertEqual(CatalogKit.ids(without.exposed), ["movie", "series"])
        XCTAssertEqual(without.visibleTypes, ["movie", "series"])
        XCTAssertFalse(without.isAvailable("anime"))
        XCTAssertFalse(without.isVisible("anime"))

        // The anime addon is installed again: the user's choice (hidden, second place) is restored.
        let back = DiscoverLayout.normalise(stored: without.entries, available: ["movie", "series", "anime"])
        XCTAssertEqual(CatalogKit.ids(back.exposed), ["movie", "anime", "series"])
        XCTAssertEqual(back.visibleTypes, ["movie", "series"])
        XCTAssertTrue(back.isAvailable("anime"))
        XCTAssertFalse(back.isVisible("anime"))
    }

    func testAliasesDuplicatesAndBlankIdsAreFolded() {
        let stored: [DiscoverTypeSetting] = [setting("Sport", false), setting("sports"), setting("  "), setting("MOVIE"),
                                             setting("movie", false), setting("")]
        let state = DiscoverLayout.normalise(stored: stored, available: ["sports", "movie"])
        XCTAssertEqual(CatalogKit.ids(state.entries), ["sports", "movie"])
        XCTAssertEqual(state.entries[0].isVisible, false, "the first stored entry for a type wins")
        XCTAssertEqual(state.entries[1].isVisible, true)

        let aliasAvailable = DiscoverLayout.normalise(stored: [], available: ["sport"])
        XCTAssertEqual(CatalogKit.ids(aliasAvailable.entries), ["sports"])
        XCTAssertTrue(aliasAvailable.isAvailable("Sport"))
        XCTAssertTrue(aliasAvailable.isAvailable("sports"))
    }

    func testVisibleTypesShortcutMatchesTheState() {
        let stored: [DiscoverTypeSetting] = [setting("tv", false), setting("movie")]
        let available = ["movie", "tv", "series"]
        XCTAssertEqual(DiscoverLayout.visibleTypes(stored: stored, available: available),
                       DiscoverLayout.normalise(stored: stored, available: available).visibleTypes)
        XCTAssertEqual(DiscoverLayout.visibleTypes(stored: stored, available: available), ["movie", "series"])
    }

    func testHidingEverythingIsReported() {
        var state = DiscoverLayout.normalise(stored: [], available: ["movie", "series"])
        state.setVisible(false, for: "Movie")
        XCTAssertFalse(state.isEverythingHidden)
        XCTAssertEqual(state.visibleTypes, ["series"])
        state.setVisible(false, for: "series")
        XCTAssertTrue(state.isEverythingHidden)
        XCTAssertTrue(state.visibleTypes.isEmpty)
        state.setVisible(true, for: "series")
        XCTAssertEqual(state.visibleTypes, ["series"])
    }

    func testVisibilityOfAnUnavailableTypeCanStillBeChanged() {
        var state = DiscoverLayout.normalise(stored: [setting("anime")], available: ["movie"])
        XCTAssertEqual(CatalogKit.ids(state.entries), ["anime", "movie"])
        state.setVisible(false, for: "anime")
        XCTAssertEqual(state.entries[0].isVisible, false)
        let later = DiscoverLayout.normalise(stored: state.entries, available: ["movie", "anime"])
        XCTAssertEqual(later.visibleTypes, ["movie"], "the choice made while the addon was away is honoured")
    }

    func testMovingAvailableTypesKeepsUnavailableOnesInPlace() {
        let stored: [DiscoverTypeSetting] = [setting("movie"), setting("ghost", false), setting("series"), setting("tv")]
        let base = DiscoverLayout.normalise(stored: stored, available: ["movie", "series", "tv"])
        XCTAssertEqual(CatalogKit.ids(base.entries), ["movie", "ghost", "series", "tv"])

        var toFront = base
        toFront.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(CatalogKit.ids(toFront.exposed), ["series", "movie", "tv"])
        XCTAssertEqual(CatalogKit.ids(toFront.entries), ["series", "ghost", "movie", "tv"])
        XCTAssertEqual(toFront.entries[1].isVisible, false, "the unavailable entry is untouched")

        var toEnd = base
        toEnd.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(CatalogKit.ids(toEnd.exposed), ["series", "tv", "movie"])

        var oneDown = base
        oneDown.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(CatalogKit.ids(oneDown.exposed), ["series", "movie", "tv"], "same semantics as List.onMove")

        var several = base
        several.move(fromOffsets: IndexSet(integersIn: 0..<2), toOffset: 3)
        XCTAssertEqual(CatalogKit.ids(several.exposed), ["tv", "movie", "series"])

        var invalid = base
        invalid.move(fromOffsets: IndexSet(integer: 9), toOffset: 0)
        XCTAssertEqual(invalid, base)
        invalid.move(fromOffsets: IndexSet(integer: 0), toOffset: 99)
        XCTAssertEqual(CatalogKit.ids(invalid.exposed), ["series", "tv", "movie"], "an out-of-range destination clamps to the end")
        invalid.move(fromOffsets: IndexSet(integer: 2), toOffset: -5)
        XCTAssertEqual(CatalogKit.ids(invalid.exposed), ["movie", "series", "tv"], "a negative destination clamps to the start")
    }

    func testSelectionSurvivesOnlyWhileVisible() {
        XCTAssertEqual(DiscoverLayout.resolveSelection(current: "series", visible: ["movie", "series"]), "series")
        XCTAssertEqual(DiscoverLayout.resolveSelection(current: "Series", visible: ["movie", "series"]), "series")
        XCTAssertEqual(DiscoverLayout.resolveSelection(current: "tv", visible: ["movie", "series"]), "movie")
        XCTAssertEqual(DiscoverLayout.resolveSelection(current: nil, visible: ["movie", "series"]), "movie")
        XCTAssertNil(DiscoverLayout.resolveSelection(current: "movie", visible: []))
    }

    func testLayoutFollowsAddonsComingAndGoing() {
        let cinemeta = CatalogKit.cinemetaLike()
        let radio = CatalogKit.handle("radio", catalogs: [CatalogKit.catalog("radio", "top"), CatalogKit.catalog("music", "hits")])

        let first = CatalogCapabilities.build(handles: [cinemeta])
        var state = DiscoverLayout.normalise(stored: [], available: CatalogKit.typeIDs(first.availableTypes))
        XCTAssertEqual(state.visibleTypes, ["movie", "series"])
        state.setVisible(false, for: "series")
        let persisted = state.entries

        let second = CatalogCapabilities.build(handles: [cinemeta, radio])
        state = DiscoverLayout.normalise(stored: persisted, available: CatalogKit.typeIDs(second.availableTypes))
        XCTAssertEqual(CatalogKit.ids(state.exposed), ["movie", "series", "music", "radio"])
        XCTAssertEqual(state.visibleTypes, ["movie", "music", "radio"], "new types appear visible, series stays hidden")

        let third = CatalogCapabilities.build(handles: [radio])
        state = DiscoverLayout.normalise(stored: state.entries, available: CatalogKit.typeIDs(third.availableTypes))
        XCTAssertEqual(state.visibleTypes, ["music", "radio"])
        XCTAssertEqual(CatalogKit.ids(state.entries), ["movie", "series", "music", "radio"],
                       "the removed addon's types are remembered")
    }
}
