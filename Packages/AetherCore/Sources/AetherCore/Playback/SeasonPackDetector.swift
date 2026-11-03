import Foundation

/// Does the name of a source say that it holds a whole season (or a whole series) instead of one episode? Pure; reads names only.
public enum SeasonPackKind: Equatable, Sendable {
    case season, series

    public var label: String { return self == .season ? "Stagione completa" : "Serie completa" }
}

public enum SeasonPackDetector {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Literal patterns: a failure is a programming error caught by the unit tests.
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let singleEpisode = regex("(?<![A-Za-z0-9])S\\d{1,2}[ ._-]?E\\d{1,3}(?![0-9])|(?<![A-Za-z0-9])\\d{1,2}x\\d{2,3}(?![A-Za-z0-9])")
    private static let episodeRange = regex("E\\d{1,3}[ ._]?(?:-|–|to|a)[ ._]?E?\\d{1,3}(?![0-9])")
    private static let seasonRange = regex("(?<![A-Za-z0-9])S\\d{1,2}[ ._]?(?:-|–|to|a)[ ._]?S?\\d{1,2}(?![0-9A-Za-z])")
    private static let seasonOnly = regex("(?<![A-Za-z0-9])S\\d{1,2}(?![0-9A-Za-z])|(?<![A-Za-z0-9])(?:season|stagione|saison|staffel)[ ._-]?\\d{1,2}(?![0-9])")
    private static let seasonWords = regex("complete[ ._-]season|season[ ._-]complete|full[ ._-]season|season[ ._-]pack|stagione[ ._-](?:completa|intera)|intera[ ._-]stagione|integrale|saison[ ._-]compl[eè]te")
    private static let seriesWords = regex("complete[ ._-]series|series[ ._-]complete|all[ ._-]seasons|serie[ ._-]completa|intera[ ._-]serie|tutte[ ._-]le[ ._-]stagioni|the[ ._-]complete[ ._-](?:collection|series)")

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func kind(of text: String) -> SeasonPackKind? {
        let name = text.replacingOccurrences(of: "\n", with: " ")
        if matches(seriesWords, name) || matches(seasonRange, name) { return .series }
        if matches(seasonWords, name) { return .season }
        if matches(singleEpisode, name) { return matches(episodeRange, name) ? .season : nil }
        if matches(seasonOnly, name) { return .season }
        return nil
    }

    public static func kind(of stream: AddonStream) -> SeasonPackKind? {
        let text = [stream.behaviorHints.filename, stream.name, stream.details].compactMap { $0 }.joined(separator: " ")
        return kind(of: text)
    }
}
