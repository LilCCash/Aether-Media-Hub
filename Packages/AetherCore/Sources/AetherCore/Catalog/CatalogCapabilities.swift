import Foundation

// What the installed addons can actually serve, computed from manifests alone (no network), so Search and Discover
// never offer a type, a genre or a filter that nothing can answer. `CatalogCapabilities.build(handles:)` is a cheap
// pure function over value types: call it again whenever the set of addons, their enabled state, their hidden
// catalogs or the adult setting changes, and compare with `==` to know whether the UI has to refresh.

// MARK: - Per-type capability

/// Everything known about one content type across the installed addons.
///
/// Spellings are folded for *identity* (`id` is `ContentTypes.canonicalID`: "Sport" and "sports" are one entry) but
/// never for *requests*: an addon is always asked with the spelling its own manifest declares (`memberIDs`).
public struct CatalogTypeCapability: Hashable, Identifiable, Sendable {
    /// Canonical id, stable across addon order and spelling: safe to persist and to use as a selection.
    public var id: String
    /// Exact spellings declared by catalogs, in the order they were met. Never empty.
    public var memberIDs: [String]
    /// Italian title (known types) or the capitalised spelling (unknown types).
    public var title: String
    public var symbolName: String
    /// False for types without a dedicated name; they are still listed.
    public var isKnown: Bool
    /// Visible catalogs of this type that can be listed without any user input.
    public var feedCatalogCount: Int
    /// Catalogs of this type that can answer a search (and need nothing else).
    public var searchCatalogCount: Int
    /// Of `searchCatalogCount`: catalogs whose manifest declares both `search` and `genre`.
    public var searchWithGenreCatalogCount: Int
    /// Genres Discover can request from the visible feed catalogs of this type (union of their `genre` options).
    public var feedGenres: [String]
    /// Genres worth offering as a search filter: union of the options of every usable catalog of this type.
    /// Empty when the type is not searchable. The filter is always verified locally (see `SearchPlan`).
    public var searchGenres: [String]

    public init(id: String, memberIDs: [String], title: String, symbolName: String, isKnown: Bool,
                feedCatalogCount: Int = 0, searchCatalogCount: Int = 0, searchWithGenreCatalogCount: Int = 0,
                feedGenres: [String] = [], searchGenres: [String] = []) {
        self.id = id
        self.memberIDs = memberIDs
        self.title = title
        self.symbolName = symbolName
        self.isKnown = isKnown
        self.feedCatalogCount = feedCatalogCount
        self.searchCatalogCount = searchCatalogCount
        self.searchWithGenreCatalogCount = searchWithGenreCatalogCount
        self.feedGenres = feedGenres
        self.searchGenres = searchGenres
    }

    /// Discover can list something for this type.
    public var hasFeed: Bool {
        return feedCatalogCount > 0
    }

    /// Search can ask at least one catalog for this type.
    public var isSearchable: Bool {
        return searchCatalogCount > 0
    }

    /// At least one searchable catalog declares `search` and `genre`, so the genre can be *sent* along with the query.
    /// Whether the server honours the combination is not known: the result is verified locally either way.
    public var canSendGenreWithSearch: Bool {
        return searchWithGenreCatalogCount > 0
    }

    /// True when `rawType` (any spelling) is this type.
    public func owns(_ rawType: String) -> Bool {
        return ContentTypes.canonicalID(rawType) == id
    }
}

// MARK: - Capabilities

/// The usable catalogs of all enabled addons, grouped by content type.
public struct CatalogCapabilities: Equatable, Sendable {
    /// Every type that has at least one usable (feed or searchable) catalog, in canonical order.
    public var types: [CatalogTypeCapability]
    /// Visible plain-feed catalogs in addon order.
    public var feedCatalogs: [CatalogRef]
    /// Catalogs that can answer a search in addon order. Catalogs the user hid from Home/Discover are still
    /// searched: hiding is about browsing, not about search.
    public var searchCatalogs: [CatalogRef]

    public init(types: [CatalogTypeCapability], feedCatalogs: [CatalogRef], searchCatalogs: [CatalogRef]) {
        self.types = types
        self.feedCatalogs = feedCatalogs
        self.searchCatalogs = searchCatalogs
    }

