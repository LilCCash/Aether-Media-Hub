import Foundation

// 1.5: settings that let the viewer shape what the app shows: the names and order of the addons' catalogs, how the sources are
// written, which TMDB modules appear on a title page and which rating services are shown. Every type decodes leniently like
// `AppSettings`: a missing or malformed value means "the default", never a lost setting.

// MARK: - Catalogs

/// The viewer's own order and names for the catalogs of the installed addons (Home, Discover and Search use them). The keys are
/// `CatalogRef.id` values; catalogs that are not listed keep the addons' order and their own name.
public struct CatalogLayoutSettings: Codable, Equatable, Sendable {
    public var order: [String] = []
    public var titles: [String: String] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case order, titles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = c.stringList(.order)
        titles = (try? c.decodeIfPresent([String: String].self, forKey: .titles)) ?? [:]
    }

    public static let maxTitleLength = 40

    /// The name to show: the viewer's if they gave one, else `fallback`.
    public func title(forID id: String, fallback: String) -> String {
        guard let custom = titles[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty else { return fallback }
        return String(custom.prefix(CatalogLayoutSettings.maxTitleLength))
    }

    public func customTitle(forID id: String) -> String? {
        guard let custom = titles[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty else { return nil }
        return String(custom.prefix(CatalogLayoutSettings.maxTitleLength))
    }

    /// An empty or blank name removes the custom name.
    public mutating func setTitle(_ title: String?, forID id: String) {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty { titles[id] = nil } else { titles[id] = String(cleaned.prefix(CatalogLayoutSettings.maxTitleLength)) }
    }

    /// The items in the viewer's order; those the viewer never placed keep their relative order after the placed ones.
    public func sorted<T>(_ items: [T], id: (T) -> String) -> [T] {
        if order.isEmpty { return items }
        var position: [String: Int] = [:]
        for (index, key) in order.enumerated() where position[key] == nil { position[key] = index }
        let indexed = items.enumerated().map { (offset: $0.offset, item: $0.element, rank: position[id($0.element)] ?? Int.max) }
        let ordered = indexed.sorted { first, second in
            if first.rank != second.rank { return first.rank < second.rank }
            return first.offset < second.offset
        }
        return ordered.map { $0.item }
    }

    /// Moves `id` one place up (-1) or down (+1) among `ids` (the catalogs shown right now, in the order shown).
    public mutating func move(id: String, by delta: Int, among ids: [String]) {
        var current = sorted(ids, id: { $0 })
        guard let index = current.firstIndex(of: id) else { return }
        let target = index + delta
        guard target >= 0, target < current.count else { return }
        current.swapAt(index, target)
        let others = order.filter { !current.contains($0) }
        order = current + others
    }

    public func canMove(id: String, by delta: Int, among ids: [String]) -> Bool {
        let current = sorted(ids, id: { $0 })
        guard let index = current.firstIndex(of: id) else { return false }
        let target = index + delta
        return target >= 0 && target < current.count
    }
}

// MARK: - Streams

public enum StreamBadgeStyle: String, Codable, CaseIterable, Sendable {
    case filled, outline, plain

    public var title: String {
        switch self {
        case .filled: return "Pieni"
        case .outline: return "Con contorno"
        case .plain: return "Solo testo"
        }
    }
}

/// The kinds of information a source row can show as a badge.
public enum StreamBadgeKind: String, Codable, CaseIterable, Sendable {
    case quality, codec, hdr, audio, language, size, format

    public var title: String {
        switch self {
        case .quality: return "Risoluzione (4K, 1080p…)"
        case .codec: return "Codec video (HEVC, H.264…)"
        case .hdr: return "HDR e Dolby Vision"
        case .audio: return "Audio (Atmos, DTS, Dolby…)"
        case .language: return "Lingue"
        case .size: return "Dimensione del file"
        case .format: return "Formato del file (MKV, MP4…)"
        }
    }
}

/// How the sources are written in the picker.
public struct StreamDisplaySettings: Codable, Equatable, Sendable {
    /// The addon's own logo beside each source.
    public var showAddonLogo: Bool = false
    public var badgeStyle: StreamBadgeStyle = .filled
    /// `StreamBadgeKind` raw values the viewer switched off.
    public var hiddenBadges: [String] = []
    /// A line written with the viewer's own pattern ("{quality} · {codec} · {size}"); empty keeps the addon's own text.
    public var template: String = ""
    /// Badges the viewer imported from a link (see `CustomBadgePack`), and the link they came from.
    public var customBadges: [CustomBadgeRule] = []
    public var customBadgesURL: String = ""

    public init() {}

    /// Ready-made patterns offered in the settings.
    public static let presets: [(title: String, template: String)] = [
        ("Come l'addon", ""),
        ("Compatta", "{quality} · {codec} · {size}"),
        ("Completa", "{quality} · {codec} · {hdr} · {audio} · {language} · {size}"),
        ("Qualità e dimensione", "{quality} · {size}"),
    ]

    /// The words a pattern may contain, for the settings screen.
    public static let tokens = ["{quality}", "{codec}", "{hdr}", "{audio}", "{language}", "{size}", "{format}", "{addon}", "{name}", "{details}"]

    private enum CodingKeys: String, CodingKey { case showAddonLogo, badgeStyle, hiddenBadges, template, customBadges, customBadgesURL }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showAddonLogo = c.value(.showAddonLogo, default: false)
        badgeStyle = c.value(.badgeStyle, default: .filled)
        hiddenBadges = c.stringList(.hiddenBadges)
        let raw: String = c.value(.template, default: "")
        template = String(raw.prefix(200))
        customBadges = Array(c.lossyArray(CustomBadgeRule.self, forKey: .customBadges).prefix(CustomBadgePack.maxRules))
        customBadgesURL = String((c.value(.customBadgesURL, default: "") as String).prefix(500))
    }

    public func isShown(_ kind: StreamBadgeKind) -> Bool {
        return !hiddenBadges.contains(kind.rawValue)
    }

    public mutating func setShown(_ shown: Bool, _ kind: StreamBadgeKind) {
        hiddenBadges.removeAll(where: { $0 == kind.rawValue })
        if !shown { hiddenBadges.append(kind.rawValue) }
    }
}

