import Foundation

public enum PlaybackFailureKind: String, Equatable, Sendable {
    case offline
    case timeout
    case unreachable
    case forbidden
    case notFound
    case tlsFailure
    case atsBlocked
    case formatUnsupported
    case codecUnsupported
    case serverMisconfigured
    case interrupted
    case unknown
}

/// A player error explained in terms the user can act on.
public struct PlaybackFailure: Equatable, Sendable {
    public var kind: PlaybackFailureKind
    public var detail: String

    public init(kind: PlaybackFailureKind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var message: String {
        switch kind {
        case .offline: return "Nessuna connessione a Internet."
        case .timeout: return "Il server non risponde: la sorgente è lenta o non disponibile."
        case .unreachable: return "Impossibile raggiungere il server della sorgente."
        case .forbidden: return "Il server ha rifiutato l'accesso (403). Il link potrebbe essere scaduto, geolimitato o richiedere intestazioni speciali."
        case .notFound: return "File non trovato sul server (404): il link non è più valido."
        case .tlsFailure: return "Connessione sicura non riuscita: certificato non valido."
        case .atsBlocked: return "iOS ha bloccato la connessione HTTP non cifrata verso questo server."
        case .formatUnsupported: return "Formato non supportato dal motore di riproduzione. Prova un'altra sorgente o cambia motore in Impostazioni → Riproduzione."
        case .codecUnsupported: return "Il video o l'audio usa un codec che questo dispositivo non può decodificare."
        case .serverMisconfigured: return "Il server non è configurato correttamente per lo streaming (risposta HTTP non valida)."
        case .interrupted: return "La riproduzione è stata interrotta."
        case .unknown: return "Errore di riproduzione: \(detail)"
        }
    }

    /// Worth retrying on the same source once connectivity returns.
    public var isNetworkRelated: Bool {
        switch kind {
        case .offline, .timeout, .unreachable, .interrupted: return true
        default: return false
        }
    }

    /// Retrying will not help; the user should pick another source.
    public var suggestsAnotherSource: Bool {
        switch kind {
        case .forbidden, .notFound, .formatUnsupported, .codecUnsupported, .serverMisconfigured, .atsBlocked, .tlsFailure, .unknown:
            return true
        case .offline, .timeout, .unreachable, .interrupted:
            return false
        }
    }
}

public enum PlaybackErrorMapper {
    /// Maps an `NSError` (domain + code) coming from AVFoundation / CoreMedia / CFNetwork.
    public static func map(domain: String, code: Int, description: String? = nil, underlying: [(domain: String, code: Int)] = []) -> PlaybackFailure {
        let text = description ?? "\(domain) \(code)"
        // Prefer the most specific underlying error (AVFoundation usually wraps the network / CoreMedia one).
        for inner in underlying {
            let mapped = map(domain: inner.domain, code: inner.code, description: description, underlying: [])
            if mapped.kind != .unknown { return mapped }
        }
        switch domain {
        case "NSURLErrorDomain":
            switch code {
            case -1009, -1018, -1020: return PlaybackFailure(kind: .offline, detail: text)
            case -1001: return PlaybackFailure(kind: .timeout, detail: text)
            case -1003, -1004, -1005, -1002: return PlaybackFailure(kind: .unreachable, detail: text)
            case -1022: return PlaybackFailure(kind: .atsBlocked, detail: text)
            case -1200, -1201, -1202, -1203, -1204, -1205, -1206: return PlaybackFailure(kind: .tlsFailure, detail: text)
            case -1011, -1008: return PlaybackFailure(kind: .serverMisconfigured, detail: text)
            default: return PlaybackFailure(kind: .unknown, detail: text)
            }
        case "CoreMediaErrorDomain":
            switch code {
            case -12660, -12661: return PlaybackFailure(kind: .forbidden, detail: text)
            case -12938: return PlaybackFailure(kind: .notFound, detail: text)
            case -12889, -12888, -12887: return PlaybackFailure(kind: .serverMisconfigured, detail: text)
            case -12642, -12645, -12646: return PlaybackFailure(kind: .formatUnsupported, detail: text)
            default: return PlaybackFailure(kind: .unknown, detail: text)
            }
        case "AVFoundationErrorDomain":
            switch code {
            case -11828, -11829:
                return PlaybackFailure(kind: .formatUnsupported, detail: text)
            case -11800 where text.localizedCaseInsensitiveContains("cannot open"):
                return PlaybackFailure(kind: .formatUnsupported, detail: text)
            case -11833, -11839, -11821:
                return PlaybackFailure(kind: .codecUnsupported, detail: text)
            case -11850, -11819:
                return PlaybackFailure(kind: .serverMisconfigured, detail: text)
            case -11847, -11848:
                return PlaybackFailure(kind: .interrupted, detail: text)
            case -11800:
                return PlaybackFailure(kind: .formatUnsupported, detail: text)
            default: return PlaybackFailure(kind: .unknown, detail: text)
            }
        default:
            return PlaybackFailure(kind: .unknown, detail: text)
        }
    }
}