    public static let empty = CatalogCapabilities(types: [], feedCatalogs: [], searchCatalogs: [])

    // MARK: Build

    /// Computes the capabilities of `handles`.
    ///
    /// - Disabled addons and addons that need to be reinstalled are ignored even if the caller passed them.
    /// - `hideAdultCatalogs` drops addons whose manifest declares `behaviorHints.adult`. It defaults to `true`:
    ///   the safe choice when a caller forgets to pass the user's setting.
    /// - A type is listed only when something can fill it: a catalog that needs a user-supplied extra other than
    ///   `search` (Cinemeta's `last-videos`, or `year` whose required `genre` is really a list of years) counts for nothing.
    public static func build(handles: [AddonHandle], hideAdultCatalogs: Bool = true) -> CatalogCapabilities {
        var usable: [AddonHandle] = []
        for handle in handles {
            let addon = handle.addon
            if !addon.isEnabled || addon.needsReinstall { continue }
            if hideAdultCatalogs && addon.manifest.behaviorHints.adult { continue }
            usable.append(handle)
        }

        let feeds = RequestPlanner.feedCatalogs(handles: usable)
        let searches = RequestPlanner.searchCatalogs(handles: usable)

        var accumulators: [String: TypeAccumulator] = [:]
        for ref in feeds {
            let key = ContentTypes.canonicalID(ref.type)
            var accumulator = accumulators[key] ?? TypeAccumulator()
            accumulator.addMember(ref.type)
            accumulator.feedCount += 1
            accumulator.feedGenreLists.append(genreOptions(of: ref.catalog))
            accumulators[key] = accumulator
        }
        for ref in searches {
            let key = ContentTypes.canonicalID(ref.type)
            var accumulator = accumulators[key] ?? TypeAccumulator()
            accumulator.addMember(ref.type)
            accumulator.searchCount += 1
            if supportsSearchWithGenre(ref.catalog) {
                accumulator.searchWithGenreCount += 1
            }
            accumulator.searchGenreLists.append(genreOptions(of: ref.catalog))
            accumulators[key] = accumulator
        }

        var types: [CatalogTypeCapability] = []
        let orderedKeys = ContentTypes.sorted(Array(accumulators.keys))
        for key in orderedKeys {
            guard let accumulator = accumulators[key] else { continue }
            let firstSpelling = accumulator.members.first ?? key
            let info = ContentTypes.info(for: firstSpelling)
            let isSearchable = accumulator.searchCount > 0
            var searchLists: [[String]] = []
            if isSearchable {
                searchLists.append(contentsOf: accumulator.feedGenreLists)
                searchLists.append(contentsOf: accumulator.searchGenreLists)
            }
            let capability = CatalogTypeCapability(
                id: key,
                memberIDs: accumulator.members,
                title: info.title,
                symbolName: info.symbolName,
                isKnown: info.isKnown,
                feedCatalogCount: accumulator.feedCount,
                searchCatalogCount: accumulator.searchCount,
                searchWithGenreCatalogCount: accumulator.searchWithGenreCount,
                feedGenres: GenreNames.mergedSorted(accumulator.feedGenreLists),
                searchGenres: GenreNames.mergedSorted(searchLists))
            types.append(capability)
        }
        return CatalogCapabilities(types: types, feedCatalogs: feeds, searchCatalogs: searches)
    }

    // MARK: Queries

    public var isEmpty: Bool {
        return types.isEmpty
    }

    /// Types Discover can list (at least one visible feed catalog), in canonical order.
    /// Use `DiscoverLayout` to apply the user's own order and visibility on top.
    public var availableTypes: [CatalogTypeCapability] {
        return types.filter { (entry: CatalogTypeCapability) -> Bool in entry.hasFeed }
    }

    /// Types Search can query (at least one searchable catalog), in canonical order.
    public var searchableTypes: [CatalogTypeCapability] {
        return types.filter { (entry: CatalogTypeCapability) -> Bool in entry.isSearchable }
    }

    /// True when at least one catalog can answer a search.
    public var canSearch: Bool {
        return !searchCatalogs.isEmpty
    }

    /// The entry for `type` in any spelling.
    public func capability(forType type: String) -> CatalogTypeCapability? {
        let key = ContentTypes.canonicalID(type)
        return types.first(where: { (entry: CatalogTypeCapability) -> Bool in entry.id == key })
    }

