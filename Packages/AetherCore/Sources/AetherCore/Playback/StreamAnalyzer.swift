import Foundation

public enum StreamQuality: Int, Comparable, Codable, Sendable {
    case unknown = 0
    case sd = 1
    case hd720 = 2
    case fullHD1080 = 3
    case uhd2160 = 4

    public static func < (lhs: StreamQuality, rhs: StreamQuality) -> Bool { return lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .unknown: return "—"
        case .sd: return "SD"
        case .hd720: return "720p"
        case .fullHD1080: return "1080p"
        case .uhd2160: return "4K"
        }
    }

    public var height: Int {
        switch self {
        case .unknown: return 0
        case .sd: return 480
        case .hd720: return 720
        case .fullHD1080: return 1080
        case .uhd2160: return 2160
        }
    }
}

public enum VideoCodec: String, Codable, Sendable {
    case h264, hevc, av1, vp9, mpeg2, xvid

    public var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .vp9: return "VP9"
        case .mpeg2: return "MPEG-2"
        case .xvid: return "Xvid"
        }
    }
}

public enum HDRFormat: String, Codable, Sendable {
    case hdr10, hdr10Plus, dolbyVision, hlg

    public var label: String {
        switch self {
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .dolbyVision: return "Dolby Vision"
        case .hlg: return "HLG"
        }
    }
}

public enum AudioCodec: String, Codable, Sendable {
    case aac, ac3, eac3, dts, truehd, atmos, flac, opus, mp3

    public var label: String {
        switch self {
        case .aac: return "AAC"
        case .ac3: return "Dolby Digital"
        case .eac3: return "Dolby Digital+"
        case .dts: return "DTS"
        case .truehd: return "TrueHD"
        case .atmos: return "Atmos"
        case .flac: return "FLAC"
        case .opus: return "Opus"
        case .mp3: return "MP3"
        }
    }
}

public enum StreamKind: String, Codable, Sendable {
    case file, hls, dash, torrent, youtube, externalPage, playerFrame, archive, other
}

public enum UnsupportedReason: Equatable, Sendable {
    case container(String)
    case dash
    case torrent
    case youtube
    case externalPage
    case playerFrame
    case archive(String)
    case transport(String)
    case localStreamingServer
    case invalidURL
    case blockedByPolicy(String)

    public var message: String {
        switch self {
        case .container(let ext):
            return "Il contenitore .\(ext) non è riproducibile da AVPlayer (iOS supporta MP4, MOV, M4V e HLS)."
        case .dash:
            return "I flussi DASH (.mpd) non sono supportati da AVPlayer."
        case .torrent:
            return "Questo è un torrent: richiede un server di streaming esterno (Impostazioni → Avanzate)."
        case .youtube:
            return "Video YouTube: non c'è un player YouTube integrato, può essere aperto nel browser."
        case .externalPage:
            return "Questa sorgente è una pagina web esterna, non un flusso video."
        case .playerFrame:
            return "Sorgente basata su un player incorporato (iframe), non supportata."
        case .archive(let kind):
            return "Sorgente \(kind) (archivio/usenet): richiede il server di streaming Stremio, non disponibile su iOS."
        case .transport(let scheme):
            return "Protocollo «\(scheme)» non supportato."
        case .localStreamingServer:
            return "La sorgente punta al server Stremio locale (127.0.0.1:11470), che non esiste su iOS."
        case .invalidURL:
            return "URL della sorgente non valido."
        case .blockedByPolicy(let detail):
            return detail
        }
    }
}

public enum PlaybackSupport: Equatable, Sendable {
    case supported
    /// Cannot tell without trying (no recognisable extension).
    case unknown
    case unsupported(UnsupportedReason)

    public var isPlayable: Bool {
        switch self {
        case .supported, .unknown: return true
        case .unsupported: return false
        }
    }
}

