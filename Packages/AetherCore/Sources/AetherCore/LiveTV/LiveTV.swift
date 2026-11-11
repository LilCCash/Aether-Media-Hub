import Foundation

// MARK: M3U playlists

/// One channel of an M3U playlist.
public struct M3UChannel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var logo: String?
    public var group: String?
    public var url: String
    /// `#EXTVLCOPT:http-user-agent` / `http-referrer`, when the playlist asks for them.
    public var userAgent: String?
    public var referrer: String?
    public var tvgID: String?

    public init(id: String, name: String, logo: String? = nil, group: String? = nil, url: String, userAgent: String? = nil, referrer: String? = nil, tvgID: String? = nil) {
        self.id = id
        self.name = name
        self.logo = logo
        self.group = group
        self.url = url
        self.userAgent = userAgent
        self.referrer = referrer
        self.tvgID = tvgID
    }

    /// The headers a player has to send for this channel.
    public var requestHeaders: [String: String] {
        var headers: [String: String] = [:]
        if let agent = userAgent, !agent.isEmpty { headers["User-Agent"] = agent }
        if let referrer = referrer, !referrer.isEmpty { headers["Referer"] = referrer }
        return headers
    }
}

public struct M3UParseResult: Equatable, Sendable {
    public var channels: [M3UChannel]
    /// Entries with an address that is not http(s), or no address at all.
    public var skipped: Int
    /// The guides the playlist announces in its header (`url-tvg`, `x-tvg-url`), http(s) only.
    public var guides: [String] = []
}

public enum M3UParser {
    public static let maxChannels = 20_000

    public static func parse(_ text: String, maxChannels: Int = M3UParser.maxChannels) -> M3UParseResult {
        var channels: [M3UChannel] = []
        var skipped = 0
        var seen = Set<String>()
        var pending: (attrs: [String: String], name: String)?
        var agent: String?
        var referrer: String?
        var extGroup: String?
        var guides: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTM3U") {
                let attrs = attributes(in: String(line.dropFirst("#EXTM3U".count)))
                for key in ["url-tvg", "x-tvg-url"] {
                    for address in (attrs[key] ?? "").split(separator: ",") {
                        let text = address.trimmingCharacters(in: .whitespaces)
                        if let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !guides.contains(text) { guides.append(text) }
                    }
                }
            } else if line.hasPrefix("#EXTINF") {
                let body = String(line.dropFirst("#EXTINF:".count))
                let parts = splitExtInf(body)
                pending = (attributes(in: parts.attributes), parts.name)
                agent = nil; referrer = nil; extGroup = nil
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = String(line.dropFirst("#EXTVLCOPT:".count))
                if let equals = option.firstIndex(of: "=") {
                    let key = option[..<equals].lowercased()
                    let value = String(option[option.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                    if key == "http-user-agent" { agent = value } else if key == "http-referrer" || key == "http-referer" { referrer = value }
                }
            } else if line.hasPrefix("#EXTGRP:") {
                extGroup = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#") {
                continue
            } else if let entry = pending {
                pending = nil
                guard let url = URL(string: line), let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"), url.host != nil else {
                    skipped += 1
                    continue
                }
                let title = entry.name.trimmingCharacters(in: .whitespaces)
                let name = !title.isEmpty ? title : (entry.attrs["tvg-name"] ?? "Canale")
                let key = name.lowercased() + "|" + line
                guard seen.insert(key).inserted else { continue }
                let group = nonEmpty(entry.attrs["group-title"]) ?? nonEmpty(extGroup)
                channels.append(M3UChannel(id: stableID(key), name: name, logo: nonEmpty(entry.attrs["tvg-logo"]), group: group, url: line,
                                           userAgent: nonEmpty(agent), referrer: nonEmpty(referrer), tvgID: nonEmpty(entry.attrs["tvg-id"])))
                if channels.count >= maxChannels { break }
            }
        }
        return M3UParseResult(channels: channels, skipped: skipped, guides: guides)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    /// The first comma outside quotes separates the attributes from the channel name (a logo address or a group may contain commas).
    static func splitExtInf(_ body: String) -> (attributes: String, name: String) {
        var quote: Character?
        var index = body.startIndex
        while index < body.endIndex {
            let c = body[index]
            if let open = quote { if c == open { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == "," {
                return (String(body[..<index]), String(body[body.index(after: index)...]))
            }
            index = body.index(after: index)
        }
        return (body, "")
    }

    static func attributes(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var quote: Character?
        var reading = false
        var isValue = false
        for c in text {
            if let open = quote {
                if c == open { quote = nil; result[key.lowercased()] = value; key = ""; value = ""; isValue = false } else { value.append(c) }
            } else if c == "=" && !key.isEmpty && !isValue {
                isValue = true
            } else if isValue && (c == "\"" || c == "'") {
                quote = c
            } else if c == " " || c == "\t" {
                if !isValue { key = ""; reading = false }
            } else if !isValue {
                key.append(c); reading = true
            }
        }
        _ = reading
        return result
    }

    /// A fixed-seed hash (FNV-1a): the same channel keeps the same id from one launch to the next, which `hashValue` does not.
    public static func stableID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

// MARK: Settings

public struct LivePlaylist: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// nil for a list imported from a file (its channels live in the cache only).
    public var url: String?
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, url: String?, addedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.url = url
        self.addedAt = addedAt
    }
}

/// A channel kept in «Preferiti» of Live TV: what is needed to show it and to play it again.
public struct LiveFavorite: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var logo: String?
    /// An M3U channel: its address (and the headers it needs).
    public var url: String?
    public var userAgent: String?
    public var referrer: String?
    /// An addon channel: where to open it.
    public var metaType: String?
    public var metaID: String?

