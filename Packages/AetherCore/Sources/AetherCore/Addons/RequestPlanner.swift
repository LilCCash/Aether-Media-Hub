import Foundation

/// A catalog offered by one installed addon.
public struct CatalogRef: Hashable, Identifiable, Sendable {
    public var addonID: UUID
    public var addonName: String
    public var catalog: ManifestCatalog

    public init(addonID: UUID, addonName: String, catalog: ManifestCatalog) {
        self.addonID = addonID
        self.addonName = addonName
        self.catalog = catalog
    }

    public var id: String { return "\(addonID.uuidString)/\(catalog.key)" }
    public var type: String { return catalog.type }
    public var title: String { return catalog.name }
}

/// Decides *which* addons/catalogs may be asked for what, from manifests alone (no network).
public enum RequestPlanner {
    /// Canonical ordering of well known types; unknown types follow alphabetically.
    private static let typeOrder = [ContentType.movie, ContentType.series, ContentType.anime,
                                    ContentType.tv, ContentType.channel, ContentType.other]

    public static func typeRank(_ type: String) -> Int {
        return typeOrder.firstIndex(of: type) ?? typeOrder.count
    }

    /// Catalogs listable as a plain feed (no mandatory extra such as `search`), in addon order.
    public static func feedCatalogs(handles: [AddonHandle], type: String? = nil,
                                    includeHidden: Bool = false) -> [CatalogRef] {
        var result: [CatalogRef] = []
        for handle in handles {
            let addon = handle.addon
            for catalog in addon.manifest.catalogs {
                if let type = type, catalog.type != type { continue }
                if !catalog.isExtraSupported([]) { continue }
                if !includeHidden && !addon.isCatalogVisible(catalog) { continue }
                result.append(CatalogRef(addonID: addon.id, addonName: addon.displayName, catalog: catalog))
            }
        }
        return result
    }

    /// Catalogs that declare the `search` extra and can answer it (other required extras would make them unusable).
    public static func searchCatalogs(handles: [AddonHandle], type: String? = nil) -> [CatalogRef] {
        let probe = [ExtraValue(name: "search", value: "x")]
        var result: [CatalogRef] = []
        for handle in handles {
            for catalog in handle.addon.manifest.catalogs {
                if let type = type, catalog.type != type { continue }
                if catalog.isExtraSupported(probe) {
                    result.append(CatalogRef(addonID: handle.addon.id, addonName: handle.addon.displayName, catalog: catalog))
                }
            }
        }
        return result
    }

    /// Addons whose manifest allows the given resource request, in user order.
    public static func addons(for path: ResourcePath, handles: [AddonHandle]) -> [AddonHandle] {
        return handles.filter { $0.addon.manifest.supports(path) }
    }

    /// Content types for which at least one *feed* catalog exists. No type is listed unless something can fill it.
    public static func availableTypes(handles: [AddonHandle]) -> [String] {
        var seen = Set<String>()
        var types: [String] = []
        for ref in feedCatalogs(handles: handles) {
            if seen.insert(ref.type).inserted { types.append(ref.type) }
        }
        return types.sorted { lhs, rhs in
            let l = typeRank(lhs)
            let r = typeRank(rhs)
            return l == r ? lhs < rhs : l < r
        }
    }

    /// Genres offered across feed catalogs of a type (union of `genre` extra options).
    public static func genreOptions(handles: [AddonHandle], type: String) -> [String] {
        var seen = Set<String>()
        var genres: [String] = []
        for ref in feedCatalogs(handles: handles, type: type) {
            for genre in ref.catalog.genreOptions where seen.insert(genre).inserted {
                genres.append(genre)
            }
        }
        return genres
    }

    /// True when at least one enabled addon can supply streams for the item (UI hides the Play button otherwise).
    public static func canProvideStreams(type: String, id: String, handles: [AddonHandle]) -> Bool {
        let path = ResourcePath(resource: ResourceName.stream, type: type, id: id)
        return !addons(for: path, handles: handles).isEmpty
    }

    public static func friendlyTypeName(_ type: String) -> String {
        switch type {
        case ContentType.movie: return "Film"
        case ContentType.series: return "Serie TV"
        case ContentType.anime: return "Anime"
        case ContentType.channel: return "Canali"
        case ContentType.tv: return "TV in diretta"
        case ContentType.other: return "Altro"
        default: return type.prefix(1).uppercased() + type.dropFirst()
        }
    }
}
