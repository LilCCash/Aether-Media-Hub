import Foundation

// Turns the raw `[AddonSubtitle]` of every addon into what the player menu needs: de-duplicated, labelled and ordered
// candidates, grouped by language. Pure functions, no I/O.

/// One selectable external subtitle.
public struct SubtitleCandidate: Hashable, Identifiable, Sendable {
    /// The addon's entry, with the URL trimmed.
    public var subtitle: AddonSubtitle
    /// Stable language code (`LanguageCodes.normalise`), `und` when the addon sent none.
    public var language: String
    /// Italian language name; the addon's own text when the language is not recognised.
    public var languageName: String
    public var addonName: String?
    /// Heuristic from the label (SDH, CC, "non udenti"...). Addons almost never send a real flag.
    public var isHearingImpaired: Bool
    /// Heuristic from the label ("forced", "forzati"...): only foreign-language parts, not a full translation.
    public var isForced: Bool
    /// Charset announced in the URL (`?senc=cp1250`), to pass to `SubtitleParser.parse(_:languageHint:encodingHint:)`.
    public var encodingHint: String?

    public init(subtitle: AddonSubtitle, language: String, languageName: String, addonName: String? = nil,
                isHearingImpaired: Bool = false, isForced: Bool = false, encodingHint: String? = nil) {
        self.subtitle = subtitle
        self.language = language
        self.languageName = languageName
        self.addonName = addonName
        self.isHearingImpaired = isHearingImpaired
        self.isForced = isForced
        self.encodingHint = encodingHint
    }

    /// The subtitle URL: candidates are unique per URL.
    public var id: String { return subtitle.url }
    public var url: String { return subtitle.url }

    private var trimmedLabel: String? {
        guard let label = subtitle.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        return label
    }

    /// Row title: the addon's label, otherwise the language name.
    public var title: String {
        return trimmedLabel ?? languageName
    }

    /// Row subtitle: language (when the title is a label), kind and addon, e.g. "Inglese · Non udenti · OpenSubtitles v3".
    public var detail: String {
        var parts: [String] = []
        if trimmedLabel != nil { parts.append(languageName) }
        if isHearingImpaired { parts.append("Non udenti") }
        if isForced { parts.append("Forzati") }
        if let addon = addonName, !addon.isEmpty { parts.append(addon) }
        return parts.joined(separator: " · ")
    }
}

/// The user's ordered language preferences for subtitles.
public struct SubtitlePreferences: Hashable, Sendable {
    /// Most wanted first. Any spelling `LanguageCodes` understands (`it`, `ita`, `pt-BR`, `Italian`).
    public var languages: [String]
    /// Rank subtitles for the deaf and hard of hearing before the plain ones (inside the same language).
    public var preferHearingImpaired: Bool

    public init(languages: [String] = [], preferHearingImpaired: Bool = false) {
        self.languages = languages
        self.preferHearingImpaired = preferHearingImpaired
    }
}

/// All the candidates of one language, in ranked order.
public struct SubtitleLanguageGroup: Hashable, Identifiable, Sendable {
    public var language: String
    public var name: String
    public var candidates: [SubtitleCandidate]

    public var id: String { return language }

    public init(language: String, name: String, candidates: [SubtitleCandidate]) {
        self.language = language
        self.name = name
        self.candidates = candidates
    }
}

public enum SubtitleCatalog {
    // MARK: Building

    /// De-duplicates by URL (first occurrence wins, gaps in its label and addon name are filled from later duplicates),
    /// normalises the language, derives the flags and orders the result:
    ///  1. languages in the user's order (an exact match of the stable code before a looser one, e.g. `pt` for a `pt-BR` wish);
    ///     languages the user did not ask for follow, alphabetically by name;
    ///  2. inside a language: plain subtitles, then hearing-impaired ones (the other way round with `preferHearingImpaired`),
    ///     then forced ones;
    ///  3. subtitles with a label before those without, then the input order (addon order, then each addon's own order).
    /// Entries without a URL are dropped.
    public static func candidates(from subtitles: [AddonSubtitle],
                                  preferences: SubtitlePreferences = SubtitlePreferences()) -> [SubtitleCandidate] {
        var built: [SubtitleCandidate] = []
        var positions: [String: Int] = [:]
        for subtitle in subtitles {
            let url = subtitle.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { continue }
            if let existing = positions[url] {
                fillGaps(of: &built[existing], from: subtitle)
                continue
            }
            var entry = subtitle
            entry.url = url
            built.append(makeCandidate(entry))
            positions[url] = built.count - 1
        }
        let ranked = rank(built, preferences: preferences)
        return ranked.map { $0.candidate }
    }

