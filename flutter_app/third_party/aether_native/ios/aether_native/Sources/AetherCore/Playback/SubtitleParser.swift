import Foundation

public struct SubtitleCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SubtitleFormat: String, Sendable {
    case srt, webVTT, ass, unknown
}

public enum SubtitleError: Error, Equatable, Sendable {
    case empty
    case unsupportedFormat
    case noCues

    public var message: String {
        switch self {
        case .empty: return "Il file dei sottotitoli è vuoto."
        case .unsupportedFormat: return "Formato di sottotitoli non riconosciuto (supportati: SRT, WebVTT, ASS/SSA)."
        case .noCues: return "Nessuna riga di sottotitolo trovata nel file."
        }
    }
}

/// Parses SRT, WebVTT and ASS/SSA into plain cues rendered by the app's own overlay. AVPlayer cannot style
/// or even load external SRT, and the overlay gives full control over colour/size/outline/background/position/offset.
public enum SubtitleParser {
    // MARK: Entry points

    /// `encodingHint` is the charset an addon announced (`?senc=cp1250` in the subtitle URL, see `SubtitleCatalog.encodingHint(forURL:)`).
    public static func parse(_ data: Data, languageHint: String? = nil, encodingHint: String? = nil) throws -> [SubtitleCue] {
        guard !data.isEmpty else { throw SubtitleError.empty }
        let text = decode(data, languageHint: languageHint, encodingHint: encodingHint)
        return try parse(text: text)
    }

