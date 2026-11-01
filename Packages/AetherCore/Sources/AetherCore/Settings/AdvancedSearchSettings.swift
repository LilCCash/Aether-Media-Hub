import Foundation

/// Chi interpreta le frasi della ricerca avanzata.
public enum AISearchProvider: String, Codable, CaseIterable, Sendable {
    case anthropic, openai, google, openrouter, custom

    public var title: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .google: return "Gemini (Google)"
        case .openrouter: return "OpenRouter"
        case .custom: return "Server compatibile OpenAI"
        }
    }

    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-5-5"
        case .openai: return "gpt-4o-mini"
        case .google: return "gemini-2.5-flash"
        case .openrouter: return "openai/gpt-4o-mini"
        case .custom: return ""
        }
    }

    /// Modelli piccoli e veloci tra cui scegliere; l'utente può scriverne uno diverso.
    public var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-haiku-5-5", "claude-sonnet-5-5"]
        case .openai: return ["gpt-4o-mini", "gpt-4o"]
        case .google: return ["gemini-2.5-flash", "gemini-2.5-flash-lite"]
        case .openrouter: return ["openai/gpt-4o-mini", "anthropic/claude-haiku-5-5", "google/gemini-2.0-flash-001"]
        case .custom: return []
        }
    }

    /// Il server accetta richieste senza chiave (solo quello personalizzato).
    public var keyIsOptional: Bool { return self == .custom }
}

/// Quale intelligenza artificiale risponde.
public enum AIEngine: String, Codable, CaseIterable, Sendable {
    /// Prima Apple Intelligence sul dispositivo; se non c'è o non basta, il modello in rete.
    case appleThenNetwork
    /// Solo Apple Intelligence sul dispositivo (gratis, privata).
    case appleOnly
    /// Solo il modello in rete scelto, con la tua chiave.
    case networkOnly

    public var title: String {
        switch self {
        case .appleThenNetwork: return "Apple Intelligence, poi modello in rete"
        case .appleOnly: return "Solo Apple Intelligence (sul dispositivo)"
        case .networkOnly: return "Solo modello in rete (con chiave)"
        }
    }
}

/// Quando interpellare l'intelligenza artificiale.
public enum AISearchTrigger: String, Codable, CaseIterable, Sendable {
    /// Solo premendo «Cerca» sulla tastiera (una richiesta per ricerca).
    case onSubmit
    /// Mentre scrivi, dopo una breve pausa (più richieste).
    case whileTyping

    public var title: String {
        switch self {
        case .onSubmit: return "Premendo Cerca"
        case .whileTyping: return "Mentre scrivo"
        }
    }
}

/// Quando l'AI interviene rispetto al parser locale.
public enum AISearchMode: String, Codable, CaseIterable, Sendable {
    /// Solo se il parser locale non ha capito la frase.
    case fallback
    /// Sempre, per ogni frase.
    case always

    public var title: String {
        switch self {
        case .fallback: return "Solo se il parser non capisce"
        case .always: return "Sempre"
        }
    }
}

public enum AdvancedResultKind: String, Codable, CaseIterable, Sendable {
    case both, movie, series

    public var title: String {
        switch self {
        case .both: return "Film e serie"
        case .movie: return "Solo film"
        case .series: return "Solo serie"
        }
    }
}

/// Impostazioni ▸ Ricerca avanzata: ricerca per parole chiave, frasi in italiano e modelli di intelligenza artificiale.
public struct AdvancedSearchSettings: Codable, Equatable, Sendable {
    /// Interruttore generale.
    public var enabled: Bool = false
    // Livelli
    /// Livello 1: parole chiave di TMDB («slasher», «heist»…).
    public var keywordSearch: Bool = true
    /// Livello 2: parser locale delle frasi («commedie degli ultimi anni»), senza AI né rete oltre a TMDB.
    public var naturalParser: Bool = true
    /// Livello 3: modello di intelligenza artificiale.
    public var aiEnabled: Bool = false
    // AI
    /// Chi risponde: Apple Intelligence sul dispositivo, il modello in rete, o prima l'uno poi l'altro.
    public var aiEngine: AIEngine = .networkOnly
    /// L'AI propone direttamente i titoli (non solo i filtri): «film simili a…», «consigliami…».
    public var aiSuggestsTitles: Bool = true
    public var provider: AISearchProvider = .anthropic
    public var models: [String: String] = [:]
    public var customBaseURL: String = ""
    public var aiTrigger: AISearchTrigger = .onSubmit
    public var aiMode: AISearchMode = .always
    public var aiTimeout: Int = 15
    // Risultati
    public var resultKind: AdvancedResultKind = .both
    public var maxResults: Int = 20
    /// Voti minimi perché un titolo sia proposto quando si ordina per valutazione.
    public var minVotes: Int = 300
    public var showInterpretation: Bool = true
    public var showSource: Bool = true
    public var includeAdult: Bool = false
    public var rememberInterpretations: Bool = true

    public init() {}

    public func model(for provider: AISearchProvider) -> String {
        let chosen = (models[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return chosen.isEmpty ? provider.defaultModel : chosen
    }

    public mutating func setModel(_ model: String, for provider: AISearchProvider) {
        models[provider.rawValue] = model
    }

    /// C'è almeno un livello utilizzabile.
    public var hasAnyLevel: Bool { return enabled && (keywordSearch || naturalParser || aiEnabled) }

    private enum CodingKeys: String, CodingKey {
        case enabled, keywordSearch, naturalParser, aiEnabled, aiEngine, aiSuggestsTitles, provider, models
        case customBaseURL, aiTrigger, aiMode, aiTimeout, resultKind, maxResults, minVotes, showInterpretation
        case showSource, includeAdult, rememberInterpretations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: false)
        keywordSearch = c.value(.keywordSearch, default: true)
        naturalParser = c.value(.naturalParser, default: true)
        aiEnabled = c.value(.aiEnabled, default: false)
        aiEngine = c.value(.aiEngine, default: .networkOnly)
        aiSuggestsTitles = c.value(.aiSuggestsTitles, default: true)
        provider = c.value(.provider, default: .anthropic)
        models = c.value(.models, default: [:])
        customBaseURL = c.value(.customBaseURL, default: "")
        aiTrigger = c.value(.aiTrigger, default: .onSubmit)
        aiMode = c.value(.aiMode, default: .always)
        aiTimeout = min(60, max(5, c.value(.aiTimeout, default: 15)))
        resultKind = c.value(.resultKind, default: .both)
        maxResults = min(40, max(5, c.value(.maxResults, default: 20)))
        minVotes = min(5000, max(0, c.value(.minVotes, default: 300)))
        showInterpretation = c.value(.showInterpretation, default: true)
        showSource = c.value(.showSource, default: true)
        includeAdult = c.value(.includeAdult, default: false)
        rememberInterpretations = c.value(.rememberInterpretations, default: true)
    }
}
