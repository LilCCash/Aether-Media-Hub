import Foundation
import AetherCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Stato di Apple Intelligence su questo iPhone, detto in italiano.
enum AppleIntelligenceStatus: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { return self == .available }

    var text: String {
        switch self {
        case .available: return "Disponibile su questo iPhone"
        case .unavailable(let reason): return reason
        }
    }
}

/// Il modello di linguaggio che Apple mette sul dispositivo (iOS 26+, iPhone con Apple Intelligence): gratis, offline, privato.
enum AppleIntelligence {
    static var status: AppleIntelligenceStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("Questo dispositivo non supporta Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence è spenta: attivala in Impostazioni ▸ Apple Intelligence e Siri.")
                case .modelNotReady: return .unavailable("Il modello si sta ancora scaricando: riprova tra poco.")
                @unknown default: return .unavailable("Apple Intelligence non è disponibile.")
                }
            @unknown default:
                return .unavailable("Apple Intelligence non è disponibile.")
            }
        }
        #endif
        return .unavailable("Serve iOS 26 o successivo.")
    }

    /// Chiede al modello sul dispositivo di tradurre la frase in filtri. Nil se non disponibile o se la risposta non è leggibile.
    static func interpret(_ query: String, year: Int) async -> SearchIntent? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard status.isAvailable else { return nil }
            do {
                let session = LanguageModelSession(instructions: AIIntentCodec.systemPrompt(year: year))
                let response = try await session.respond(to: AIIntentCodec.userPrompt(query))
                return AIIntentCodec.parse(response.content, source: .apple)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}
