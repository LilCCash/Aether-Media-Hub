import Foundation

public enum AISearchError: Error, Equatable, Sendable {
    case notConfigured
    case invalidCredentials
    case rateLimited
    case badEndpoint
    case unavailable
    case unreadable

    public var message: String {
        switch self {
        case .notConfigured: return "Manca la chiave del modello scelto."
        case .invalidCredentials: return "Il servizio ha rifiutato la chiave: controllala."
        case .rateLimited: return "Troppe richieste o credito esaurito: riprova più tardi."
        case .badEndpoint: return "Indirizzo del server non valido (serve https)."
        case .unavailable: return "Il modello non risponde. Controlla rete e nome del modello."
        case .unreadable: return "Il modello ha risposto in modo non comprensibile."
        }
    }
}

/// Istruzioni e lettura della risposta, uguali per ogni modello (in rete o sul dispositivo).
public enum AIIntentCodec {
    public static func systemPrompt(year: Int, count: Int = 15, suggestTitles: Bool = true) -> String {
        let genres = IntentGenre.allCases.map { $0.rawValue }.joined(separator: ", ")
        var text = """
        You are an expert on films and TV series helping a user find something to watch. The user writes in Italian. \
        Reply with ONE JSON object and nothing else, with these optional keys: \
        "kind" ("movie" or "series", omit for both); \
        "genres" (array, only from: \(genres)); \
        "keywords" (array of 0-3 short English TMDB keywords such as "heist", "slasher", "parody"); \
        "year_from" and "year_to" (integers); \
        "sort" ("popularity", "rating", "newest" or "oldest"); \
        "min_rating" (0-10); \
        "countries" (array of ISO 3166-1 codes); \
        "max_runtime" (minutes); \
        "title" (only if the user names one specific title and wants that title itself); \
        "similar_to" (the reference title when the user asks for titles similar to a specific film or series).
        """
        if suggestTitles {
            text += """
             Add "titles": an array of up to \(count) real titles that best answer the request, most relevant first, \
            each as {"title": ORIGINAL title, "year": release year, "type": "movie" or "series"}. \
            Use your knowledge: Italian release titles often differ from the original ones \
            (e.g. "Ghost Movie" is the Italian title of "A Haunted House" (2013)), so identify the real title first and \
            then recommend titles with the same genre, tone and style, not just titles that share a word. \
            Never invent titles; leave "titles" out if you are not sure.
            """
        }
        text += " The current year is \(year): \"recent years\" means the last 5 years. Never explain, never add text outside the JSON."
        return text
    }

