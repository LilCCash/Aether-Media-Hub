import Foundation

/// Quanto ha impiegato una fase della ricerca.
public struct PhaseTiming: Equatable, Sendable, Codable {
    public var name: String
    public var seconds: Double
    public var detail: String?

    public init(name: String, seconds: Double, detail: String? = nil) {
        self.name = name
        self.seconds = seconds
        self.detail = detail
    }
}

public struct AdvancedSearchOutcome: Sendable {
    public var items: [MetaItem]
    public var notes: [String]
    public var timings: [PhaseTiming]

    public init(items: [MetaItem] = [], notes: [String] = [], timings: [PhaseTiming] = []) {
        self.items = items
        self.notes = notes
        self.timings = timings
    }
}

/// Ricorda (finché l'app è aperta) i titoli già ritrovati su TMDB e i loro codici IMDb: le ricerche ripetute non rifanno le richieste.
public final class AdvancedSearchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var metas: [String: MetaItem] = [:]
    private var imdb: [String: String] = [:]

    public init() {}

    func meta(_ key: String) -> MetaItem? {
        lock.lock()
        defer { lock.unlock() }
        return metas[key]
    }

    func setMeta(_ value: MetaItem, for key: String) {
        lock.lock()
        if metas.count > 800 { metas.removeAll() }
        metas[key] = value
        lock.unlock()
    }

    func imdbID(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return imdb[key]
    }

    func setIMDB(_ value: String, for key: String) {
        lock.lock()
        if imdb.count > 2000 { imdb.removeAll() }
        imdb[key] = value
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        metas.removeAll()
        imdb.removeAll()
        lock.unlock()
    }
}

/// Esegue un `SearchIntent` su TMDB (discover, parole chiave, titolo) e restituisce titoli apribili in Aether.
public struct AdvancedSearchService: Sendable {
    private let tmdb: TMDBClient
    private let cache: AdvancedSearchCache

    public init(tmdb: TMDBClient, cache: AdvancedSearchCache = AdvancedSearchCache()) {
        self.tmdb = tmdb
        self.cache = cache
    }

    public var isAvailable: Bool { return tmdb.isConfigured }

