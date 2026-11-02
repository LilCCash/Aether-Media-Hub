import Foundation

/// I lettori di altri produttori a cui si può passare un indirizzo video (VLC, Infuse, nPlayer, Outplayer).
/// Servono i loro «schemi» nell'Info.plist (`LSApplicationQueriesSchemes`) per sapere quali sono installati.
public enum ExternalPlayer: String, CaseIterable, Sendable {
    case vlc, infuse, nplayer, outplayer

    public var title: String {
        switch self {
        case .vlc: return "VLC"
        case .infuse: return "Infuse"
        case .nplayer: return "nPlayer"
        case .outplayer: return "Outplayer"
        }
    }

    /// Lo schema da interrogare per sapere se l'app è installata.
    public var probeURL: URL? {
        switch self {
        case .vlc: return URL(string: "vlc-x-callback://")
        case .infuse: return URL(string: "infuse://")
        case .nplayer: return URL(string: "nplayer-http://")
        case .outplayer: return URL(string: "outplayer://")
        }
    }

    /// L'indirizzo che apre `media` nel lettore. Solo per link diretti http/https.
    public func url(for media: URL) -> URL? {
        let scheme = media.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return nil }
        let text = media.absoluteString
        switch self {
        case .vlc:
            return URL(string: "vlc-x-callback://x-callback-url/stream?url=" + Self.encode(text))
        case .infuse:
            return URL(string: "infuse://x-callback-url/play?url=" + Self.encode(text))
        case .nplayer:
            return URL(string: "nplayer-" + text)
        case .outplayer:
            return URL(string: "outplayer://" + text)
        }
    }

    static func encode(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

extension AddonStream {
    /// L'indirizzo diretto del video, se la fonte ne ha uno (http/https): è quello che si può dare a un lettore esterno.
    public var directMediaURL: URL? {
        guard case .url(let text) = source, let url = URL.lenient(text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// La fonte vuole intestazioni particolari (Referer, User-Agent…): un lettore esterno non le manda e il server può rifiutare.
    public var needsRequestHeaders: Bool { return !behaviorHints.proxyRequestHeaders.isEmpty }
}