    /// Candidates grouped by language, groups and members in the given order (first appearance).
    public static func groups(from candidates: [SubtitleCandidate]) -> [SubtitleLanguageGroup] {
        var order: [String] = []
        var buckets: [String: [SubtitleCandidate]] = [:]
        for candidate in candidates {
            if buckets[candidate.language] == nil {
                order.append(candidate.language)
                buckets[candidate.language] = []
            }
            buckets[candidate.language]?.append(candidate)
        }
        var result: [SubtitleLanguageGroup] = []
        for code in order {
            let members = buckets[code] ?? []
            let name: String
            if LanguageCodes.resolve(code) != nil {
                name = LanguageCodes.displayName(code)
            } else {
                name = members.first?.languageName ?? code
            }
            result.append(SubtitleLanguageGroup(language: code, name: name, candidates: members))
        }
        return result
    }

    /// Stable codes of the languages present, in the order of the given candidates.
    public static func availableLanguages(in candidates: [SubtitleCandidate]) -> [String] {
        return groups(from: candidates).map { $0.language }
    }

    /// The subtitle to switch on automatically: the best candidate in one of the preferred languages. Forced-only tracks are
    /// never chosen (they translate only foreign dialogue), and nothing is chosen when no preferred language is available.
    public static func preferred(in candidates: [SubtitleCandidate], preferences: SubtitlePreferences) -> SubtitleCandidate? {
        if preferences.languages.isEmpty { return nil }
        let limit = preferences.languages.count * 2
        let ranked = rank(candidates, preferences: preferences)
        for entry in ranked {
            if entry.key.tier >= limit { continue }
            if entry.candidate.isForced { continue }
            return entry.candidate
        }
        return nil
    }

    // MARK: Encoding hint

    /// Value of the `senc` query parameter (`…/file/123?senc=cp1250`), or nil. Some addons serve legacy charsets and announce
    /// them this way; the official OpenSubtitles addon re-encodes to UTF-8 and does not need it.
    public static func encodingHint(forURL urlString: String) -> String? {
        guard let questionMark = urlString.firstIndex(of: "?") else { return nil }
        var query = String(urlString[urlString.index(after: questionMark)...])
        if let fragment = query.firstIndex(of: "#") { query = String(query[query.startIndex..<fragment]) }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count != 2 { continue }
            if parts[0].lowercased() != "senc" { continue }
            let value = URIComponent.decode(String(parts[1])).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Construction

    private static func makeCandidate(_ subtitle: AddonSubtitle) -> SubtitleCandidate {
        let normalised = LanguageCodes.normalise(subtitle.lang)
        let language = normalised.isEmpty ? "und" : normalised
        let marks = SubtitleCatalog.flags(label: subtitle.label, language: language)
        return SubtitleCandidate(subtitle: subtitle,
                                 language: language,
                                 languageName: LanguageCodes.displayName(subtitle.lang),
                                 addonName: subtitle.addonName,
                                 isHearingImpaired: marks.hearingImpaired,
                                 isForced: marks.forced,
                                 encodingHint: encodingHint(forURL: subtitle.url))
    }

    private static func fillGaps(of candidate: inout SubtitleCandidate, from duplicate: AddonSubtitle) {
        let currentLabel = candidate.subtitle.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let otherLabel = duplicate.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentLabel.isEmpty && !otherLabel.isEmpty {
            candidate.subtitle.label = otherLabel
            let marks = SubtitleCatalog.flags(label: otherLabel, language: candidate.language)
            candidate.isHearingImpaired = marks.hearingImpaired
            candidate.isForced = marks.forced
        }
        if (candidate.addonName ?? "").isEmpty, let name = duplicate.addonName, !name.isEmpty {
            candidate.addonName = name
            candidate.subtitle.addonName = name
        }
    }

    // MARK: Ranking

    private struct RankKey {
        var tier: Int
        var groupName: String
        var language: String
        var kind: Int
        var label: Int
        var position: Int
    }

    private struct RankedCandidate {
        var key: RankKey
        var candidate: SubtitleCandidate
    }

    private static func rank(_ candidates: [SubtitleCandidate], preferences: SubtitlePreferences) -> [RankedCandidate] {
        var entries: [RankedCandidate] = []
        for (position, candidate) in candidates.enumerated() {
            let key = RankKey(tier: languageTier(candidate.language, preferences: preferences.languages),
                              groupName: LanguageCodes.displayName(candidate.language).lowercased(),
                              language: candidate.language,
                              kind: kindTier(candidate, preferHearingImpaired: preferences.preferHearingImpaired),
                              label: hasLabel(candidate) ? 0 : 1,
                              position: position)
            entries.append(RankedCandidate(key: key, candidate: candidate))
        }
        return entries.sorted { (lhs: RankedCandidate, rhs: RankedCandidate) -> Bool in
            return isOrdered(lhs.key, before: rhs.key)
        }
    }

    private static func isOrdered(_ lhs: RankKey, before rhs: RankKey) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.groupName != rhs.groupName { return lhs.groupName < rhs.groupName }
        if lhs.language != rhs.language { return lhs.language < rhs.language }
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.label != rhs.label { return lhs.label < rhs.label }
        return lhs.position < rhs.position
    }