    /// - Parameters:
    ///   - extraKeywords: parole non riconosciute dal parser, da provare come parole chiave TMDB (livello 1).
    public func run(intent: SearchIntent, extraKeywords: [String], settings: AdvancedSearchSettings, language: String) async -> AdvancedSearchOutcome {
        var notes: [String] = []
        var timings: [PhaseTiming] = []
        let kinds = Self.kinds(for: intent, settings: settings)
        guard !kinds.isEmpty else { return AdvancedSearchOutcome() }

        // I titoli proposti dall'AI vanno per primi; i filtri (se ci sono) completano la lista.
        if !intent.suggestions.isEmpty {
            let started = Date()
            let suggested = await resolveItems(intent.suggestions, kinds: kinds, language: language, limit: settings.maxResults)
            timings.append(PhaseTiming(name: "TMDB · titoli proposti (ricerca e codici IMDb)", seconds: Date().timeIntervalSince(started),
                                       detail: "\(suggested.count) su \(intent.suggestions.count) trovati"))
            if suggested.count < intent.suggestions.count {
                notes.append("\(suggested.count) titoli su \(intent.suggestions.count) proposti dall'AI sono stati trovati su TMDB.")
            }
            var rest = intent
            rest.suggestions = []
            rest.similarTo = nil
            rest.title = nil
            guard rest.hasFilters, suggested.count < settings.maxResults else {
                return AdvancedSearchOutcome(items: suggested, notes: notes, timings: timings)
            }
            let more = await run(intent: rest, extraKeywords: extraKeywords, settings: settings, language: language)
            var seen = Set(suggested.map { $0.id })
            var merged = suggested
            for item in more.items where seen.insert(item.id).inserted && merged.count < settings.maxResults { merged.append(item) }
            return AdvancedSearchOutcome(items: merged, notes: notes + more.notes, timings: timings + more.timings)
        }

        // «Simili a …»: si cerca il titolo di partenza e si prendono i consigliati di TMDB.
        if let reference = intent.similarTo {
            let started = Date()
            var found: [(TMDBClient.Kind, TMDBDiscoverItem)] = []
            for kind in kinds {
                guard let match = (try? await tmdb.searchTitles(kind: kind, text: reference, language: language))?.first,
                      let id = match.id else { continue }
                let list = (try? await tmdb.related(kind: kind, id: id, language: language)) ?? []
                found = list.filter { $0.id != id }.map { (kind, $0) }
                notes.append("Titolo di partenza: «\(match.title ?? reference)»" + (match.date.map { " (\($0.prefix(4)))" } ?? "") + ".")
                break
            }
            if found.isEmpty && notes.isEmpty { notes.append("Non ho trovato «\(reference)» su TMDB.") }
            let items = await Self.items(from: found, tmdb: tmdb, limit: settings.maxResults, cache: cache)
            timings.append(PhaseTiming(name: "TMDB · titoli simili (raccomandazioni)", seconds: Date().timeIntervalSince(started), detail: "\(items.count) titoli"))
            return AdvancedSearchOutcome(items: items, notes: notes, timings: timings)
        }

        // Un titolo preciso: ricerca per nome.
        if let title = intent.title, intent.genres.isEmpty {
            var found: [(TMDBClient.Kind, TMDBDiscoverItem)] = []
            for kind in kinds {
                if let list = try? await tmdb.searchTitles(kind: kind, text: title, language: language) {
                    found.append(contentsOf: list.prefix(settings.maxResults).map { (kind, $0) })
                }
            }
            let items = await Self.items(from: found, tmdb: tmdb, limit: settings.maxResults, cache: cache)
            return AdvancedSearchOutcome(items: items, notes: notes, timings: timings)
        }

        var words = intent.keywords
        if settings.keywordSearch {
            for word in extraKeywords where words.count < 4 && !words.contains(word) { words.append(word) }
        }
        let keywordStarted = Date()
        let ids = await keywordIDs(words)
        if !words.isEmpty {
            timings.append(PhaseTiming(name: "TMDB · parole chiave", seconds: Date().timeIntervalSince(keywordStarted), detail: words.joined(separator: ", ")))
        }
        if !words.isEmpty && ids.isEmpty { notes.append("Nessuna parola chiave TMDB corrisponde a «\(words.joined(separator: ", "))»: ho usato solo gli altri filtri.") }

        let discoverStarted = Date()
        var found = await fetch(kinds: kinds, intent: intent, keywordIDs: ids, settings: settings, language: language, notes: &notes)
        // Le parole chiave restringono molto: se i titoli sono pochi, si completa con quelli degli altri filtri.
        if !ids.isEmpty && found.count < settings.maxResults {
            let more = await fetch(kinds: kinds, intent: intent, keywordIDs: [], settings: settings, language: language, notes: &notes)
            var seen = Set(found.compactMap { (entry: (TMDBClient.Kind, TMDBDiscoverItem)) -> String? in entry.1.id.map { "\(entry.0.rawValue)-\($0)" } })
            for entry in more {
                guard let id = entry.1.id, seen.insert("\(entry.0.rawValue)-\(id)").inserted else { continue }
                found.append(entry)
            }
            if more.count > 0 { notes.append("Prima i titoli con la parola chiave, poi altri dello stesso genere.") }
        }
        timings.append(PhaseTiming(name: "TMDB · elenco per filtri (discover)", seconds: Date().timeIntervalSince(discoverStarted), detail: "\(found.count) candidati"))
        let idsStarted = Date()
        let items = await Self.items(from: found, tmdb: tmdb, limit: settings.maxResults, cache: cache)
        timings.append(PhaseTiming(name: "TMDB · codici IMDb", seconds: Date().timeIntervalSince(idsStarted), detail: "\(items.count) titoli"))
        return AdvancedSearchOutcome(items: items, notes: notes, timings: timings)
    }

    // MARK: Passi