    /// Visible feed catalogs of `type` (any spelling, aliases included), in addon order.
    public func catalogsToBrowse(forType type: String) -> [CatalogRef] {
        let key = ContentTypes.canonicalID(type)
        return feedCatalogs.filter { (ref: CatalogRef) -> Bool in ContentTypes.canonicalID(ref.type) == key }
    }

    /// Searchable catalogs of `type`; every searchable catalog when `type` is nil.
    public func catalogsToSearch(forType type: String?) -> [CatalogRef] {
        guard let type = type else { return searchCatalogs }
        let key = ContentTypes.canonicalID(type)
        return searchCatalogs.filter { (ref: CatalogRef) -> Bool in ContentTypes.canonicalID(ref.type) == key }
    }

    /// Genres Discover can request for `type`.
    public func browseGenres(forType type: String) -> [String] {
        guard let found = capability(forType: type) else { return [] }
        return found.feedGenres
    }

    /// Genres to offer as a search filter: those of `type`, or the union over every searchable type when `type` is nil.
    /// A type that is not searchable offers none.
    public func filterGenres(forType type: String?) -> [String] {
        if let type = type {
            guard let found = capability(forType: type), found.isSearchable else { return [] }
            return found.searchGenres
        }
        var lists: [[String]] = []
        for entry in searchableTypes {
            lists.append(entry.searchGenres)
        }
        return GenreNames.mergedSorted(lists)
    }

    // MARK: Catalog helpers

    /// True when the manifest accepts `search` and `genre` in the same request, which is exactly what
    /// `AddonService.catalog` checks before sending. It says nothing about what the server does with the pair.
    public static func supportsSearchWithGenre(_ catalog: ManifestCatalog) -> Bool {
        let probe = [ExtraValue(name: "search", value: "x"), ExtraValue(name: "genre", value: "x")]
        return catalog.isExtraSupported(probe)
    }

    /// Genre options of a catalog that are really genres: a required `genre` extra is a mandatory choice the user
    /// cannot skip, and a list made only of years (Cinemeta's `year` catalog) is not a list of genres.
    static func genreOptions(of catalog: ManifestCatalog) -> [String] {
        guard let property = catalog.extraProperty("genre") else { return [] }
        if property.isRequired { return [] }
        if looksLikeYearList(property.options) { return [] }
        return property.options
    }

    static func looksLikeYearList(_ options: [String]) -> Bool {
        if options.isEmpty { return false }
        for option in options {
            let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count == 4, let value = Int(trimmed) else { return false }
            if !ReleaseYears.plausibleRange.contains(value) { return false }
        }
        return true
    }
}

private struct TypeAccumulator {
    var members: [String] = []
    var feedCount: Int = 0
    var searchCount: Int = 0
    var searchWithGenreCount: Int = 0
    var feedGenreLists: [[String]] = []
    var searchGenreLists: [[String]] = []

    mutating func addMember(_ spelling: String) {
        if !members.contains(spelling) {
            members.append(spelling)
        }
    }
}

// MARK: - Search plan

/// Whether the genre may be sent to the addon together with the query.
public enum SearchGenreStrategy: String, Sendable {
    /// Send `genre` next to `search` when the catalog's manifest declares both (and, if it lists genre options,
    /// the wanted genre is one of them). The answer is still checked locally.
    case sendWhenDeclared
    /// Never send `genre` with a search; filter locally only. Pick this if live checks show that an addon answers
    /// `search`+`genre` requests with something other than a filtered search.
    case localOnly
}

/// What happens to the genre filter for one catalog of a search.
public enum SearchGenreHandling: String, Sendable {
    /// No genre was asked for.
    case notRequested
    /// The extra is sent, but nothing guarantees the server applied it: the result is filtered locally anyway.
    case sentAndVerifiedLocally
    /// The catalog cannot take the genre next to a search (or the genre is not one of its options): local filter only.
    case localOnly
}

/// One request of a planned search: a catalog and exactly the extras to send to it.
public struct SearchPlanEntry: Hashable, Identifiable, Sendable {
    public var ref: CatalogRef
    /// Always starts with `search`; `genre` follows when it is sent.
    public var extra: [ExtraValue]
    public var genreHandling: SearchGenreHandling