public struct StreamInfo: Sendable {
    public var quality: StreamQuality
    public var codec: VideoCodec?
    public var hdr: [HDRFormat]
    public var audio: [AudioCodec]
    public var languages: [String]
    public var sizeBytes: Int64?
    public var kind: StreamKind
    public var container: String?
    public var support: PlaybackSupport
    public var warnings: [String]
    public var needsHeaders: Bool

    /// One-line badge summary, e.g. "1080p · HEVC · HDR10 · Dolby Digital+".
    public var badges: [String] {
        var parts: [String] = []
        if quality != .unknown { parts.append(quality.label) }
        if let codec = codec { parts.append(codec.label) }
        parts.append(contentsOf: hdr.map { $0.label })
        if let audio = audio.first { parts.append(audio.label) }
        return parts
    }

    public var sizeLabel: String? {
        guard let size = sizeBytes, size > 0 else { return nil }
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(size) / 1_048_576)
    }
}

/// Derives playable-ness and presentation info from an addon stream. Pure and deterministic.
public enum StreamAnalyzer {
    /// Containers AVPlayer opens natively.
    public static let supportedContainers: Set<String> = ["mp4", "m4v", "mov", "m3u8", "mp3", "m4a", "aac", "wav", "caf", "aif", "aiff", "ac3", "ec3"]
    /// Containers it does not.
    public static let unsupportedContainers: Set<String> = ["mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "divx", "ogv", "ogm", "ts", "m2ts", "vob", "rmvb", "3gp2", "asf", "mka"]

    public static func analyze(_ stream: AddonStream, streamingServer: URL? = nil) -> StreamInfo {
        let text = stream.searchableText
        let tokens = tokenize(text)
        var warnings: [String] = []

        let quality = detectQuality(text: text.lowercased(), tokens: tokens)
        let codec = detectCodec(tokens: tokens, text: text.lowercased())
        let hdr = detectHDR(tokens: tokens, text: text.lowercased())
        let audio = detectAudio(tokens: tokens, text: text.lowercased())
        let languages = detectLanguages(text: text, tokens: tokens)
        let size = stream.behaviorHints.videoSize ?? detectSize(text: text)

        if audio.contains(where: { $0 == .dts || $0 == .truehd })
            && !audio.contains(where: { $0 == .aac || $0 == .ac3 || $0 == .eac3 || $0 == .atmos }) {
            warnings.append("Audio DTS/TrueHD: iOS non lo decodifica, potrebbe mancare l'audio.")
        }
        if codec == .av1 {
            warnings.append("AV1 richiede la decodifica hardware (iPhone 15 Pro o successivo).")
        }
        let needsHeaders = !stream.behaviorHints.proxyRequestHeaders.isEmpty

        var kind: StreamKind = .other
        var container: String?
        var support: PlaybackSupport = .unknown

        switch stream.source {
        case .url(let raw):
            guard let url = URL.lenient(raw), let scheme = url.scheme?.lowercased() else {
                support = .unsupported(.invalidURL)
                kind = .other
                break
            }
            if scheme != "http" && scheme != "https" {
                support = .unsupported(.transport(scheme))
                kind = .other
                break
            }
            if isLocalStreamingServer(url) {
                support = .unsupported(.localStreamingServer)
                kind = .other
                break
            }
            let urlExtension = url.pathExtension.lowercased()
            let hintExtension = filenameExtension(stream.behaviorHints.filename)
            if urlExtension == "m3u8" || (urlExtension.isEmpty && raw.lowercased().contains(".m3u8")) {
                kind = .hls
                container = "m3u8"
                support = .supported
            } else if urlExtension == "mpd" {
                kind = .dash
                container = "mpd"
                support = .unsupported(.dash)
            } else {
                kind = .file
                let chosen = !urlExtension.isEmpty && (supportedContainers.contains(urlExtension) || unsupportedContainers.contains(urlExtension))
                    ? urlExtension : hintExtension
                container = chosen.isEmpty ? nil : chosen
                if let ext = container {
                    if supportedContainers.contains(ext) {
                        support = .supported
                    } else if unsupportedContainers.contains(ext) {
                        support = .unsupported(.container(ext))
                    } else {
                        support = .unknown
                    }
                } else {
                    support = .unknown
                }
            }
        case .youtube:
            kind = .youtube
            support = .unsupported(.youtube)
        case .torrent:
            kind = .torrent
            if streamingServer != nil {
                support = .unknown
                warnings.append("Torrent tramite server esterno (sperimentale).")
            } else {
                support = .unsupported(.torrent)
            }
        case .external:
            kind = .externalPage
            support = .unsupported(.externalPage)
        case .playerFrame:
            kind = .playerFrame
            support = .unsupported(.playerFrame)
        case .archive(let archiveKind):
            kind = .archive
            support = .unsupported(.archive(archiveKind))
        case .unknown:
            kind = .other
            support = .unsupported(.invalidURL)
        }

        return StreamInfo(quality: quality, codec: codec, hdr: hdr, audio: audio, languages: languages,
                          sizeBytes: size, kind: kind, container: container, support: support,
                          warnings: warnings, needsHeaders: needsHeaders)
    }

    // MARK: Detection

    static func tokenize(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "+" {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { tokens.insert(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.insert(current) }
        return tokens
    }

    static func detectQuality(text: String, tokens: Set<String>) -> StreamQuality {
        if tokens.contains("2160p") || tokens.contains("4k") || tokens.contains("uhd") || tokens.contains("2160") {
            return .uhd2160
        }
        if tokens.contains("1080p") || tokens.contains("1080i") || tokens.contains("fhd") || tokens.contains("1080") {
            return .fullHD1080
        }
        if tokens.contains("720p") || tokens.contains("720") {
            return .hd720
        }
        if tokens.contains("480p") || tokens.contains("576p") || tokens.contains("sd") || tokens.contains("dvdrip") {
            return .sd
        }
        // "1920x1080"
        if text.contains("x1080") { return .fullHD1080 }
        if text.contains("x2160") { return .uhd2160 }
        if text.contains("x720") { return .hd720 }
        return .unknown
    }

    static func detectCodec(tokens: Set<String>, text: String) -> VideoCodec? {
        if tokens.contains("hevc") || tokens.contains("x265") || tokens.contains("h265") || text.contains("h.265") {
            return .hevc
        }
        if tokens.contains("av1") { return .av1 }
        if tokens.contains("x264") || tokens.contains("h264") || tokens.contains("avc") || text.contains("h.264") {
            return .h264
        }
        if tokens.contains("vp9") { return .vp9 }
        if tokens.contains("xvid") || tokens.contains("divx") { return .xvid }
        if tokens.contains("mpeg2") { return .mpeg2 }
        return nil
    }

    static func detectHDR(tokens: Set<String>, text: String) -> [HDRFormat] {
        var result: [HDRFormat] = []
        if tokens.contains("dv") || tokens.contains("dovi") || text.contains("dolby vision") || text.contains("dolbyvision") {
            result.append(.dolbyVision)
        }
        if tokens.contains("hdr10+") || tokens.contains("hdr10plus") { result.append(.hdr10Plus) }
        else if tokens.contains("hdr10") || tokens.contains("hdr") { result.append(.hdr10) }
        if tokens.contains("hlg") { result.append(.hlg) }
        return result
    }

    static func detectAudio(tokens: Set<String>, text: String) -> [AudioCodec] {
        var result: [AudioCodec] = []
        func add(_ codec: AudioCodec) { if !result.contains(codec) { result.append(codec) } }
        if tokens.contains("atmos") { add(.atmos) }
        if tokens.contains("truehd") { add(.truehd) }
        if tokens.contains("eac3") || tokens.contains("ddp") || tokens.contains("dd+") || text.contains("dd+") || text.contains("e-ac-3") { add(.eac3) }
        if tokens.contains("ac3") || tokens.contains("dd5") || text.contains("dolby digital") { add(.ac3) }
        if tokens.contains("dts") || tokens.contains("dtshd") || tokens.contains("dts-hd") { add(.dts) }
        if tokens.contains("aac") { add(.aac) }
        if tokens.contains("flac") { add(.flac) }
        if tokens.contains("opus") { add(.opus) }
        if tokens.contains("mp3") { add(.mp3) }
        return result
    }

    private static let languageTokens: [String: String] = [
        "ita": "it", "italian": "it", "italiano": "it",
        "eng": "en", "english": "en",
        "fra": "fr", "fre": "fr", "french": "fr", "vff": "fr",
        "spa": "es", "spanish": "es", "esp": "es", "latino": "es",
        "ger": "de", "deu": "de", "german": "de",
        "por": "pt", "portuguese": "pt",
        "rus": "ru", "russian": "ru",
        "jpn": "ja", "jap": "ja", "japanese": "ja",
        "kor": "ko", "korean": "ko",
        "hin": "hi", "hindi": "hi",
        "chi": "zh", "chinese": "zh",
        "multi": "multi", "dual": "multi"
    ]

    private static let flagLanguages: [String: String] = [
        "IT": "it", "GB": "en", "US": "en", "FR": "fr", "ES": "es", "DE": "de", "PT": "pt", "BR": "pt",
        "RU": "ru", "JP": "ja", "KR": "ko", "IN": "hi", "CN": "zh"
    ]

    static func detectLanguages(text: String, tokens: Set<String>) -> [String] {
        var result: [String] = []
        for (token, code) in languageTokens where tokens.contains(token) {
            if !result.contains(code) { result.append(code) }
        }
        // Flag emoji = two regional indicator scalars.
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index + 1 < scalars.count {
            let a = scalars[index].value
            let b = scalars[index + 1].value
            if (0x1F1E6...0x1F1FF).contains(a) && (0x1F1E6...0x1F1FF).contains(b) {
                let code = String(UnicodeScalar(UInt8(a - 0x1F1E6 + 65))) + String(UnicodeScalar(UInt8(b - 0x1F1E6 + 65)))
                if let language = flagLanguages[code], !result.contains(language) { result.append(language) }
                index += 2
            } else {
                index += 1
            }
        }
        return result.sorted()
    }

    static func detectSize(text: String) -> Int64? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+(?:[.,]\\d+)?)\\s?(gb|gib|mb|mib)\\b", options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let number = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) ?? 0
        let unit = text[unitRange].lowercased()
        let multiplier: Double = unit.hasPrefix("g") ? 1_073_741_824 : 1_048_576
        let bytes = number * multiplier
        return bytes > 0 && bytes < 1e13 ? Int64(bytes) : nil
    }

    static func filenameExtension(_ filename: String?) -> String {
        guard let filename = filename, let dot = filename.lastIndex(of: ".") else { return "" }
        let ext = filename[filename.index(after: dot)...].lowercased()
        return ext.count <= 5 ? String(ext) : ""
    }

    static func isLocalStreamingServer(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host == "127.0.0.1" || host == "localhost" || host == "::1") && url.port == 11470
    }
}

/// Maps a stream to the URL actually handed to a player.
public enum StreamResolver {
    /// Direct http(s) URL for the stream, or a streaming-server URL for torrents when a server is configured
    /// (`{server}/{infoHash}/{fileIdx|-1}?tr=…`, same shape as stremio-core).
    public static func playbackURL(for stream: AddonStream, streamingServer: URL?) -> URL? {
        switch stream.source {
        case .url(let raw):
            guard let url = URL.lenient(raw), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        case .torrent(let hash, let index, let trackers):
            guard let server = streamingServer, isValidInfoHash(hash) else { return nil }
            guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
            var basePath = components.percentEncodedPath
            if basePath.hasSuffix("/") { basePath.removeLast() }
            components.percentEncodedPath = "\(basePath)/\(hash.lowercased())/\(index ?? -1)"
            if !trackers.isEmpty {
                components.queryItems = trackers.map { URLQueryItem(name: "tr", value: $0) }
            }
            return components.url
        default:
            return nil
        }
    }

    public static func isValidInfoHash(_ hash: String) -> Bool {
        guard hash.count == 40 else { return false }
        return hash.allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}
