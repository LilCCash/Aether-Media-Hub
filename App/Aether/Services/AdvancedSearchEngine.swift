import Foundation
import AetherCore

/// Il risultato di una ricerca avanzata, con il modo in cui la frase è stata letta.
struct AdvancedSearchResult {
    var intent: SearchIntent?
    var items: [MetaItem]
    var notes: [String]
}

/// Mette insieme i livelli della ricerca avanzata: parole chiave TMDB, parser locale, Apple Intelligence e modelli in rete.
final class AdvancedSearchEngine: @unchecked Sendable {
    private let service: AdvancedSearchService
    let ai: AISearchClient
    private let timing: SearchTimingLog
    private let resolveCache = AdvancedSearchCache()
    private let lock = NSLock()
    private var cache: [String: SearchIntent] = [:]

    init(tmdb: TMDBClient, ai: AISearchClient, timing: SearchTimingLog) {
        service = AdvancedSearchService(tmdb: tmdb, cache: resolveCache)
        self.ai = ai
        self.timing = timing
    }

    var tmdbReady: Bool { return service.isAvailable }

    func clearCache() {
        resolveCache.clear()
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func cached(_ key: String) -> SearchIntent? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ intent: SearchIntent, for key: String) {
        lock.lock()
        cache[key] = intent
        lock.unlock()
    }

    /// - Parameter submitted: l'utente ha premuto «Cerca» (serve per l'AI quando è impostata su «premendo Cerca»).
    func search(_ query: String, settings: AdvancedSearchSettings, language: String, submitted: Bool) async -> AdvancedSearchResult {
        guard settings.hasAnyLevel else { return AdvancedSearchResult(intent: nil, items: [], notes: []) }
        guard service.isAvailable else {
            return AdvancedSearchResult(intent: nil, items: [], notes: ["La ricerca avanzata usa TMDB: inserisci la chiave in Impostazioni ▸ Servizi."])
        }
        let year = Calendar.current.component(.year, from: Date())
        let totalStarted = Date()
        var phases: [PhaseTiming] = []
        var interpreter = "parser locale"
        var notes: [String] = []
        let parseStarted = Date()
        let parsed = settings.naturalParser ? NaturalQueryParser(currentYear: year).parse(query) : nil
        var intent: SearchIntent? = (parsed?.intent.hasFilters ?? false) ? parsed?.intent : nil
        phases.append(PhaseTiming(name: "Parser locale", seconds: Date().timeIntervalSince(parseStarted)))

        let aiAllowed = settings.aiEnabled && (submitted || settings.aiTrigger == .whileTyping)
        // «Simili a…»: il parser sa solo cercare il titolo; l'AI sa davvero quali titoli gli somigliano.
        let aiKnowsSimilar = settings.aiSuggestsTitles && intent?.similarTo != nil
        let wantsAI = aiAllowed && (settings.aiMode == .always || intent == nil || aiKnowsSimilar)
        if wantsAI {
            let started = Date()
            let outcome = await askAI(query, settings: settings, year: year)
            phases.append(PhaseTiming(name: "Interpretazione AI · \(outcome.via)", seconds: Date().timeIntervalSince(started),
                                      detail: outcome.intent.map { "\($0.suggestions.count) titoli proposti" } ?? "nessuna risposta"))
            if let found = outcome.intent {
                intent = found
                interpreter = outcome.via
            }
            notes.append(contentsOf: outcome.notes)
        } else if settings.aiEnabled && !aiAllowed && intent == nil {
            notes.append("Premi «Cerca» sulla tastiera per far interpretare la frase dal modello AI.")
        }

        let leftovers = settings.keywordSearch ? Array((parsed?.leftovers ?? NaturalQueryParser(currentYear: year).parse(query).leftovers).prefix(3)) : []
        if intent == nil {
            // Nothing to search and no service asked: not worth a line in the log.
            guard !leftovers.isEmpty else {
                if phases.count > 1 { record(query: query, interpreter: interpreter, total: Date().timeIntervalSince(totalStarted), phases: phases, results: 0, notes: notes, enabled: settings.logTimings) }
                return AdvancedSearchResult(intent: nil, items: [], notes: notes)
            }
            var keywordOnly = SearchIntent()
            keywordOnly.source = .keyword
            keywordOnly.keywords = leftovers
            intent = keywordOnly
        }
        guard let finalIntent = intent else { return AdvancedSearchResult(intent: nil, items: [], notes: notes) }
        let extra = finalIntent.source == .keyword ? [] : leftovers
        let outcome = await service.run(intent: finalIntent, extraKeywords: extra, settings: settings, language: language)
        notes.append(contentsOf: outcome.notes)
        phases.append(contentsOf: outcome.timings)
        record(query: query, interpreter: interpreter, total: Date().timeIntervalSince(totalStarted), phases: phases, results: outcome.items.count, notes: notes, enabled: settings.logTimings)
        return AdvancedSearchResult(intent: finalIntent, items: outcome.items, notes: notes)
    }

    private func record(query: String, interpreter: String, total: Double, phases: [PhaseTiming], results: Int, notes: [String], enabled: Bool) {
        guard enabled else { return }
        let entry = SearchTimingEntry(query: query, interpreter: interpreter, total: total, phases: phases, results: results, notes: notes)
        let log = timing
        Task { @MainActor in log.add(entry) }
    }

    // MARK: AI

    private func askAI(_ query: String, settings: AdvancedSearchSettings, year: Int) async -> (intent: SearchIntent?, notes: [String], via: String) {
        let key = "\(query.lowercased())|\(settings.aiEngine.rawValue)|\(settings.aiSuggestsTitles)|\(settings.maxResults)|\(settings.provider.rawValue)|\(settings.model(for: settings.provider))"
        if settings.rememberInterpretations {
            if let hit = cached(key) { return (hit, [], "memoria") }
        }
        var notes: [String] = []
        var found: SearchIntent?
        var via = "nessuno"
        let triesApple = settings.aiEngine != .networkOnly
        let triesNetwork = settings.aiEngine != .appleOnly
        if triesApple {
            let status = AppleIntelligence.status
            if status.isAvailable {
                found = await AppleIntelligence.interpret(query, year: year, count: settings.maxResults, suggestTitles: settings.aiSuggestsTitles)
                if found != nil { via = "Apple Intelligence" }
                if found == nil { notes.append("Apple Intelligence non ha capito la frase.") }
            } else {
                notes.append(status.text)
            }
        }
        if found == nil && triesNetwork {
            do {
                found = try await ai.interpret(query, settings: settings, year: year)
                via = "\(settings.provider.title) (\(settings.model(for: settings.provider)))"
            } catch let error as AISearchError {
                notes.append("\(settings.provider.title): \(error.message)")
            } catch {
                notes.append("\(settings.provider.title): errore di rete.")
            }
        }
        if let found = found, settings.rememberInterpretations {
            store(found, for: key)
        }
        return (found, notes, via)
    }
}
