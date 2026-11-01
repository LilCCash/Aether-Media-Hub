import Foundation

/// Trasforma i titoli di Trakt in titoli apribili in Aether: Trakt non ha immagini, quindi nome, trama e locandina vengono da TMDB
/// (se c'è la chiave), nella lingua dell'utente.
public final class TraktCatalogService: @unchecked Sendable {
    private struct Resolved {
        var name: String?
        var overview: String?
        var poster: String?
        var background: String?
    }

    private let trakt: TraktClient
    private let tmdb: TMDBClient
    private let lock = NSLock()
    private var cache: [String: Resolved] = [:]

    public init(trakt: TraktClient, tmdb: TMDBClient) {
        self.trakt = trakt
        self.tmdb = tmdb
    }

    public func items(for kind: TraktCatalogKind, limit: Int, language: String) async throws -> [TraktShelfItem] {
        let titles = try await trakt.titles(for: kind, limit: limit)
        return await shelf(titles, language: language)
    }

    public func lists() async throws -> [TraktListInfo] { return try await trakt.lists() }

    public func listItems(_ list: TraktListInfo, limit: Int, language: String) async throws -> [TraktShelfItem] {
        return await shelf(try await trakt.listItems(list, limit: limit), language: language)
    }

    /// Dà a ogni titolo nome, locandina e trama; chi non ha il codice IMDb (quello che usano gli addon) viene saltato.
    public func shelf(_ titles: [TraktTitle], language: String) async -> [TraktShelfItem] {
        let usable = titles.filter { $0.imdb != nil }
        return await withTaskGroup(of: (Int, TraktShelfItem?).self) { (group: inout TaskGroup<(Int, TraktShelfItem?)>) -> [TraktShelfItem] in
            for (index, title) in usable.enumerated() {
                group.addTask { [self] in
                    guard let imdb = title.imdb else { return (index, nil) }
                    let resolved = await self.resolve(title, language: language)
                    let meta = MetaItem(id: imdb, type: title.kind == .movie ? "movie" : "series", name: resolved.name ?? title.title,
                                        poster: resolved.poster, background: resolved.background, description: resolved.overview,
                                        releaseInfo: title.year.map { String($0) },
                                        externalIDs: ExternalIDs(imdb: imdb, tmdb: title.tmdb, tvdb: title.tvdb))
                    return (index, TraktShelfItem(meta: meta, note: title.note))
                }
            }
            var collected: [(Int, TraktShelfItem)] = []
            for await (index, item) in group {
                if let item = item { collected.append((index, item)) }
            }
            var seen = Set<String>()
            return collected.sorted { (a: (Int, TraktShelfItem), b: (Int, TraktShelfItem)) -> Bool in a.0 < b.0 }
                .map { $0.1 }.filter { seen.insert($0.id).inserted }
        }
    }

    private func resolve(_ title: TraktTitle, language: String) async -> Resolved {
        guard let id = title.tmdb, tmdb.isConfigured else { return Resolved() }
        let key = "\(title.kind.rawValue)-\(id)-\(language)"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit = hit { return hit }
        guard let details = try? await tmdb.summary(kind: title.kind == .movie ? .movie : .tv, id: id, language: language) else { return Resolved() }
        func image(_ path: String?, size: String) -> String? {
            guard let path = path, path.hasPrefix("/"), !path.contains("..") else { return nil }
            return "https://image.tmdb.org/t/p/\(size)" + path
        }
        let resolved = Resolved(name: details.title, overview: details.overview,
                                poster: image(details.posterPath, size: "w342"), background: image(details.backdropPath, size: "w780"))
        lock.lock()
        if cache.count > 1500 { cache.removeAll() }
        cache[key] = resolved
        lock.unlock()
        return resolved
    }
}
