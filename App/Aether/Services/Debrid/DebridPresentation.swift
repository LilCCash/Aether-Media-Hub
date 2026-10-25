import Foundation
import AetherCore

// Italian texts and number formats for the TorBox flows (Settings, stream picker, player). Pure functions: no I/O, no state,
// nothing here ever sees an API key or a download link.

enum DebridFormat {
    /// "42%" for a fraction of 0...1; nil when the provider reported nothing usable.
    static func percent(_ fraction: Double?) -> String? {
        guard let value = fraction, value.isFinite else { return nil }
        let clamped = min(1.0, max(0.0, value))
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// "15 MB/s"; nil for a missing or zero speed.
    static func speed(_ bytesPerSecond: Int64?) -> String? {
        guard let value = bytesPerSecond, value > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file) + "/s"
    }

    /// "12 s", "3 min", "1 h 05 min" (rounded up); nil for a missing or zero estimate.
    static func eta(_ seconds: Int?) -> String? {
        guard let total = seconds, total > 0 else { return nil }
        if total < 60 { return "\(total) s" }
        let totalMinutes = (total + 59) / 60
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%ld h %02ld min", hours, minutes)
    }

    /// What goes under the progress bar: "42% · 15 MB/s · ancora 3 s". Only what the provider really reported; nil when
    /// nothing is known. The percentage is only meaningful while TorBox is downloading.
    static func detail(for progress: DebridProgress?) -> String? {
        guard let progress = progress else { return nil }
        var parts: [String] = []
        if progress.phase == DebridProgress.Phase.downloading, let percentText = DebridFormat.percent(progress.fraction) {
            parts.append(percentText)
        }
        if let speedText = DebridFormat.speed(progress.downloadSpeed) { parts.append(speedText) }
        if let etaText = DebridFormat.eta(progress.etaSeconds) { parts.append("ancora " + etaText) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One line for a status pill: the provider's step plus the percentage while it downloads.
    static func statusLine(for progress: DebridProgress) -> String {
        if progress.phase == DebridProgress.Phase.downloading, let percentText = DebridFormat.percent(progress.fraction) {
            return progress.message + " " + percentText
        }
        return progress.message
    }
}

/// The small badge on a torrent row. nil in `badge(status:isChecking:)` means "show nothing": the status is unknown (for
/// example the check failed) and an unknown status is never presented as "not in cache".
enum DebridCacheBadge: Equatable {
    case checking
    case cached
    case notCached

    var label: String {
        switch self {
        case .checking: return "Verifica…"
        case .cached: return DebridCacheStatus.cached.label
        case .notCached: return DebridCacheStatus.notCached.label
        }
    }

    var systemImage: String {
        switch self {
        case .checking: return "clock"
        case .cached: return "checkmark.circle.fill"
        case .notCached: return "arrow.down.circle"
        }
    }

    var accessibilityText: String {
        switch self {
        case .checking: return "Verifica della cache TorBox in corso"
        case .cached: return "In cache su TorBox"
        case .notCached: return "Non in cache su TorBox: va prima scaricato"
        }
    }

    static func badge(status: DebridCacheStatus?, isChecking: Bool) -> DebridCacheBadge? {
        if let status = status {
            switch status {
            case .cached: return DebridCacheBadge.cached
            case .notCached: return DebridCacheBadge.notCached
            case .unknown: break
            }
        }
        return isChecking ? DebridCacheBadge.checking : nil
    }
}

enum DebridErrorText {
    static let settingsPath = "Impostazioni › Servizi"

    /// Provider-aware errors: the shared DebridError type has legacy TorBox wording, so never show that wording
    /// when the active provider is Real-Debrid.
    static func message(for error: DebridError) -> String {
        return message(for: error, provider: .torbox)
    }

    static func message(for error: DebridError, provider: DebridService.ProviderChoice) -> String {
        let name = provider.title
        switch error {
        case .notConfigured:
            return "Nessuna chiave \(name) salvata: aggiungila in \(settingsPath)."
        case .authFailed:
            return "\(name) ha rifiutato il token API. Controllalo o rigeneralo e salvalo in \(settingsPath)."
        case .planRestricted:
            return "Questa funzione non è inclusa nel tuo piano \(name)."
        case .notCached:
            return "Questo contenuto non risulta nella cache di \(name): serve prima renderlo disponibile."
        case .alreadyInAccount:
            return "\(name) segnala che il torrent è già presente o in coda, ma non è visibile nella lista."
        case .itemNotFound:
            return "Elemento non trovato su \(name)."
        case .queuedAtProvider:
            return "Il torrent è in coda su \(name). Riprova tra poco."
        case .downloadNotReady(let progress):
            if let fraction = progress?.fraction {
                let percent = Int((min(1, max(0, fraction)) * 100).rounded())
                return "Il download su \(name) non è ancora completo (\(percent)%). Riprova tra poco."
            }
            return "Il download su \(name) non è ancora completo. Riprova tra poco."
        case .itemFailed(let state):
            return "\(name) segnala un errore su questo torrent (stato: \(state))."
        case .serviceUnavailable(let status):
            if let status = status { return "\(name) non risponde correttamente (errore \(status)). Riprova più tardi." }
            return "\(name) non risponde correttamente. Riprova più tardi."
        case .timeout:
            return "\(name) non ha risposto in tempo."
        case .unreachable:
            return "Impossibile raggiungere \(name)."
        case .refusedHost:
            return "Connessione bloccata: l'indirizzo non corrisponde a \(name)."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter, seconds > 0 {
                return "\(name) sta limitando le richieste. Riprova tra circa \(Int(seconds.rounded(.up))) secondi."
            }
            return "\(name) sta limitando le richieste. Riprova tra poco."
        case .api(let code, _):
            if code == "INSTANT_AVAILABILITY_UNSUPPORTED" && provider == .realdebrid {
                return "Real-Debrid non offre più il controllo istantaneo della cache. Il token può essere valido: per usare un torrent non già presente nel tuo account, scegli l'avvio del download; Aether non aggiungerà torrent in modalità istantanea."
            }
            return "\(name) ha risposto con un errore (\(code))."
        default:
            return error.message
        }
    }

    /// Any error thrown while resolving through the selected provider.
    static func describe(_ error: Error, provider: DebridService.ProviderChoice = .torbox) -> String {
        if let debrid = error as? DebridError { return message(for: debrid, provider: provider) }
        if error is CancellationError { return "Operazione annullata." }
        return "Errore imprevisto durante la comunicazione con \(provider.title)."
    }

    /// Why the connection check of Settings > Servizi failed.
    static func connectionMessage(for error: DebridError) -> String {
        switch error {
        case .authFailed:
            return "Chiave non valida: TorBox l'ha rifiutata. Controlla di averla copiata per intero oppure creane una nuova su torbox.app."
        case .planRestricted:
            return "Il tuo piano TorBox non consente questa funzione. Controlla il piano del tuo account su torbox.app."
        case .notConfigured:
            return "Nessuna chiave salvata."
        default:
            return error.message
        }
    }

    /// The same, for any error (a non-TorBox error is reported generically, never with its raw text).
    static func connectionMessage(forAny error: Error) -> String {
        if let debrid = error as? DebridError { return connectionMessage(for: debrid) }
        return "Errore imprevisto durante la verifica della connessione."
    }
}

enum DebridUserText {
    static let configureHint = "Per riprodurlo configura TorBox in \(DebridErrorText.settingsPath)."

    static let torrentNeedsTorBox = "Per riprodurre i torrent serve TorBox: aggiungi la tua chiave in \(DebridErrorText.settingsPath). In alternativa puoi indicare un server di streaming esterno in Impostazioni › Avanzate."

    static let downloadConfirmationTitle = "Avvia il download su TorBox?"

    static let downloadConfirmationMessage = "Questo contenuto non è nella cache di TorBox: verrà aggiunto al tuo account TorBox e scaricato prima di poterlo guardare. Può richiedere alcuni minuti e conta nei limiti del tuo piano. Aether non cancella mai nulla dal tuo account."
}
