import Foundation
import AetherCore

/// Where the taste game (and the invitations that suggest a title) find films: the genre catalogs of the viewer's own addons.
@MainActor
enum TasteSource {
    static func candidate(_ item: MetaItem) -> TasteCandidate {
        return TasteCandidate(id: item.id, type: item.type, name: item.name, poster: item.poster, year: item.releaseInfo, genres: item.genres,
                              overview: item.description, cast: item.cast)
    }

    /// Films of the given genres (`ProfileGenre` raw values; none = what is popular), from the first addon catalog that offers a genre filter.
    static func fetch(env: AppEnvironment, addons: AddonStore, genres: [String]) async -> [TasteCandidate] {
        let names = genres.compactMap { ProfileGenre(rawValue: $0)?.cinemeta }
        for addon in addons.enabledAddons {
            for catalog in addon.manifest.catalogs where ContentTypes.canonicalID(catalog.type) == "movie" && catalog.extraProperty("genre") != nil {
                let searchOnly = catalog.supportsSearch && !catalog.isPlainFeed && DiscoverFiltering.serverFilter(for: catalog) == nil
                guard !searchOnly else { continue }
                let ref = CatalogRef(addonID: addon.id, addonName: addon.displayName, catalog: catalog)
                var found: [TasteCandidate] = []
                let wanted: [String?] = names.isEmpty ? [nil] : names.shuffled().prefix(4).map { Optional($0) }
                for genre in wanted {
                    var extra: [ExtraValue] = []
                    if let genre = genre { extra.append(ExtraValue(name: "genre", value: genre)) }
                    if catalog.extraProperty("skip") != nil, Bool.random() { extra.append(ExtraValue(name: "skip", value: String(Int.random(in: 1...4) * 20))) }
                    guard let result = try? await env.service.catalog(ref, extra: extra) else { continue }
                    found += result.items.map { candidate($0) }
                }
                if !found.isEmpty { return found }
            }
        }
        return []
    }
}