public struct StreamBadge: Equatable, Sendable {
    public var kind: StreamBadgeKind
    public var text: String
}

/// Writes the information of a source the way the viewer asked. Pure.
public enum StreamFormatter {
    public static func badges(for info: StreamInfo, settings: StreamDisplaySettings) -> [StreamBadge] {
        var result: [StreamBadge] = []
        func add(_ kind: StreamBadgeKind, _ text: String?) {
            guard let text = text, !text.isEmpty, settings.isShown(kind) else { return }
            result.append(StreamBadge(kind: kind, text: text))
        }
        if info.quality != .unknown { add(.quality, info.quality.label) }
        add(.codec, info.codec?.label)
        for format in info.hdr { add(.hdr, "\(format.label) (nel nome)") }
        add(.audio, info.audio.first?.label)
        for language in info.languages { add(.language, LanguageCodes.displayName(language)) }
        add(.size, info.sizeLabel)
        add(.format, info.formatLabel)
        return result
    }

    /// The viewer's pattern filled with what is known about the source; words with nothing to say disappear together with
    /// their separator, so "{quality} · {hdr} · {size}" never shows "1080p ·  · 4 GB".
    public static func line(template: String, info: StreamInfo, stream: AddonStream) -> String {
        let values: [String: String] = [
            "quality": info.quality == .unknown ? "" : info.quality.label,
            "codec": info.codec?.label ?? "",
            "hdr": info.hdr.map { $0.label }.joined(separator: " "),
            "audio": info.audio.first?.label ?? "",
            "language": info.languages.map { LanguageCodes.displayName($0) }.joined(separator: ", "),
            "size": info.sizeLabel ?? "",
            "format": info.formatLabel ?? "",
            "addon": stream.addonName ?? "",
            "name": stream.name ?? "",
            "details": stream.details ?? "",
        ]
        var text = template
        for (key, value) in values { text = text.replacingOccurrences(of: "{\(key)}", with: value) }
        return tidy(text)
    }

    static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: "(\\s*[·•|/,;-]\\s*){2,}", with: " · ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ·•|/,;-"))
    }
}

// MARK: - TMDB modules

/// Which parts of the title page that come from TMDB are shown.
public struct TitleModulesSettings: Codable, Equatable, Sendable {
    public var cast: Bool = true
    public var trailers: Bool = true
    public var companies: Bool = true
    public var financials: Bool = true
    public var facts: Bool = true
    public var similar: Bool = true
    /// The saga a film belongs to ("Il Signore degli Anelli"), with its other films.
    public var collection: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case cast, trailers, companies, financials, facts, similar, collection }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cast = c.value(.cast, default: true)
        trailers = c.value(.trailers, default: true)
        companies = c.value(.companies, default: true)
        financials = c.value(.financials, default: true)
        facts = c.value(.facts, default: true)
        similar = c.value(.similar, default: true)
        collection = c.value(.collection, default: true)
    }
}

// MARK: - Ratings

/// The rating services MDBList can report.
public enum RatingSource: String, CaseIterable, Codable, Sendable {
    case imdb, tmdb, tomatoes, tomatoesaudience, metacritic, metacriticuser, trakt, letterboxd, rogerebert, myanimelist

    public var title: String {
        switch self {
        case .imdb: return "IMDb"
        case .tmdb: return "TMDB"
        case .tomatoes: return "Rotten Tomatoes (critica)"
        case .tomatoesaudience: return "Rotten Tomatoes (pubblico)"
        case .metacritic: return "Metacritic"
        case .metacriticuser: return "Metacritic (utenti)"
        case .trakt: return "Trakt"
        case .letterboxd: return "Letterboxd"
        case .rogerebert: return "Roger Ebert"
        case .myanimelist: return "MyAnimeList"
        }
    }