    /// 0, 2, 4... for an exact match of the n-th wish, 1, 3, 5... for a looser one; `2 * count` when nothing matches.
    private static func languageTier(_ language: String, preferences: [String]) -> Int {
        var best = preferences.count * 2
        for (index, wish) in preferences.enumerated() {
            let strength = LanguageCodes.matchStrength(language, wish)
            if strength == 0 { continue }
            let tier = index * 2 + (strength >= 2 ? 0 : 1)
            if tier < best { best = tier }
        }
        return best
    }

    private static func kindTier(_ candidate: SubtitleCandidate, preferHearingImpaired: Bool) -> Int {
        if candidate.isForced { return 2 }
        if candidate.isHearingImpaired { return preferHearingImpaired ? 0 : 1 }
        return preferHearingImpaired ? 1 : 0
    }

    private static func hasLabel(_ candidate: SubtitleCandidate) -> Bool {
        guard let label = candidate.subtitle.label else { return false }
        return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Label heuristics

    private static let hearingImpairedTokens: Set<String> = [
        "sdh", "cc", "hoh", "deaf", "captions", "caption",
        "udenti", "ipoudenti", "sordi", "sordos", "surdos", "sourds", "malentendants", "hipoacusicos",
        "hörgeschädigte", "hoergeschaedigte", "gehörlose"
    ]

    private static let forcedTokens: Set<String> = [
        "forced", "forzati", "forzato", "forzata", "forzate", "forzado", "forzados",
        "forcé", "forcés", "forcee", "forcees", "forçado", "forçados", "forcado", "forcados", "erzwungen", "fpo"
    ]

    /// Hearing-impaired / forced markers found in an addon label. Whole words only ("cc" must not match "accent").
    static func flags(label: String?, language: String) -> (hearingImpaired: Bool, forced: Bool) {
        guard let label = label else { return (false, false) }
        let lower = label.lowercased()
        let words: [String] = lower.split(whereSeparator: { (character: Character) -> Bool in
            return !character.isLetter && !character.isNumber
        }).map { String($0) }
        if words.isEmpty { return (false, false) }
        let wordSet = Set(words)

        var hearingImpaired = !wordSet.isDisjoint(with: hearingImpairedTokens)
        if !hearingImpaired && wordSet.contains("hearing") && wordSet.contains("impaired") { hearingImpaired = true }
        if !hearingImpaired && lower.contains("hard of hearing") { hearingImpaired = true }
        // "hi" is also the code of Hindi: only a marker next to other words, and never in a Hindi subtitle.
        if !hearingImpaired && wordSet.contains("hi") && words.count > 1 && LanguageCodes.baseLanguage(language) != "hi" {
            hearingImpaired = true
        }

        var forced = !wordSet.isDisjoint(with: forcedTokens)
        if !forced && (lower.contains("foreign parts") || lower.contains("foreign only") || lower.contains("foreign language only")) {
            forced = true
        }
        if !forced && wordSet.contains("signs") && wordSet.contains("songs") { forced = true }
        return (hearingImpaired, forced)
    }
}
