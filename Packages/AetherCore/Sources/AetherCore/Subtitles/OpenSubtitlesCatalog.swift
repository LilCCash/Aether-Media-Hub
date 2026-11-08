import Foundation
#if canImport(Compression)
import Compression
#endif

/// The full OpenSubtitles.org catalogue, asked directly (its public REST interface, no account needed). The OpenSubtitles v3 addon
/// answers with a small selection of the catalogue: for many titles it has no Italian subtitle at all while the site has dozens.
/// This asks the catalogue for the viewer's languages only, and its answers are added to the addons' ones.
public enum OpenSubtitlesCatalog {
    public static let name = "OpenSubtitles.org"
    /// The catalogue's documented agent for clients without a registered one.
    public static let userAgent = "TemporaryUserAgent"
    static let base = "https://rest.opensubtitles.org/search"
    /// Formats the app's parser reads.
    static let formats: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "smi", "txt"]

    /// The catalogue's language code (ISO 639-2/B and its own inventions) for a language of the app ("it", "ita", "Italiano"…).
    public static func catalogLanguage(_ raw: String) -> String? {
        let code = LanguageCodes.normalise(raw)
        if code.isEmpty || code == "und" { return nil }
        let special: [String: String] = [
            "pt-BR": "pob", "pt-PT": "por", "zh-Hant": "zht", "zh-Hans": "chi", "es-419": "spl",
        ]
        if let mapped = special[code] { return mapped }
        let base = LanguageCodes.baseLanguage(code)
        let table: [String: String] = [
            "it": "ita", "en": "eng", "fr": "fre", "de": "ger", "es": "spa", "pt": "por", "nl": "dut", "ru": "rus", "ja": "jpn",
            "ko": "kor", "zh": "chi", "ar": "ara", "pl": "pol", "tr": "tur", "sv": "swe", "no": "nor", "da": "dan", "fi": "fin",
            "el": "ell", "he": "heb", "hu": "hun", "ro": "rum", "cs": "cze", "sk": "slo", "sl": "slv", "hr": "hrv", "sr": "scc",
            "bg": "bul", "uk": "ukr", "fa": "per", "hi": "hin", "id": "ind", "ms": "may", "th": "tha", "vi": "vie", "ca": "cat",
            "et": "est", "lv": "lav", "lt": "lit", "sq": "alb", "mk": "mac", "bs": "bos", "is": "ice", "ga": "gle", "eu": "baq",
            "gl": "glg", "bn": "ben", "ta": "tam", "te": "tel", "ur": "urd", "ka": "geo", "hy": "arm", "az": "aze", "kk": "kaz",
        ]
        if let mapped = table[base] { return mapped }
        return base.count == 3 ? base : nil
    }

    /// The search for one language. `videoID` is the addons' id: `tt0111161` for a film, `tt0944947:1:3` for an episode. The
    /// catalogue wants its parameters in alphabetical order.
    public static func searchURL(videoID: String, language: String) -> URL? {
        let parts = videoID.split(separator: ":").map(String.init)
        guard let first = parts.first, first.hasPrefix("tt"), first.count > 2 else { return nil }
        let digits = String(first.dropFirst(2))
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var segments: [String] = []
        if parts.count >= 3, let season = Int(parts[1]), let episode = Int(parts[2]) {
            segments.append("episode-\(episode)")
            segments.append("imdbid-\(digits)")
            segments.append("season-\(season)")
        } else {
            segments.append("imdbid-\(digits)")
        }
        segments.append("sublanguageid-\(language)")
        return URL(string: base + "/" + segments.joined(separator: "/"))
    }

    /// The headers every request to the catalogue needs.
    public static var headers: [String: String] {
        return ["User-Agent": userAgent, "X-User-Agent": userAgent, "Accept": "application/json"]
    }

    /// The subtitles of an answer, most downloaded first, one per file, at most `limit`.
    public static func parse(_ data: Data, limit: Int = 25) -> [AddonSubtitle] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        struct Found { var subtitle: AddonSubtitle; var downloads: Int }
        var found: [Found] = []
        var seen = Set<String>()
        for item in list {
            func text(_ key: String) -> String? {
                if let value = item[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
                if let value = item[key] as? NSNumber { return value.stringValue }
                return nil
            }
            guard let link = text("SubDownloadLink"), link.hasPrefix("https://"), let language = text("SubLanguageID"), !language.isEmpty else { continue }
            let format = (text("SubFormat") ?? "srt").lowercased()
            guard formats.contains(format) else { continue }
            let fileID = text("IDSubtitleFile") ?? link
            guard seen.insert(fileID).inserted else { continue }
            var label = text("MovieReleaseName") ?? text("SubFileName") ?? name
            if label.isEmpty { label = name }
            if text("SubHearingImpaired") == "1" { label += " · non udenti" }
            let subtitle = AddonSubtitle(id: "osorg-" + fileID, url: link, lang: language, label: label, addonName: name)
            found.append(Found(subtitle: subtitle, downloads: Int(text("SubDownloadsCnt") ?? "") ?? 0))
        }
        found.sort { $0.downloads > $1.downloads }
        return found.prefix(max(0, limit)).map { $0.subtitle }
    }
}

/// A file compressed with gzip (the catalogue hands its subtitles out as `.gz`).
public enum GzipData {
    public static func isGzip(_ data: Data) -> Bool {
        return data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// The contents, or nil when the data is not gzip or cannot be read. `limit` caps what is accepted (a subtitle is small).
    public static func decompress(_ data: Data, limit: Int = 16 << 20) -> Data? {
        guard isGzip(data) else { return nil }
        let bytes = [UInt8](data)
        guard bytes[2] == 8 else { return nil }   // deflate
        let flags = bytes[3]
        var position = 10
        if flags & 0x04 != 0 {
            guard position + 2 <= bytes.count else { return nil }
            position += 2 + (Int(bytes[position]) | Int(bytes[position + 1]) << 8)
        }
        if flags & 0x08 != 0 { while position < bytes.count && bytes[position] != 0 { position += 1 }; position += 1 }
        if flags & 0x10 != 0 { while position < bytes.count && bytes[position] != 0 { position += 1 }; position += 1 }
        if flags & 0x02 != 0 { position += 2 }
        guard position < bytes.count - 8 else { return nil }
        let stated = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        let deflated = Array(bytes[position..<(bytes.count - 8)])
        #if canImport(Compression)
        let capacity = min(limit, max(stated, deflated.count * 4, 1024))
        var output = [UInt8](repeating: 0, count: capacity)
        let written = output.withUnsafeMutableBufferPointer { target -> Int in
            deflated.withUnsafeBufferPointer { source -> Int in
                guard let targetBase = target.baseAddress, let sourceBase = source.baseAddress else { return 0 }
                return compression_decode_buffer(targetBase, capacity, sourceBase, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return Data(output.prefix(written))
        #else
        _ = stated
        return nil
        #endif
    }
}
