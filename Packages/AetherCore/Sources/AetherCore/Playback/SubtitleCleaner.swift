import Foundation

/// Removes hearing-impaired (SDH) annotations from subtitle text: "[door slams]", "(SIGHS)", "♪ music ♪", "JOHN:".
/// Conservative on purpose: ordinary parenthesised dialogue in the middle of a sentence is left alone.
public enum SubtitleCleaner {
    /// Cleans the text of one cue. Returns an empty string when nothing but annotations was there.
    public static func stripHearingImpaired(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let cleaned = cleanLine(rawLine)
            if !cleaned.isEmpty { lines.append(cleaned) }
        }
        return lines.joined(separator: "\n")
    }

    static func cleanLine(_ raw: String) -> String {
        var line = raw
        // Square and curly brackets are only ever used for annotations.
        line = removing(pattern: "\\[[^\\]]*\\]", from: line)
        line = removing(pattern: "\\{[^}]*\\}", from: line)
        // Parentheses: annotations when they open or close the line, or when written in capitals.
        line = removing(pattern: "^\\s*[-–]?\\s*\\([^)]*\\)\\s*", from: line)
        line = removing(pattern: "\\s*\\([^)]*\\)\\s*$", from: line)
        line = removing(pattern: "\\(([^a-z)]*[A-Z][^a-z)]*)\\)", from: line)
        // Music symbols.
        line = line.replacingOccurrences(of: "♪", with: "").replacingOccurrences(of: "♫", with: "")
        // "SPEAKER NAME:" labels written in capitals.
        line = removing(pattern: "^\\s*[-–]?\\s*[A-Z][A-Z0-9 .'’-]{0,24}:\\s+", from: line)
        line = line.trimmingCharacters(in: .whitespaces)
        // A dash left behind by a removed annotation ("- [sighs]") is not text.
        if line == "-" || line == "–" || line == "#" { return "" }
        return line
    }

    private static func removing(pattern: String, from text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