    public init(ref: CatalogRef, extra: [ExtraValue], genreHandling: SearchGenreHandling) {
        self.ref = ref
        self.extra = extra
        self.genreHandling = genreHandling
    }

    public var id: String {
        return ref.id
    }

    /// The resource request this entry stands for; `manifest.supports(path)` holds by construction.
    public var path: ResourcePath {
        return ResourcePath(resource: ResourceName.catalog, type: ref.catalog.type, id: ref.catalog.id, extra: extra)
    }
}

/// Decides, from manifests alone, which catalogs a search asks and with which extras, and which filters Aether must
/// apply to the answers. Nothing is pretended: a filter no catalog can honour is applied locally and the UI is told
/// how many results the missing data hid (`ResultFilterOutcome`).
public struct SearchPlan: Equatable, Sendable {
    /// Whitespace-normalised query (`SearchService.normalisedQuery`). Empty means "nothing to search".
    public var query: String
    /// Canonical id of the requested type; nil searches every type.
    public var typeID: String?
    /// The requested genre, cleaned; nil when none (or blank).
    public var genre: String?
    /// One entry per catalog to ask, in addon order. Empty when the query is empty or no catalog fits.
    public var entries: [SearchPlanEntry]
    /// Filters to apply to every answer: genre (always, even when it was also sent), plus year and rating, which
    /// search extras cannot express.
    public var localFilters: ResultFilters

    public init(query: String, typeID: String?, genre: String?, entries: [SearchPlanEntry], localFilters: ResultFilters) {
        self.query = query
        self.typeID = typeID
        self.genre = genre
        self.entries = entries
        self.localFilters = localFilters
    }

    public var isRunnable: Bool {
        return !query.isEmpty && !entries.isEmpty
    }

    /// Entries where the genre travels to the addon.
    public var genreSentCount: Int {
        return entries.filter { (entry: SearchPlanEntry) -> Bool in
            entry.genreHandling == .sentAndVerifiedLocally
        }.count
    }

    /// Entries where only Aether can filter by genre.
    public var genreLocalOnlyCount: Int {
        return entries.filter { (entry: SearchPlanEntry) -> Bool in
            entry.genreHandling == .localOnly
        }.count
    }

    /// Applies the local filters to one catalog's answer.
    public func filter(_ items: [MetaItem]) -> ResultFilterOutcome {
        return localFilters.apply(to: items)
    }

    /// Italian explanation for an empty plan; nil when the plan can run or there is no query yet.
    public var emptyReason: String? {
        if query.isEmpty || !entries.isEmpty { return nil }
        if let typeID = typeID {
            return "Nessun addon attivo cerca tra i contenuti «\(ContentTypes.title(for: typeID))»."
        }
        return "Nessun addon attivo dichiara la ricerca nei suoi cataloghi."
    }

    /// Italian footnote about how the genre filter is applied; nil when no genre was requested.
    public var genreNotice: String? {
        if genre == nil || entries.isEmpty { return nil }
        if genreLocalOnlyCount > 0 {
            return "Il filtro per genere è applicato da Aether sui risultati ricevuti: non tutti gli addon lo supportano nella ricerca."
        }
        return "Il genere è richiesto agli addon e ricontrollato sui risultati ricevuti."
    }

    /// Builds the plan.
    ///
    /// - Parameters:
    ///   - query: raw text typed by the user; whitespace is normalised.
    ///   - type: type to restrict the search to, any spelling; nil or blank means every type.
    ///   - genre: genre to filter by; nil or blank means none.
    ///   - year, yearMatch, minimumRating: always local, added to `localFilters`.
    ///   - capabilities: from `CatalogCapabilities.build(handles:)`.
    public static func make(query rawQuery: String, type: String? = nil, genre rawGenre: String? = nil,
                            year: YearFilter? = nil, yearMatch: YearMatch = .premiere,
                            minimumRating: Double? = nil, capabilities: CatalogCapabilities,
                            genreStrategy: SearchGenreStrategy = .sendWhenDeclared) -> SearchPlan {
        let query = SearchService.normalisedQuery(rawQuery)

        var typeID: String?
        if let type = type {
            let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                typeID = ContentTypes.canonicalID(trimmed)
            }
        }