    /// Ritrova su TMDB i titoli proposti dall'AI: per ognuno cerca il titolo e subito dopo il codice IMDb, tutti in parallelo
    /// (una catena per titolo, senza aspettare gli altri). Le ricerche già fatte vengono dalla memoria.
    private func resolveItems(_ suggestions: [SuggestedTitle], kinds: [TMDBClient.Kind], language: String, limit: Int) async -> [MetaItem] {
        let client = tmdb
        let cache = self.cache
        return await withTaskGroup(of: (Int, MetaItem?).self) { (group: inout TaskGroup<(Int, MetaItem?)>) -> [MetaItem] in
            for (index, suggestion) in suggestions.enumerated() {
                let order: [TMDBClient.Kind]
                if let kind = suggestion.kind {
                    order = [kind == .movie ? .movie : .tv]
                } else {
                    order = kinds
                }
                group.addTask {
                    let key = "\(language)|\(suggestion.title.lowercased())|\(suggestion.year ?? 0)|" + order.map { $0.rawValue }.joined(separator: ",")
                    if let hit = cache.meta(key) { return (index, hit) }
                    for kind in order {
                        let list = (try? await client.searchTitles(kind: kind, text: suggestion.title, language: language, year: suggestion.year)) ?? []
                        guard let first = list.first, let id = first.id else { continue }
                        let imdbKey = "\(kind.rawValue)-\(id)"
                        var imdb = cache.imdbID(imdbKey)
                        if imdb == nil, let ids = try? await client.externalIDs(kind: kind, id: id), let code = ids.imdbID, !code.isEmpty {
                            cache.setIMDB(code, for: imdbKey)
                            imdb = code
                        }
                        guard let code = imdb, let meta = Self.meta(kind: kind, item: first, imdb: code) else { continue }
                        cache.setMeta(meta, for: key)
                        return (index, meta)
                    }
                    return (index, nil)
                }
            }
            var collected: [(Int, MetaItem)] = []
            for await (index, meta) in group {
                if let meta = meta { collected.append((index, meta)) }
            }
            var seen = Set<String>()
            let ordered = collected.sorted { (a: (Int, MetaItem), b: (Int, MetaItem)) -> Bool in a.0 < b.0 }.map { $0.1 }
            return Array(ordered.filter { seen.insert($0.id).inserted }.prefix(limit))
        }
    }

    private func keywordIDs(_ words: [String]) async -> [Int] {
        guard !words.isEmpty else { return [] }
        let client = tmdb
        return await withTaskGroup(of: [Int].self) { (group: inout TaskGroup<[Int]>) -> [Int] in
            for word in words {
                group.addTask { (try? await client.keywordIDs(matching: word, limit: 1)) ?? [] }
            }
            var all: [Int] = []
            for await ids in group { all.append(contentsOf: ids) }
            return Array(Set(all)).sorted()
        }
    }