    public static func parse(text rawText: String) throws -> [SubtitleCue] {
        var text = rawText
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SubtitleError.empty }
        let cues: [SubtitleCue]
        switch detectFormat(text) {
        case .webVTT: cues = parseVTT(text)
        case .srt: cues = parseSRT(text)
        case .ass: cues = parseASS(text)
        case .unknown: throw SubtitleError.unsupportedFormat
        }
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return cues.sorted { $0.start < $1.start }
    }

    public static func detectFormat(_ text: String) -> SubtitleFormat {
        let head = text.prefix(2048)
        if head.contains("WEBVTT") && head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") {
            return .webVTT
        }
        if head.contains("[Script Info]") || head.contains("[Events]") || head.contains("Dialogue:") { return .ass }
        if text.contains("-->") { return .srt }
        return .unknown
    }

    // MARK: Encoding

    /// BOMs first, then strict UTF-8, then the charset the addon announced (`encodingHint`), then legacy code pages
    /// guessed from the language hint. A hint never overrides valid UTF-8: addons that re-encode (the official OpenSubtitles
    /// one) keep announcing the original charset.
    public static func decode(_ data: Data, languageHint: String?, encodingHint: String? = nil) -> String {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE, let text = String(data: data, encoding: .utf16LittleEndian) { return text }
            if data[0] == 0xFE && data[1] == 0xFF, let text = String(data: data, encoding: .utf16BigEndian) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        let language = languageHint.map { LanguageCodes.baseLanguage($0) } ?? ""
        var candidates: [String.Encoding] = []
        if let hint = encodingHint, let announced = encoding(forCharset: hint) {
            candidates.append(announced)
        }
        var guessed: [String.Encoding] = []
        switch language {
        case "ru", "uk", "bg", "sr": guessed = [.windowsCP1251, .isoLatin1]
        case "pl", "cs", "sk", "hu", "ro", "hr", "sl": guessed = [.windowsCP1250, .isoLatin2, .isoLatin1]
        case "el": guessed = [.windowsCP1253, .isoLatin1]
        case "tr": guessed = [.windowsCP1254, .isoLatin1]
        default: guessed = [.windowsCP1252, .isoLatin1]
        }
        candidates.append(contentsOf: guessed)
        for candidate in candidates {
            if let text = String(data: data, encoding: candidate) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Charset names found in `?senc=` and `Content-Type` parameters (case-insensitive, `-`/`_` interchangeable) mapped to
    /// the encodings Foundation supports on every platform. Unknown names return nil and the heuristics apply.
    static func encoding(forCharset charset: String) -> String.Encoding? {
        let key = charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        switch key {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16": return .utf16
        case "utf-16le", "utf16le": return .utf16LittleEndian
        case "utf-16be", "utf16be": return .utf16BigEndian
        case "ascii", "us-ascii": return .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1": return .isoLatin1
        case "iso-8859-2", "iso8859-2", "latin2", "latin-2", "l2": return .isoLatin2
        case "cp1250", "windows-1250", "win-1250", "x-cp1250": return .windowsCP1250
        case "cp1251", "windows-1251", "win-1251", "x-cp1251": return .windowsCP1251
        case "cp1252", "windows-1252", "win-1252", "x-cp1252": return .windowsCP1252
        case "cp1253", "windows-1253", "win-1253", "x-cp1253": return .windowsCP1253
        case "cp1254", "windows-1254", "win-1254", "x-cp1254": return .windowsCP1254
        case "macroman", "mac-roman", "macintosh": return .macOSRoman
        case "shift-jis", "shiftjis", "sjis", "x-sjis": return .shiftJIS
        case "euc-jp", "eucjp": return .japaneseEUC
        default: return nil
        }
    }

    // MARK: Timestamps

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm`
    static func parseTimestamp(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0.0
        for part in parts.dropLast() {
            guard let number = Double(part) else { return nil }
            seconds = seconds * 60 + number
        }
        guard let last = parts.last, let tail = Double(last) else { return nil }
        return seconds * 60 + tail
    }

    private static func parseTimeRange(_ line: String) -> (Double, Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = String(line[line.startIndex..<arrow.lowerBound])
        let rightRaw = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        // Drop WebVTT cue settings ("align:start position:10%").
        let right: String
        if let space = rightRaw.firstIndex(of: " ") {
            right = String(rightRaw[rightRaw.startIndex..<space])
        } else {
            right = rightRaw
        }
        guard let start = parseTimestamp(left), let end = parseTimestamp(right) else { return nil }
        return (start, end)
    }

    // MARK: SRT / VTT

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        return parseBlocks(text, skipHeader: false)
    }

    static func parseVTT(_ text: String) -> [SubtitleCue] {
        return parseBlocks(text, skipHeader: true)
    }

    private static func parseBlocks(_ text: String, skipHeader: Bool) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            if skipHeader, let first = lines.first, first.hasPrefix("NOTE") || first.hasPrefix("STYLE") || first.hasPrefix("REGION") {
                continue
            }
            guard let (start, end) = parseTimeRange(lines[timingIndex]) else { continue }
            let body = lines[(timingIndex + 1)...].joined(separator: "\n")
            let cleaned = cleanMarkup(body)
            if cleaned.isEmpty || end < start { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues
    }

    // MARK: ASS / SSA

    static func parseASS(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var inEvents = false
        var format: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst("format:".count).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
            } else if line.lowercased().hasPrefix("dialogue:") {
                let payload = String(line.dropFirst("dialogue:".count))
                let fieldCount = max(format.count, 10)
                // The text field is last and may contain commas.
                let fields = payload.split(separator: ",", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
                    .map { String($0) }
                guard fields.count >= fieldCount else { continue }
                let startIndex = format.firstIndex(of: "start") ?? 1
                let endIndex = format.firstIndex(of: "end") ?? 2
                let textIndex = format.firstIndex(of: "text") ?? (fieldCount - 1)
                guard startIndex < fields.count, endIndex < fields.count, textIndex < fields.count,
                      let start = parseTimestamp(fields[startIndex]), let end = parseTimestamp(fields[endIndex]) else {
                    continue
                }
                var body = fields[textIndex]
                body = body.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                body = body.replacingOccurrences(of: "\\h", with: " ")
                body = stripASSOverrides(body)
                let cleaned = cleanMarkup(body)
                if !cleaned.isEmpty && end >= start {
                    cues.append(SubtitleCue(start: start, end: end, text: cleaned))
                }
            }
        }
        return cues
    }

    private static func stripASSOverrides(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "{" { depth += 1; continue }
            if character == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    // MARK: Markup cleanup

    /// Removes `<i>`, `<b>`, `<font …>`, VTT voice/timestamp tags; decodes the basic entities; trims blank lines.
    static func cleanMarkup(_ raw: String) -> String {
        var output = ""
        var inTag = false
        for character in raw {
            if character == "<" { inTag = true; continue }
            if character == ">" && inTag { inTag = false; continue }
            if !inTag { output.append(character) }
        }
        // A lone "<" without ">" would have swallowed text; recover by using the raw string in that case.
        if inTag { output = raw.replacingOccurrences(of: "<", with: "") }
        let entities: [(String, String)] = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                            ("&apos;", "'"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", "")]
        for (entity, replacement) in entities {
            output = output.replacingOccurrences(of: entity, with: replacement)
        }
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

/// Fast lookup of the cue(s) active at a playback time, with a user-adjustable delay.
public struct SubtitleTimeline: Sendable {
    public private(set) var cues: [SubtitleCue]

    public init(cues: [SubtitleCue]) {
        self.cues = cues.sorted { $0.start < $1.start }
    }

    /// Cues displayed at `time` once shifted by `delay` seconds (positive delay = subtitles appear later).
    public func active(at time: Double, delay: Double = 0) -> [SubtitleCue] {
        let t = time - delay
        // Binary search for the last cue starting at or before t, then scan back a little for overlaps.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= t { low = mid + 1 } else { high = mid }
        }
        var result: [SubtitleCue] = []
        var index = low - 1
        var scanned = 0
        while index >= 0 && scanned < 6 {
            let cue = cues[index]
            if cue.start <= t && t < cue.end { result.insert(cue, at: 0) }
            index -= 1
            scanned += 1
        }
        return result
    }
}