    public init(id: String, name: String, logo: String? = nil, url: String? = nil, userAgent: String? = nil, referrer: String? = nil, metaType: String? = nil, metaID: String? = nil) {
        self.id = id
        self.name = name
        self.logo = logo
        self.url = url
        self.userAgent = userAgent
        self.referrer = referrer
        self.metaType = metaType
        self.metaID = metaID
    }
}

public enum LiveGuideStyle: String, Codable, CaseIterable, Sendable {
    case rows, grid

    public var title: String {
        switch self {
        case .rows: return "Sotto i canali"
        case .grid: return "Griglia per orario"
        }
    }
}

public struct LiveTVSettings: Codable, Equatable, Sendable {
    /// The «Live TV» entry in the bottom bar.
    public var showTab: Bool = false
    public var playlists: [LivePlaylist] = []
    /// Catalogs the viewer marked as live TV although they are not of the «tv» type, and live catalogs the viewer switched off.
    /// A catalog is named `<addon id>/<catalog key>`.
    public var includedCatalogs: [String] = []
    public var excludedCatalogs: [String] = []
    public var favorites: [LiveFavorite] = []
    /// The TV guide under the channels of the playlists.
    public var guideEnabled: Bool = true
    /// The viewer's own XMLTV address (.xml or .xml.gz); empty for the playlist's own guide, else the public Italian one.
    public var guideURL: String = ""
    /// How the guide is shown: under each channel (now and next) or as a grid of all the channels by time.
    public var guideStyle: LiveGuideStyle = .rows

    public init() {}

    private enum CodingKeys: String, CodingKey { case showTab, playlists, includedCatalogs, excludedCatalogs, favorites, guideEnabled, guideURL, guideStyle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showTab = c.value(.showTab, default: false)
        playlists = c.lossyArray(LivePlaylist.self, forKey: .playlists)
        includedCatalogs = c.stringList(.includedCatalogs)
        excludedCatalogs = c.stringList(.excludedCatalogs)
        favorites = c.lossyArray(LiveFavorite.self, forKey: .favorites)
        guideEnabled = c.value(.guideEnabled, default: true)
        guideURL = c.value(.guideURL, default: "")
        guideStyle = c.value(.guideStyle, default: .rows)
    }

    /// The guide to download: the viewer's address, else the one a playlist announces (`url-tvg`), else the public Italian one.
    public func guideAddress(announced: [String]) -> String? {
        guard guideEnabled else { return nil }
        let own = guideURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return announced.first { !$0.isEmpty } ?? TVGuide.defaultItalianURL
    }

    /// Is the catalog shown in Live TV? A «tv» catalog is, unless switched off; any other is only when the viewer asked for it.
    public func includes(catalogKey: String, isTVType: Bool) -> Bool {
        if excludedCatalogs.contains(catalogKey) { return false }
        return isTVType || includedCatalogs.contains(catalogKey)
    }

    public mutating func setIncluded(_ included: Bool, catalogKey: String, isTVType: Bool) {
        includedCatalogs.removeAll { $0 == catalogKey }
        excludedCatalogs.removeAll { $0 == catalogKey }
        if included && !isTVType { includedCatalogs.append(catalogKey) }
        if !included && isTVType { excludedCatalogs.append(catalogKey) }
    }

    public func isFavorite(_ id: String) -> Bool { return favorites.contains { $0.id == id } }

    public mutating func toggleFavorite(_ favorite: LiveFavorite) {
        if let index = favorites.firstIndex(where: { $0.id == favorite.id }) { favorites.remove(at: index) } else { favorites.insert(favorite, at: 0) }
    }
}

// MARK: Searching and grouping

public enum LiveChannelList {
    /// Channels whose name or group contains every word of `query` (accents and case ignored), in the chosen group.
    public static func filter(_ channels: [M3UChannel], query: String, group: String?) -> [M3UChannel] {
        let words = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).split(separator: " ").map(String.init)
        return channels.filter { channel in
            if let group = group, channel.group != group { return false }
            guard !words.isEmpty else { return true }
            let haystack = (channel.name + " " + (channel.group ?? "")).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    /// The groups in the order of first appearance, with how many channels each has.
    public static func groups(_ channels: [M3UChannel]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for channel in channels {
            let name = channel.group ?? "Senza gruppo"
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { (name: $0, count: counts[$0] ?? 0) }
    }
}
