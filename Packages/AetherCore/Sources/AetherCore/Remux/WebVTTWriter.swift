import Foundation

/// Turns the subtitle events of a file (SRT, ASS, WebVTT… as FFmpeg hands them) into WebVTT pieces for HLS.
public enum WebVTTWriter {
    public struct Cue: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// The text of one event: the codec says how it is written. ASS events carry nine fields before the text; their override tags
    /// (`{\i1}`) and line breaks (`\N`) are turned into plain text. HTML-like tags of SRT are kept only for italics and bold, which WebVTT
    /// understands.
    public static func text(of payload: String, codec: String) -> String {
        var body = payload
        let lowered = codec.lowercased()
        if lowered == "ass" || lowered == "ssa" {
            // "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text" (Matroska), or a full "Dialogue:" line.
            if body.hasPrefix("Dialogue:") { body = String(body.dropFirst("Dialogue:".count)) }
            let fields = body.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if fields.count == 9 { body = String(fields[8]) }
            body = stripOverrides(body)
            body = body.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        }
        return clean(body)
    }

    /// Keeps `<i>`, `<b>`, `<u>`; drops every other tag; escapes what WebVTT would read as markup.
    static func clean(_ raw: String) -> String {
        var output = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "<", let close = raw[index...].firstIndex(of: ">") {
                let tag = raw[raw.index(after: index)..<close].lowercased().trimmingCharacters(in: .whitespaces)
                if ["i", "/i", "b", "/b", "u", "/u"].contains(tag) { output += "<\(tag)>" }
                index = raw.index(after: close)
                continue
            }
            switch character {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            default: output.append(character)
            }
            index = raw.index(after: index)
        }
        output = output.replacingOccurrences(of: "&amp;nbsp;", with: " ").replacingOccurrences(of: "-->", with: "→")
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static func stripOverrides(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "{" { depth += 1; continue }
            if character == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    /// One piece: the header, then the cues in order. The times are those of the video's timeline (the same the MP4 pieces carry), so
    /// the piece maps local time 0 to media time 0.
    public static func document(_ cues: [Cue]) -> String {
        var lines = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000", ""]
        for cue in cues.sorted(by: { $0.start < $1.start }) where !cue.text.isEmpty && cue.end > cue.start {
            lines.append("\(timestamp(cue.start)) --> \(timestamp(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        let hours = millis / 3_600_000
        let minutes = (millis / 60_000) % 60
        let secs = (millis / 1000) % 60
        let ms = millis % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, ms)
    }
}