        var genre: String?
        if let rawGenre = rawGenre {
            let cleaned = GenreNames.clean(rawGenre)
            if !cleaned.isEmpty {
                genre = cleaned
            }
        }

        let filters = ResultFilters(year: year, yearMatch: yearMatch, genre: genre, minimumRating: minimumRating)

        var entries: [SearchPlanEntry] = []
        if !query.isEmpty {
            let candidates = capabilities.catalogsToSearch(forType: typeID)
            for ref in candidates {
                var extra: [ExtraValue] = [ExtraValue(name: "search", value: query)]
                var handling = SearchGenreHandling.notRequested
                if let wanted = genre {
                    handling = .localOnly
                    if genreStrategy == .sendWhenDeclared,
                       let value = serverGenreValue(for: ref.catalog, wanted: wanted) {
                        extra.append(ExtraValue(name: "genre", value: value))
                        handling = .sentAndVerifiedLocally
                    }
                }
                entries.append(SearchPlanEntry(ref: ref, extra: extra, genreHandling: handling))
            }
        }
        return SearchPlan(query: query, typeID: typeID, genre: genre, entries: entries, localFilters: filters)
    }

    /// The value to send as `genre` to `catalog`, or nil when it must not be sent: the manifest does not accept
    /// `search`+`genre`, or it lists genre options and `wanted` is not one of them. When options are listed the
    /// catalog's own spelling is sent ("Action", not "action"): servers compare options literally.
    static func serverGenreValue(for catalog: ManifestCatalog, wanted: String) -> String? {
        if !CatalogCapabilities.supportsSearchWithGenre(catalog) { return nil }
        let options = catalog.genreOptions
        if options.isEmpty { return wanted }
        let wantedKey = GenreNames.key(wanted)
        for option in options {
            if GenreNames.key(option) == wantedKey {
                return option
            }
        }
        return nil
    }
}

// MARK: - Running a plan

/// One catalog's answer to a planned search, already filtered.
public struct PlannedSearchUpdate: Sendable {
    /// `row.items` are the items that passed `SearchPlan.localFilters`, limited to the per-catalog cap.
    public var row: SearchRow
    /// Counts for the UI ("3 risultati senza anno nascosti"). `filtering.kept` holds every kept item, before the cap.
    public var filtering: ResultFilterOutcome
    public var completed: Int
    public var total: Int
}

/// Runs a `SearchPlan`: one request per entry, concurrently, results streamed as each catalog answers. Cancelling the
/// consumer cancels the requests, as in `SearchService.search`.
public final class PlannedSearch: Sendable {
    private let service: AddonService

    public init(service: AddonService) {
        self.service = service
    }

    public func run(_ plan: SearchPlan, perCatalogLimit: Int = 40) -> AsyncStream<PlannedSearchUpdate> {
        return AsyncStream { continuation in
            guard plan.isRunnable else {
                continuation.finish()
                return
            }
            let task = Task {
                let total = plan.entries.count
                var completed = 0
                await withTaskGroup(of: PlannedSearchUpdate.self) { group in
                    for entry in plan.entries {
                        group.addTask { [service = self.service] in
                            return await PlannedSearch.execute(entry, plan: plan, service: service,
                                                               limit: perCatalogLimit)
                        }
                    }
                    for await update in group {
                        completed += 1
                        var numbered = update
                        numbered.completed = completed
                        numbered.total = total
                        continuation.yield(numbered)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func execute(_ entry: SearchPlanEntry, plan: SearchPlan, service: AddonService,
                                limit: Int) async -> PlannedSearchUpdate {
        do {
            let result = try await service.catalog(entry.ref, extra: entry.extra)
            let outcome = plan.filter(result.items)
            let items = Array(outcome.kept.prefix(max(0, limit)))
            let row = SearchRow(ref: entry.ref, items: items, error: nil, isStale: result.isStale)
            return PlannedSearchUpdate(row: row, filtering: outcome, completed: 0, total: 0)
        } catch {
            let row = SearchRow(ref: entry.ref, items: [], error: AddonService.normalise(error), isStale: false)
            return PlannedSearchUpdate(row: row, filtering: ResultFilterOutcome(kept: []), completed: 0, total: 0)
        }
    }
}
