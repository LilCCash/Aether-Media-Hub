import Foundation

/// Every failure the addon engine can surface to the UI. `message` is user-facing Italian text.
public enum AddonError: Error, Equatable, Sendable {
    case invalidURL(String)
    case blockedURL(BlockReason)
    case insecureTransport
    case timeout
    case offline
    case http(status: Int)
    case responseTooLarge(limit: Int)
    case tooManyRedirects
    case redirectBlocked(BlockReason)
    case atsBlocked
    case tlsFailure
    case unreachable(String)
    case invalidManifest(String)
    case malformedResponse(String)
    case duplicate(existingName: String)
    case configurationRequired
    case notFound
    case cancelled
    case unsupported(String)

    public enum BlockReason: Equatable, Sendable {
        case scheme(String)
        case credentialsInURL
        case privateAddress(String)
        case loopback
        case localHostname(String)
        case emptyHost
        case tooLong

        public var message: String {
            switch self {
            case .scheme(let scheme):
                return "Schema «\(scheme)» non consentito (sono ammessi solo http e https)."
            case .credentialsInURL:
                return "L'URL contiene nome utente/password incorporati: non consentito."
            case .privateAddress(let host):
                return "«\(host)» è un indirizzo di rete locale o privato. Abilita «Rete locale» nelle impostazioni per usarlo."
            case .loopback:
                return "L'indirizzo punta a questo stesso dispositivo (localhost) e non è utilizzabile."
            case .localHostname(let host):
                return "«\(host)» è un nome host locale. Abilita «Rete locale» nelle impostazioni per usarlo."
            case .emptyHost:
                return "L'URL non contiene un host valido."
            case .tooLong:
                return "L'URL è troppo lungo."
            }
        }
    }

    public var message: String {
        switch self {
        case .invalidURL(let detail):
            return "URL non valido: \(detail)"
        case .blockedURL(let reason):
            return reason.message
        case .insecureTransport:
            return "L'addon usa HTTP non cifrato su Internet. iOS blocca questa connessione (App Transport Security): usa un indirizzo https."
        case .timeout:
            return "L'addon non ha risposto in tempo."
        case .offline:
            return "Nessuna connessione a Internet."
        case .http(let status):
            return "L'addon ha risposto con errore HTTP \(status)."
        case .responseTooLarge(let limit):
            return "Risposta troppo grande (limite \(limit / 1024) KiB)."
        case .tooManyRedirects:
            return "Troppi reindirizzamenti."
        case .redirectBlocked(let reason):
            return "Reindirizzamento bloccato: \(reason.message)"
        case .atsBlocked:
            return "iOS ha bloccato una connessione HTTP non cifrata verso un indirizzo pubblico (App Transport Security)."
        case .tlsFailure:
            return "Certificato TLS non valido o connessione sicura non riuscita."
        case .unreachable(let host):
            return "Impossibile raggiungere «\(host)»."
        case .invalidManifest(let detail):
            return detail
        case .malformedResponse(let detail):
            return "Risposta dell'addon non valida: \(detail)"
        case .duplicate(let name):
            return "L'addon «\(name)» è già installato."
        case .configurationRequired:
            return "Questo addon richiede una configurazione prima dell'installazione."
        case .notFound:
            return "Contenuto non trovato presso l'addon (404)."
        case .cancelled:
            return "Operazione annullata."
        case .unsupported(let detail):
            return detail
        }
    }

    /// Whether retrying later could plausibly succeed.
    public var isTransient: Bool {
        switch self {
        case .timeout, .offline, .unreachable: return true
        case .http(let status): return status >= 500 || status == 429
        default: return false
        }
    }
}

extension AddonError: LocalizedError {
    public var errorDescription: String? { return message }
}
