import Foundation

public enum CastTarget: String, Codable, CaseIterable, Sendable {
    case airPlay
    case googleCast
    case dlna

    public var title: String {
        switch self {
        case .airPlay: return "AirPlay"
        case .googleCast: return "Google Cast"
        case .dlna: return "DLNA / UPnP"
        }
    }
}

public enum CastVerdict: Equatable, Sendable {
    /// Expected to work.
    case ok
    /// May work; the messages explain the risk. The user decides.
    case warning([String])
    /// Will not work; sending would only produce a silent failure on the TV.
    case blocked(String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var messages: [String] {
        switch self {
        case .ok: return []
        case .warning(let messages): return messages
        case .blocked(let message): return [message]
        }
    }
}

/// Pre-flight check before handing a URL to a remote receiver. The receiver fetches the media itself, so the
/// URL must be reachable *from the TV*, not just from the phone. These rules encode what is knowable offline;
/// the real reachability test is done by the receiver and surfaced as a playback error.
public enum CastCompatibility {
    public enum HostKind: Equatable, Sendable {
        case publicInternet
        case localNetwork
        case loopback
    }

    public static func hostKind(of url: URL) -> HostKind {
        guard var host = url.host?.lowercased() else { return .publicInternet }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if let address = IPAddress.parse(host) {
            switch address.addressClass {
            case .loopback, .unspecified: return .loopback
            case .privateNetwork, .linkLocal: return .localNetwork
            default: return .publicInternet
            }
        }
        if !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return .localNetwork
        }
        return .publicInternet
    }

    private static let castContainers: Set<String> = ["mp4", "m4v", "webm", "m3u8", "mpd", "mp3", "m4a", "aac", "mkv"]
    private static let dlnaContainers: Set<String> = ["mp4", "m4v", "mkv", "avi", "ts", "mov", "mp3", "m4a", "aac", "mpg", "mpeg", "wmv", "flac", "wav"]

    /// - Parameter delivery: how the address reaches the receiver. With `.relay` the phone serves the video itself, so `url` is the
    ///   address of the *real source* (which only the phone contacts): the receiver neither needs to reach it nor to receive headers.
    public static func evaluate(url: URL, info: StreamInfo, headers: [String: String] = [:],
                                target: CastTarget, hasExternalSubtitles: Bool = false,
                                delivery: CastDelivery = .direct) -> CastVerdict {
        var warnings: [String] = []
        let relayed = delivery == .relay
        let host = hostKind(of: url)
        switch host {
        case .loopback:
            return .blocked("L'indirizzo punta a questo telefono (localhost): il televisore non può raggiungerlo.")
        case .localNetwork:
            if !relayed { warnings.append("La sorgente è nella rete locale: il televisore deve essere nella stessa rete.") }
        case .publicInternet:
            break
        }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            return .blocked("Protocollo «\(scheme)» non inviabile al televisore.")
        }
        if relayed && scheme == "http" && host == .publicInternet {
            return .blocked(CastRefusal.plainHTTPNeedsRelay.message)
        }
        if delivery == .directWithKey {
            warnings.append("Il televisore riceverà il link con la tua chiave TorBox (scelta fatta in Impostazioni ▸ Avanzate).")
            if target == .dlna { warnings.append("Con DLNA il link viene inviato in chiaro sulla rete locale.") }
        }

        let container = info.container ?? ""
        switch target {
        case .airPlay:
            if case .unsupported(let reason) = info.support {
                return .blocked(reason.message)
            }
            if !headers.isEmpty {
                warnings.append("Questa sorgente richiede header HTTP personalizzati: AirPlay potrebbe non inoltrarli e fallire.")
            }
            if hasExternalSubtitles {
                warnings.append("I sottotitoli esterni di Aether non vengono mostrati sul televisore in AirPlay (solo tracce incorporate).")
            }
        case .googleCast:
            if !headers.isEmpty && !relayed {
                return .blocked("Questa sorgente richiede header HTTP personalizzati, che Google Cast non può inviare.")
            }
            switch info.kind {
            case .torrent, .youtube, .externalPage, .playerFrame, .archive, .other:
                if case .unsupported(let reason) = info.support { return .blocked(reason.message) }
            default:
                break
            }
            if !container.isEmpty && !castContainers.contains(container) {
                return .blocked("Il formato .\(container) non è supportato da Google Cast (MP4, WebM, HLS, DASH).")
            }
            if container == "mkv" {
                warnings.append("MKV è supportato solo da alcuni dispositivi (Chromecast Ultra, Google TV, Android TV).")
            }
            if container == "m3u8" || container == "mpd" {
                warnings.append("HLS/DASH su Google Cast richiedono che il server invii gli header CORS.")
            }
            if container.isEmpty {
                warnings.append("Formato non verificabile: se il file non è MP4/WebM/HLS il televisore lo rifiuterà.")
            }
            if info.codec == .hevc {
                warnings.append("HEVC è supportato solo da Chromecast Ultra / Google TV.")
            }
            if scheme == "http" && !relayed {
                warnings.append("Sorgente non cifrata (HTTP): alcuni ricevitori la bloccano.")
            }
            if hasExternalSubtitles {
                warnings.append("I sottotitoli esterni di Aether non vengono inviati a Google Cast in questa versione: sul televisore compaiono solo le tracce già incorporate nel file.")
            }
        case .dlna:
            if !headers.isEmpty && !relayed {
                return .blocked("Questa sorgente richiede header HTTP personalizzati, che DLNA non può inviare.")
            }
            if case .unsupported(let reason) = info.support, info.kind != .file {
                return .blocked(reason.message)
            }
            if container == "mpd" {
                return .blocked("DASH non è supportato dai renderer DLNA.")
            }
            if container == "m3u8" {
                warnings.append("Molti renderer DLNA non supportano HLS.")
            } else if !container.isEmpty && !dlnaContainers.contains(container) {
                warnings.append("Formato .\(container) non verificato per DLNA.")
            }
            if scheme == "https" && !relayed {
                warnings.append("Molti televisori DLNA non gestiscono HTTPS: se non parte, serve una sorgente HTTP.")
            }
            if hasExternalSubtitles {
                warnings.append("I sottotitoli esterni non sono supportati in modo uniforme da DLNA.")
            }
        }
        return warnings.isEmpty ? .ok : .warning(warnings)
    }

    /// Guidance shown in the casting screen for Android TV devices.
    public static let androidTVGuidance: [String] = [
        "Android TV / Google TV con «Chromecast integrato» compaiono in Google Cast.",
        "Android TV senza Google Cast: prova DLNA/UPnP (serve un'app renderer sul televisore, es. un ricevitore DLNA) e aggiungi l'indirizzo manualmente.",
        "La scoperta automatica DLNA (SSDP) richiede l'entitlement multicast di Apple; senza di esso usa l'aggiunta manuale.",
        "Il televisore scarica il video direttamente: URL privati, protetti da header o raggiungibili solo dal telefono non funzioneranno."
    ]
}
