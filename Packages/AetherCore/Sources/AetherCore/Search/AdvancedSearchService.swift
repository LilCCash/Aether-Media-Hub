import Foundation

public struct AdvancedSearchOutcome: Sendable {
    public var items: [MetaItem]
    public var notes: [String]

    public init(items: [MetaItem] = [], notes: [String] = []) {
        self.items = items
        self.notes = notes
    }
}

/// Esegue un `SearchIntent` su TMDB (discover, parole chiave, titolo) e restituisce titoli apribili in Aether.
public struct AdvancedSearchService: Sendable {
    private let tmdb: TMDBClient

    public init(tmdb: TMDBClient) {
        self.tmdb = tmdb
    }

    public var isAvailable: Bool { return tmdb.isConfigured }

    /// - Parameters:
    ///   - extraKeywords: parole non riconosciute dal parser, da provare come parole chiave TMDB (livello 1).
    public func run(intent: SearchIntent, extraKeywords: [String], settings: AdvancedSearchSettings, language: String) async -> AdvancedSearchOutcome {
        var notes: [String] = []
        let kinds = Self.kinds(for: intent, settings: settings)
        guard !kinds.isEmpty else { return AdvancedSearchOutcome() }

        // I titoli proposti dall'AI vanno per primi; i filtri (se ci sono) completano la lista.
        if !intent.suggestions.isEmpty {
            let proposed = await resolve(intent.suggestions, kinds: kinds, language: language)
            let suggested = await Self.items(from: proposed, tmdb: tmdb, limit: settings.maxResults)
            if suggested.count < intent.suggestions.count {
                notes.append("\(suggested.count) titoli su \(intent.suggestions.count) proposti dall'AI sono stati trovati su TMDB.")
            }
            var rest = intent
            rest.suggestions = []
            rest.similarTo = nil
            rest.title = nil
            guard rest.hasFilters, suggested.count < settings.maxResults else {
                return AdvancedSearchOutcome(items: suggested, notes: notes)
            }
            let more = await run(intent: rest, extraKeywords: extraKeywords, settings: settings, language: language)
            var seen = Set(suggested.map { $0.id })
            var merged = suggested
            for item in more.items where seen.insert(item.id).inserted && merged.count < settings.maxResults { merged.append(item) }
            return AdvancedSearchOutcome(items: merged, notes: notes + more.notes)
        }

        // «Simili a …»: si cerca il titolo di partenza e si prendono i consigliati di TMDB.
        if let reference = intent.similarTo {
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
            let items = await Self.items(from: found, tmdb: tmdb, limit: settings.maxResults)
            return AdvancedSearchOutcome(items: items, notes: notes)
        }

        // Un titolo preciso: ricerca per nome.
        if let title = intent.title, intent.genres.isEmpty {
            var found: [(TMDBClient.Kind, TMDBDiscoverItem)] = []
            for kind in kinds {
                if let list = try? await tmdb.searchTitles(kind: kind, text: title, language: language) {
                    found.append(contentsOf: list.prefix(settings.maxResults).map { (kind, $0) })
                }
            }
            let items = await Self.items(from: found, tmdb: tmdb, limit: settings.maxResults)
            return AdvancedSearchOutcome(items: items, notes: notes)
        }

        var words = intent.keywords
        if settings.keywordSearch {
            for word in extraKeywords where words.count < 4 && !words.contains(word) { words.append(word) }
        }
        let ids = await keywordIDs(words)
        if !words.isEmpty && ids.isEmpty { notes.append("Nessuna parola chiave TMDB corrisponde a «\(words.joined(separator: ", "))»: ho usato solo gli altri filtri.") }

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
        let items = await Self.items(from: found, tmdb: tmdb, limit: settings.maxResults)
        return AdvancedSearchOutcome(items: items, notes: notes)
    }

    // MARK: Passi

    /// Ritrova su TMDB i titoli proposti dall'AI (nome originale e anno), nello stesso ordine.
    private func resolve(_ suggestions: [SuggestedTitle], kinds: [TMDBClient.Kind], language: String) async -> [(TMDBClient.Kind, TMDBDiscoverItem)] {
        let client = tmdb
        return await withTaskGroup(of: (Int, (TMDBClient.Kind, TMDBDiscoverItem)?).self) { (group: inout TaskGroup<(Int, (TMDBClient.Kind, TMDBDiscoverItem)?)>) -> [(TMDBClient.Kind, TMDBDiscoverItem)] in
            for (index, suggestion) in suggestions.enumerated() {
                let order: [TMDBClient.Kind]
                if let kind = suggestion.kind {
                    order = [kind == .movie ? .movie : .tv]
                } else {
                    order = kinds
                }
                group.addTask {
                    for kind in order {
                        let list = (try? await client.searchTitles(kind: kind, text: suggestion.title, language: language, year: suggestion.year)) ?? []
                        if let first = list.first { return (index, (kind, first)) }
                    }
                    return (index, nil)
                }
            }
            var found: [(Int, (TMDBClient.Kind, TMDBDiscoverItem))] = []
            for await (index, match) in group {
                if let match = match { found.append((index, match)) }
            }
            return found.sorted { (a: (Int, (TMDBClient.Kind, TMDBDiscoverItem)), b: (Int, (TMDBClient.Kind, TMDBDiscoverItem))) -> Bool in a.0 < b.0 }.map { $0.1 }
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
        var lists: [[(TMDBClient.Kind, TMDBDiscoverItem)]] = []
        for kind in kinds {
            let query = Self.query(kind: kind, intent: intent, keywordIDs: keywordIDs, settings: settings, language: language, notes: &notes)
            let list = (try? await tmdb.discover(kind: kind, query: query)) ?? []
            lists.append(list.map { (kind, $0) })
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

    /// Dà a ogni risultato il suo codice IMDb (quello che usano gli addon) e lo trasforma in `MetaItem`.
    static func items(from found: [(TMDBClient.Kind, TMDBDiscoverItem)], tmdb: TMDBClient, limit: Int) async -> [MetaItem] {
        let slice = Array(found.prefix(limit + 8))
        return await withTaskGroup(of: (Int, MetaItem?).self) { (group: inout TaskGroup<(Int, MetaItem?)>) -> [MetaItem] in
            for (index, entry) in slice.enumerated() {
                let kind = entry.0
                let item = entry.1
                group.addTask {
                    guard let id = item.id, let title = item.title else { return (index, nil) }
                    guard let ids = try? await tmdb.externalIDs(kind: kind, id: id), let imdb = ids.imdbID, !imdb.isEmpty else { return (index, nil) }
                    let year = item.date.map { String($0.prefix(4)) }.flatMap { $0.count == 4 ? $0 : nil }
                    let poster = item.posterPath.flatMap { (path: String) -> String? in
                        path.hasPrefix("/") && !path.contains("..") ? "https://image.tmdb.org/t/p/w342" + path : nil
                    }
                    let background = item.backdropPath.flatMap { (path: String) -> String? in
                        path.hasPrefix("/") && !path.contains("..") ? "https://image.tmdb.org/t/p/w780" + path : nil
                    }
                    let meta = MetaItem(id: imdb, type: kind == .movie ? "movie" : "series", name: title, poster: poster,
                                        background: background, description: item.overview, releaseInfo: year,
                                        externalIDs: ExternalIDs(imdb: imdb, tmdb: id))
                    return (index, meta)
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