    private func fetch(kinds: [TMDBClient.Kind], intent: SearchIntent, keywordIDs: [Int], settings: AdvancedSearchSettings,
                       language: String, notes: inout [String]) async -> [(TMDBClient.Kind, TMDBDiscoverItem)] {
        var requests: [(TMDBClient.Kind, [(String, String)])] = []
        for kind in kinds {
            requests.append((kind, Self.query(kind: kind, intent: intent, keywordIDs: keywordIDs, settings: settings, language: language, notes: &notes)))
        }
        // Film e serie si chiedono insieme, non uno dopo l'altro.
        let client = tmdb
        let lists = await withTaskGroup(of: (Int, [(TMDBClient.Kind, TMDBDiscoverItem)]).self) { (group: inout TaskGroup<(Int, [(TMDBClient.Kind, TMDBDiscoverItem)])>) -> [[(TMDBClient.Kind, TMDBDiscoverItem)]] in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let list = (try? await client.discover(kind: request.0, query: request.1)) ?? []
                    return (index, list.map { (request.0, $0) })
                }
            }
            var byIndex: [Int: [(TMDBClient.Kind, TMDBDiscoverItem)]] = [:]
            for await (index, list) in group { byIndex[index] = list }
            return requests.indices.map { byIndex[$0] ?? [] }
        }
        // Film e serie si alternano, così nessuno dei due riempie la lista.
        var merged: [(TMDBClient.Kind, TMDBDiscoverItem)] = []
        var index = 0
        while merged.count < settings.maxResults * 2 {
            var added = false
            for list in lists where index < list.count {
                merged.append(list[index])
                added = true
            }
            if !added { break }
            index += 1
        }
        return merged
    }

    static func kinds(for intent: SearchIntent, settings: AdvancedSearchSettings) -> [TMDBClient.Kind] {
        if let kind = intent.kind { return [kind == .movie ? .movie : .tv] }
        switch settings.resultKind {
        case .both: return [.movie, .tv]
        case .movie: return [.movie]
        case .series: return [.tv]
        }
    }

    static func query(kind: TMDBClient.Kind, intent: SearchIntent, keywordIDs: [Int], settings: AdvancedSearchSettings,
                      language: String, notes: inout [String]) -> [(String, String)] {
        var query: [(String, String)] = [
            ("language", language),
            ("include_adult", settings.includeAdult ? "true" : "false"),
            ("page", "1"),
        ]
        let genreIDs = intent.genres.compactMap { (genre: IntentGenre) -> Int? in kind == .movie ? genre.movieID : genre.tvID }
        if genreIDs.count < intent.genres.count {
            let missing = intent.genres.filter { (genre: IntentGenre) -> Bool in (kind == .movie ? genre.movieID : genre.tvID) == nil }
            notes.append("Per le serie TMDB non ha il genere \(missing.map { $0.italianName }.joined(separator: ", ")): l'ho ignorato.")
        }
        if !genreIDs.isEmpty { query.append(("with_genres", Array(Set(genreIDs)).sorted().map(String.init).joined(separator: ","))) }
        if !keywordIDs.isEmpty { query.append(("with_keywords", keywordIDs.map(String.init).joined(separator: "|"))) }
        let dateKey = kind == .movie ? "primary_release_date" : "first_air_date"
        if let from = intent.yearFrom { query.append(("\(dateKey).gte", "\(from)-01-01")) }
        if let to = intent.yearTo { query.append(("\(dateKey).lte", "\(to)-12-31")) }
        if let rating = intent.minRating { query.append(("vote_average.gte", String(format: "%.1f", rating))) }
        if !intent.countries.isEmpty { query.append(("with_origin_country", intent.countries.joined(separator: "|"))) }
        if let runtime = intent.maxRuntime, kind == .movie { query.append(("with_runtime.lte", String(runtime))) }
        switch intent.sort {
        case .popularity:
            query.append(("sort_by", "popularity.desc"))
            query.append(("vote_count.gte", "20"))
        case .rating:
            query.append(("sort_by", "vote_average.desc"))
            query.append(("vote_count.gte", String(settings.minVotes)))
        case .newest:
            query.append(("sort_by", "\(dateKey).desc"))
            query.append(("vote_count.gte", "30"))
        case .oldest:
            query.append(("sort_by", "\(dateKey).asc"))
            query.append(("vote_count.gte", "200"))
        }
        return query
    }

    static func meta(kind: TMDBClient.Kind, item: TMDBDiscoverItem, imdb: String) -> MetaItem? {
        guard let id = item.id, let title = item.title else { return nil }
        let year = item.date.map { String($0.prefix(4)) }.flatMap { $0.count == 4 ? $0 : nil }
        let poster = item.posterPath.flatMap { (path: String) -> String? in
            path.hasPrefix("/") && !path.contains("..") ? "https://image.tmdb.org/t/p/w342" + path : nil
        }
        let background = item.backdropPath.flatMap { (path: String) -> String? in
            path.hasPrefix("/") && !path.contains("..") ? "https://image.tmdb.org/t/p/w780" + path : nil
        }
        return MetaItem(id: imdb, type: kind == .movie ? "movie" : "series", name: title, poster: poster,
                        background: background, description: item.overview, releaseInfo: year,
                        externalIDs: ExternalIDs(imdb: imdb, tmdb: id))
    }

    /// Dà a ogni risultato il suo codice IMDb (quello che usano gli addon) e lo trasforma in `MetaItem`.
    static func items(from found: [(TMDBClient.Kind, TMDBDiscoverItem)], tmdb: TMDBClient, limit: Int,
                      cache: AdvancedSearchCache? = nil) async -> [MetaItem] {
        let slice = Array(found.prefix(limit + 8))
        return await withTaskGroup(of: (Int, MetaItem?).self) { (group: inout TaskGroup<(Int, MetaItem?)>) -> [MetaItem] in
            for (index, entry) in slice.enumerated() {
                let kind = entry.0
                let item = entry.1
                group.addTask {
                    guard let id = item.id else { return (index, nil) }
                    let key = "\(kind.rawValue)-\(id)"
                    var imdb = cache?.imdbID(key)
                    if imdb == nil, let ids = try? await tmdb.externalIDs(kind: kind, id: id), let code = ids.imdbID, !code.isEmpty {
                        cache?.setIMDB(code, for: key)
                        imdb = code
                    }
                    guard let code = imdb else { return (index, nil) }
                    return (index, Self.meta(kind: kind, item: item, imdb: code))
                }
            }
            var collected: [(Int, MetaItem)] = []
            for await (index, meta) in group {
                if let meta = meta { collected.append((index, meta)) }
            }
            var seen = Set<String>()
            let ordered = collected.sorted { (a: (Int, MetaItem), b: (Int, MetaItem)) -> Bool in a.0 < b.0 }.map { $0.1 }
            return Array(ordered.filter { seen.insert($0.id).inserted }.prefix(limit))
        }
    }
}
