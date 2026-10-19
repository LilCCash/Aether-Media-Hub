import Foundation

public struct CatalogPage: Sendable {
    /// Items not seen in earlier pages.
    public var newItems: [MetaItem]
    public var hasMore: Bool
    public var isStale: Bool
}

/// Stateful pagination over one addon catalog (`skip` extra), with de-duplication and loop protection.
///
/// Stremio's convention is "skip = number of items already loaded"; an addon returning fewer items than a
/// full page signals the end. Because page size is not declared in manifests we stop when a page is empty
/// or contributes no new ids (some addons ignore `skip` and would otherwise loop forever).
public actor CatalogPager {
    public let ref: CatalogRef
    private let service: AddonService
    private var extra: [ExtraValue]
    private var seenIDs = Set<String>()
    private var rawCount = 0
    private var exhausted = false
    private var loading = false
    private var generation = 0

    public private(set) var items: [MetaItem] = []

    public init(ref: CatalogRef, service: AddonService, extra: [ExtraValue] = []) {
        self.ref = ref
        self.service = service
        self.extra = extra
    }

    public var hasMore: Bool { return !exhausted }
    public var isLoading: Bool { return loading }

    /// Replaces the filters (e.g. a genre) and starts over.
    public func reset(extra newExtra: [ExtraValue]) {
        generation += 1
        extra = newExtra
        seenIDs = []
        rawCount = 0
        exhausted = false
        loading = false
        items = []
    }

    /// Loads the next page. Concurrent calls collapse: while a load is in flight further calls return an empty page.
    public func loadNext(mode: AddonClient.LoadMode = .normal) async throws -> CatalogPage {
        if exhausted { return CatalogPage(newItems: [], hasMore: false, isStale: false) }
        if loading { return CatalogPage(newItems: [], hasMore: true, isStale: false) }
        loading = true
        let myGeneration = generation

        var requestExtra = extra
        if rawCount > 0 && ref.catalog.supportsSkip {
            requestExtra.append(ExtraValue(name: "skip", value: String(rawCount)))
        }

        do {
            let result = try await service.catalog(ref, extra: requestExtra, mode: mode)
            // `reset` may have run while awaiting: discard the stale answer.
            guard myGeneration == generation else {
                return CatalogPage(newItems: [], hasMore: true, isStale: false)
            }
            loading = false
            rawCount += result.items.count
            var fresh: [MetaItem] = []
            for item in result.items where seenIDs.insert(item.id).inserted {
                fresh.append(item)
            }
            items.append(contentsOf: fresh)
            let canPage = ref.catalog.supportsSkip
            if result.items.isEmpty || fresh.isEmpty || !canPage {
                exhausted = true
            }
            return CatalogPage(newItems: fresh, hasMore: !exhausted, isStale: result.isStale)
        } catch {
            if myGeneration == generation { loading = false }
            throw error
        }
    }
}
