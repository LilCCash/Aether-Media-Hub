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
    public static func systemPrompt(year: Int) -> String {
        let genres = IntentGenre.allCases.map { $0.rawValue }.joined(separator: ", ")
        return """
        You turn a movie/TV search request (usually in Italian) into filters for the TMDB discover API. \
        Reply with ONE JSON object and nothing else, with these optional keys: \
        "kind" ("movie" or "series", omit for both); \
        "genres" (array, only from: \(genres)); \
        "keywords" (array of 0-3 short English TMDB keywords such as "heist", "slasher", "parody", "time travel"); \
        "year_from" and "year_to" (integers); \
        "sort" ("popularity", "rating", "newest" or "oldest"); \
        "min_rating" (0-10); \
        "countries" (array of ISO 3166-1 codes); \
        "max_runtime" (minutes); \
        "title" (only if the user names one specific title). \
        The current year is \(year): "recent years" means the last 5 years. Never explain, never add text outside the JSON.
        """
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

    public func interpret(_ query: String, settings: AdvancedSearchSettings, year: Int) async throws -> SearchIntent {
        let provider = settings.provider
        let secret = key(provider)
        if secret == nil && !provider.keyIsOptional { throw AISearchError.notConfigured }
        let model = settings.model(for: provider)
        guard !model.isEmpty else { throw AISearchError.notConfigured }
        let system = AIIntentCodec.systemPrompt(year: year)
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

    /// Prova la chiave con una frase breve (pulsante «Prova» delle impostazioni).
    public func test(settings: AdvancedSearchSettings, year: Int) async -> AISearchError? {
        do {
            _ = try await interpret("commedie degli ultimi anni", settings: settings, year: year)
            return nil
        } catch let error as AISearchError {
            return error
        } catch {
            return .unavailable
        }
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
            body = ["model": model, "max_tokens": 300, "system": system,
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