    /// Short name for the small badge.
    public var shortTitle: String {
        switch self {
        case .tomatoes: return "Rotten Tomatoes"
        case .tomatoesaudience: return "Pubblico RT"
        case .metacriticuser: return "Metacritic utenti"
        default: return title
        }
    }

    /// The id MDBList uses, or one of its older spellings, mapped to ours.
    static func canonical(_ raw: String) -> String {
        switch raw.lowercased() {
        case "rottentomatoes", "rotten_tomatoes", "tomatoes": return RatingSource.tomatoes.rawValue
        case "popcorn", "audience", "tomatoesaudience", "tomatoes_audience": return RatingSource.tomatoesaudience.rawValue
        case "metacritic": return RatingSource.metacritic.rawValue
        case "metacriticuser", "metacritic_user": return RatingSource.metacriticuser.rawValue
        case "myanimelist", "mal": return RatingSource.myanimelist.rawValue
        default: return raw.lowercased()
        }
    }
}

public struct RatingsSettings: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    /// `RatingSource` raw values to show, in this order.
    public var sources: [String] = [RatingSource.imdb.rawValue, RatingSource.tomatoes.rawValue, RatingSource.metacritic.rawValue, RatingSource.tmdb.rawValue]

    public init() {}

    private enum CodingKeys: String, CodingKey { case enabled, sources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        let stored = c.stringList(.sources)
        sources = stored.isEmpty && !(c.contains(.sources)) ? RatingsSettings().sources : stored
    }

    public func isShown(_ source: RatingSource) -> Bool { return sources.contains(source.rawValue) }

    public mutating func setShown(_ shown: Bool, _ source: RatingSource) {
        sources.removeAll(where: { $0 == source.rawValue })
        if shown { sources.append(source.rawValue) }
    }
}

// MARK: - Badges imported from a link

/// One imported badge: shown on every source whose text contains one of the words.
public struct CustomBadgeRule: Codable, Equatable, Sendable, Identifiable {
    public var label: String
    /// Words (case-insensitive); an entry starting with "re:" is a regular expression.
    public var match: [String]
    public var colorHex: String?

    public var id: String { return label + "|" + match.joined(separator: ",") }

    public init(label: String, match: [String], colorHex: String? = nil) {
        self.label = label
        self.match = match
        self.colorHex = colorHex
    }

    public func matches(_ text: String) -> Bool {
        for entry in match {
            if entry.hasPrefix("re:") {
                let pattern = String(entry.dropFirst(3))
                if !pattern.isEmpty, text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            } else if !entry.isEmpty, text.range(of: entry, options: .caseInsensitive) != nil {
                return true
            }
        }
        return false
    }
}

/// A badge pack as published at a link: `[{"label":"Remux","match":["remux"],"color":"#FF9500"}]`, or the same list inside
/// `{"badges":[…]}` (also `name`/`text` for the label, `keywords`/`pattern` for the words, `colour`/`hex` for the colour).
public enum CustomBadgePack {
    public static let maxRules = 60
    public static let maxBytes = 200_000

    public static func parse(_ data: Data) -> [CustomBadgeRule] {
        guard data.count <= maxBytes, let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var list: [Any] = []
        if let array = object as? [Any] {
            list = array
        } else if let dictionary = object as? [String: Any] {
            list = (dictionary["badges"] as? [Any]) ?? (dictionary["rules"] as? [Any]) ?? (dictionary["items"] as? [Any]) ?? []
        }
        var rules: [CustomBadgeRule] = []
        for entry in list {
            guard let item = entry as? [String: Any] else { continue }
            let label = [item["label"], item["name"], item["text"]].compactMap { $0 as? String }.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var words: [String] = []
            for key in ["match", "keywords", "pattern", "regex", "contains"] {
                if let one = item[key] as? String { words.append(key == "regex" || key == "pattern" ? "re:" + one : one) }
                if let many = item[key] as? [Any] { words.append(contentsOf: many.compactMap { $0 as? String }) }
            }
            words = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let color = [item["color"], item["colour"], item["hex"]].compactMap { $0 as? String }.first.flatMap { value -> String? in
                let hex = value.trimmingCharacters(in: .whitespaces).uppercased()
                let full = hex.hasPrefix("#") ? hex : "#" + hex
                return full.range(of: "^#[0-9A-F]{6}$", options: .regularExpression) != nil ? full : nil
            }
            guard !label.isEmpty, !words.isEmpty else { continue }
            rules.append(CustomBadgeRule(label: String(label.prefix(24)), match: Array(words.prefix(12)), colorHex: color))
            if rules.count >= maxRules { break }
        }
        return rules
    }

    /// The imported badges that apply to a source.
    public static func badges(for stream: AddonStream, rules: [CustomBadgeRule]) -> [CustomBadgeRule] {
        if rules.isEmpty { return [] }
        let text = [stream.name, stream.details].compactMap { $0 }.joined(separator: " ")
        return rules.filter { $0.matches(text) }
    }
}
