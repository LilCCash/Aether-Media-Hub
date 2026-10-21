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

    /// Shown next to a torrent in the picker and in the player. Wording that points at "the settings" is made concrete.
    static func message(for error: DebridError) -> String {
        switch error {
        case .notConfigured:
            return "Nessuna chiave TorBox salvata: aggiungila in \(settingsPath)."
        case .authFailed:
            return "TorBox ha rifiutato la chiave. Controllala o creane una nuova, poi salvala in \(settingsPath)."
        default:
            return error.message
        }
    }

    /// Any error thrown by a TorBox call, as text for the user.
    static func describe(_ error: Error) -> String {
        if let debrid = error as? DebridError { return message(for: debrid) }
        if error is CancellationError { return "Operazione annullata." }
        return "Errore imprevisto durante la comunicazione con TorBox."
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
