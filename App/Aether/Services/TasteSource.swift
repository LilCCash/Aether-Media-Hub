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
                // Two pages per genre: one from far down the list (older films, the classics, the cult ones) and one nearer the top.
                // Only the top of a popularity list would be all recent films.
                let skips: [Int?] = catalog.extraProperty("skip") != nil ? [Int.random(in: 8...60) * 20, Int.random(in: 0...12) * 20] : [nil]
                for genre in wanted {
                    for skip in skips {
                        var extra: [ExtraValue] = []
                        if let genre = genre { extra.append(ExtraValue(name: "genre", value: genre)) }
                        if let skip = skip, skip > 0 { extra.append(ExtraValue(name: "skip", value: String(skip))) }
                        guard let result = try? await env.service.catalog(ref, extra: extra) else { continue }
                        found += result.items.map { candidate($0) }
                    }
                }
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    /// The films in an order that mixes the decades: one from each decade in turn, each decade shuffled, so that the old ones come up as
    /// often as the new ones instead of the newest filling the pile.
    static func varied(_ items: [TasteCandidate]) -> [TasteCandidate] {
        func decade(_ item: TasteCandidate) -> Int {
            guard let year = item.year, year.count >= 4, let value = Int(year.prefix(4)) else { return 0 }
            return value / 10 * 10
        }
        var buckets = Dictionary(grouping: items, by: decade).mapValues { $0.shuffled() }
        var order = buckets.keys.shuffled()
        var result: [TasteCandidate] = []
        while !buckets.isEmpty {
            for key in order {
                guard var list = buckets[key], !list.isEmpty else { continue }
                result.append(list.removeFirst())
                buckets[key] = list.isEmpty ? nil : list
            }
            order = order.filter { buckets[$0] != nil }
        }
        return result
    }
}