    public static func userPrompt(_ query: String) -> String {
        return "Richiesta: " + query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Estrae l'intento dal testo del modello (accetta anche JSON dentro blocchi di codice o con testo attorno).
    public static func parse(_ text: String, source: SearchIntent.Source = .ai) -> SearchIntent? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var intent = SearchIntent()
        intent.source = source
        if let kind = (object["kind"] as? String)?.lowercased() {
            if kind == "movie" || kind == "film" { intent.kind = .movie }
            if kind == "series" || kind == "tv" || kind == "show" { intent.kind = .series }
        }
        for name in (object["genres"] as? [Any] ?? []).compactMap({ $0 as? String }) {
            let key = name.lowercased().replacingOccurrences(of: "-", with: "")
            let genre = IntentGenre(rawValue: key)
                ?? IntentGenre.allCases.first(where: { (g: IntentGenre) -> Bool in g.italianName == key || g.rawValue == key })
            if let genre = genre, !intent.genres.contains(genre) { intent.genres.append(genre) }
        }
        intent.keywords = Array((object["keywords"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }.prefix(3))
        intent.yearFrom = integer(object["year_from"]).flatMap { (1900...2100).contains($0) ? $0 : nil }
        intent.yearTo = integer(object["year_to"]).flatMap { (1900...2100).contains($0) ? $0 : nil }
        if let sort = (object["sort"] as? String).flatMap({ IntentSort(rawValue: $0.lowercased()) }) { intent.sort = sort }
        if let rating = number(object["min_rating"]), rating > 0, rating <= 10 { intent.minRating = rating }
        intent.countries = (object["countries"] as? [Any] ?? []).compactMap { $0 as? String }
            .map { $0.uppercased() }.filter { $0.count == 2 }
        if let runtime = integer(object["max_runtime"]), runtime > 20, runtime < 400 { intent.maxRuntime = runtime }
        for entry in (object["titles"] as? [Any] ?? []) {
            guard let dict = entry as? [String: Any],
                  let name = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let year = integer(dict["year"]).flatMap { (1880...2100).contains($0) ? $0 : nil }
            var kind: IntentKind?
            if let type = (dict["type"] as? String)?.lowercased() {
                if type == "movie" || type == "film" { kind = .movie }
                if type == "series" || type == "tv" || type == "show" { kind = .series }
            }
            let suggestion = SuggestedTitle(title: name, year: year, kind: kind)
            if !intent.suggestions.contains(suggestion) { intent.suggestions.append(suggestion) }
            if intent.suggestions.count >= 40 { break }
        }
        if let similar = (object["similar_to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !similar.isEmpty { intent.similarTo = similar }
        if let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { intent.title = title }
        return intent.hasFilters || intent.title != nil ? intent : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

/// Chiama il modello in rete scelto dall'utente con la sua chiave (letta dal Portachiavi a ogni richiesta).
public struct AISearchClient: Sendable {
    public typealias KeyProvider = @Sendable (AISearchProvider) -> String?

    private let http: HTTPClient
    private let key: KeyProvider

    public init(http: HTTPClient, key: @escaping KeyProvider) {
        self.http = http
        self.key = key
    }

    public func hasKey(for provider: AISearchProvider) -> Bool {
        return key(provider) != nil
    }

    public func interpret(_ query: String, settings: AdvancedSearchSettings, year: Int, model overrideModel: String? = nil) async throws -> SearchIntent {
        let provider = settings.provider
        let secret = key(provider)
        if secret == nil && !provider.keyIsOptional { throw AISearchError.notConfigured }
        let model = overrideModel ?? settings.model(for: provider)
        guard !model.isEmpty else { throw AISearchError.notConfigured }
        let system = AIIntentCodec.systemPrompt(year: year, count: settings.maxResults, suggestTitles: settings.aiSuggestsTitles)
        let user = AIIntentCodec.userPrompt(query)
        let request = try Self.request(provider: provider, model: model, key: secret, customBase: settings.customBaseURL,
                                       system: system, user: user, timeout: TimeInterval(settings.aiTimeout))
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw AISearchError.unavailable
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw AISearchError.invalidCredentials
        case 402, 429: throw AISearchError.rateLimited
        default: throw AISearchError.unavailable
        }
        guard let text = Self.answerText(provider: provider, data: response.data),
              let intent = AIIntentCodec.parse(text) else { throw AISearchError.unreadable }
        return intent
    }

    /// Prova il modello con una frase breve (pulsante «Prova il modello» delle impostazioni).
    public func test(settings: AdvancedSearchSettings, year: Int) async -> AISearchError? {
        do {
            _ = try await interpret("film simili a Toy Story", settings: settings, year: year)
            return nil
        } catch let error as AISearchError {
            return error
        } catch {
            return .unavailable
        }
    }

    // MARK: Modelli disponibili

    /// I modelli che la chiave può usare (gratis: non consuma credito). Dipende dal piano dell'account.
    public func listModels(provider: AISearchProvider, customBase: String) async throws -> [AIModelInfo] {
        let secret = key(provider)
        if secret == nil && !provider.keyIsOptional && provider != .openrouter { throw AISearchError.notConfigured }
        let request = try Self.listRequest(provider: provider, key: secret, customBase: customBase)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw AISearchError.unavailable
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw AISearchError.invalidCredentials
        case 429: throw AISearchError.rateLimited
        default: throw AISearchError.unavailable
        }
        let models = AIModelCatalog.parse(provider: provider, data: response.data)
        guard !models.isEmpty else { throw AISearchError.unreadable }
        return models
    }

    static func listRequest(provider: AISearchProvider, key: String?, customBase: String) throws -> HTTPRequest {
        var headers = ["Accept": "application/json"]
        let url: URL
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
            headers["x-api-key"] = key ?? ""
            headers["anthropic-version"] = "2023-06-01"
        case .openai:
            url = URL(string: "https://api.openai.com/v1/models")!
            headers["Authorization"] = "Bearer " + (key ?? "")
        case .openrouter:
            url = URL(string: "https://openrouter.ai/api/v1/models")!
            if let key = key { headers["Authorization"] = "Bearer " + key }
        case .google:
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!
            headers["x-goog-api-key"] = key ?? ""
        case .custom:
            let trimmed = customBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let base = URL(string: trimmed), base.scheme?.lowercased() == "https", let host = base.host, !host.isEmpty,
                  let built = URL(string: trimmed + "/models") else { throw AISearchError.badEndpoint }
            url = built
            if let key = key { headers["Authorization"] = "Bearer " + key }
        }
        return HTTPRequest(url: url, headers: headers, timeout: 20, maxBytes: HTTPLimits.resource)
    }

    // MARK: Richieste

    static func request(provider: AISearchProvider, model: String, key: String?, customBase: String,
                        system: String, user: String, timeout: TimeInterval) throws -> HTTPRequest {
        var headers = ["Content-Type": "application/json", "Accept": "application/json"]
        let url: URL
        let body: [String: Any]
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            headers["x-api-key"] = key ?? ""
            headers["anthropic-version"] = "2023-06-01"
            body = ["model": model, "max_tokens": 2000, "system": system,
                    "messages": [["role": "user", "content": user]]]
        case .openai:
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            headers["Authorization"] = "Bearer " + (key ?? "")
            body = ["model": model, "response_format": ["type": "json_object"],
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        case .openrouter:
            url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
            headers["Authorization"] = "Bearer " + (key ?? "")
            body = ["model": model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        case .google:
            let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            guard let built = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent") else {
                throw AISearchError.badEndpoint
            }
            url = built
            headers["x-goog-api-key"] = key ?? ""
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": user]]]],
                    "generationConfig": ["responseMimeType": "application/json"]]
        case .custom:
            let trimmed = customBase.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let base = URL(string: trimmed), base.scheme?.lowercased() == "https", let host = base.host, !host.isEmpty,
                  let built = URL(string: trimmed + "/chat/completions") else { throw AISearchError.badEndpoint }
            url = built
            if let key = key { headers["Authorization"] = "Bearer " + key }
            body = ["model": model,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { throw AISearchError.badEndpoint }
        return HTTPRequest(url: url, method: "POST", headers: headers, body: data, timeout: timeout, maxBytes: HTTPLimits.manifest)
    }

    static func answerText(provider: AISearchProvider, data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch provider {
        case .anthropic:
            let blocks = object["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .google:
            let candidates = object["candidates"] as? [[String: Any]] ?? []
            let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        case .openai, .openrouter, .custom:
            let choices = object["choices"] as? [[String: Any]] ?? []
            return (choices.first?["message"] as? [String: Any])?["content"] as? String
        }
    }
}


/// Un modello che la chiave può usare.
public struct AIModelInfo: Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// «Veloce ed economico», «gratuito»…
    public var note: String?

    public init(id: String, name: String, note: String? = nil) {
        self.id = id
        self.name = name
        self.note = note
    }
}

/// Legge e ordina l'elenco dei modelli di ogni servizio: tiene solo quelli che sanno chattare e mette per primi i piccoli e veloci.
public enum AIModelCatalog {
    private static let cheapMarkers = ["haiku", "mini", "nano", "flash", "lite", "small", "instant"]
    private static let excludedOpenAI = ["embedding", "whisper", "tts", "dall-e", "image", "audio", "realtime", "transcribe",
                                         "moderation", "davinci", "babbage", "search", "computer-use", "codex", "sora", "omni-moderation"]

    public static func parse(provider: AISearchProvider, data: Data) -> [AIModelInfo] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var models: [AIModelInfo] = []
        switch provider {
        case .anthropic:
            for entry in object["data"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                models.append(AIModelInfo(id: id, name: (entry["display_name"] as? String) ?? id, note: note(for: id)))
            }
        case .openai:
            for entry in object["data"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                let lower = id.lowercased()
                let isChat = lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("o5")
                guard isChat, !excludedOpenAI.contains(where: { lower.contains($0) }) else { continue }
                models.append(AIModelInfo(id: id, name: id, note: note(for: id)))
            }
        case .google:
            for entry in object["models"] as? [[String: Any]] ?? [] {
                guard let full = entry["name"] as? String else { continue }
                let id = full.hasPrefix("models/") ? String(full.dropFirst(7)) : full
                let methods = entry["supportedGenerationMethods"] as? [String] ?? []
                guard methods.contains("generateContent"), id.lowercased().hasPrefix("gemini") else { continue }
                models.append(AIModelInfo(id: id, name: (entry["displayName"] as? String) ?? id, note: note(for: id)))
            }
        case .openrouter:
            for entry in object["data"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                if let architecture = entry["architecture"] as? [String: Any],
                   let output = architecture["output_modalities"] as? [String], !output.contains("text") { continue }
                let pricing = entry["pricing"] as? [String: Any]
                let free = id.hasSuffix(":free") || ((pricing?["prompt"] as? String) == "0" && (pricing?["completion"] as? String) == "0")
                models.append(AIModelInfo(id: id, name: (entry["name"] as? String) ?? id, note: free ? "gratuito" : note(for: id)))
            }
        case .custom:
            for entry in object["data"] as? [[String: Any]] ?? [] {
                guard let id = entry["id"] as? String else { continue }
                models.append(AIModelInfo(id: id, name: id))
            }
        }
        var seen = Set<String>()
        let unique = models.filter { seen.insert($0.id).inserted }
        // Prima i piccoli e veloci (bastano per questo compito), poi gli altri nell'ordine ricevuto.
        let cheap = unique.filter { $0.note != nil }
        let others = unique.filter { $0.note == nil }
        return cheap + others
    }

    static func note(for id: String) -> String? {
        let lower = id.lowercased()
        return cheapMarkers.contains(where: { lower.contains($0) }) ? "veloce ed economico" : nil
    }
}
