import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: XMLTV guide

/// One programme of the TV guide.
public struct TVProgramme: Codable, Hashable, Sendable {
    public var start: Date
    public var stop: Date
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var category: String?

    public init(start: Date, stop: Date, title: String, subtitle: String? = nil, summary: String? = nil, category: String? = nil) {
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.category = category
    }

    public func isOn(at date: Date) -> Bool { return start <= date && date < stop }

    /// 0…1, how much of the programme has gone by.
    public func progress(at date: Date) -> Double {
        let length = stop.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / length))
    }
}

/// A TV guide (XMLTV): the channels it knows, with their names, and their programmes in order.
public struct TVGuide: Codable, Equatable, Sendable {
    public struct Channel: Codable, Equatable, Sendable {
        public var id: String
        public var names: [String]
    }

    public var channels: [Channel]
    /// Guide channel id → programmes, by start time.
    public var programmes: [String: [TVProgramme]]
    public var fetchedAt: Date

    public init(channels: [Channel] = [], programmes: [String: [TVProgramme]] = [:], fetchedAt: Date = Date()) {
        self.channels = channels
        self.programmes = programmes
        self.fetchedAt = fetchedAt
    }

    /// Italian channels, from the public guide built from Sky's listings by epgshare01 (gzip, about 2 MB, refreshed every day).
    public static let defaultItalianURL = "https://epgshare01.online/epgshare01/epg_ripper_IT1.xml.gz"

    public var isEmpty: Bool { return programmes.isEmpty }

    public func now(_ channelID: String, at date: Date = Date()) -> TVProgramme? {
        return programmes[channelID]?.first { $0.isOn(at: date) }
    }

    /// What is on now and what follows.
    public func upcoming(_ channelID: String, from date: Date = Date(), count: Int) -> [TVProgramme] {
        guard let list = programmes[channelID] else { return [] }
        return Array(list.filter { $0.stop > date }.prefix(count))
    }

    /// The programmes of a channel that touch the window.
    public func programmes(_ channelID: String, between start: Date, and end: Date) -> [TVProgramme] {
        return (programmes[channelID] ?? []).filter { $0.stop > start && $0.start < end }
    }
}

/// Reads an XMLTV file, keeping only the programmes that touch a window around now (the guides cover a week or two; the app
/// shows a day and a half).
public enum XMLTVParser {
    public static func parse(_ data: Data, now: Date = Date(), keepBefore: TimeInterval = 3 * 3600, keepAfter: TimeInterval = 36 * 3600) -> TVGuide {
        let delegate = Delegate(from: now.addingTimeInterval(-keepBefore), to: now.addingTimeInterval(keepAfter))
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        var programmes: [String: [TVProgramme]] = [:]
        for (id, list) in delegate.programmes {
            var seen = Set<Date>()
            programmes[id] = list.sorted { $0.start < $1.start }.filter { seen.insert($0.start).inserted }
        }
        return TVGuide(channels: delegate.channels, programmes: programmes, fetchedAt: now)
    }

    /// `20261108050000 +0000` (the offset may be missing: then UTC).
    public static func date(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        guard let stamp = parts.first, stamp.count >= 12 else { return nil }
        let digits = Array(stamp.prefix(14))
        func number(_ from: Int, _ length: Int) -> Int? {
            guard from + length <= digits.count else { return length == 2 && from == 12 ? 0 : nil }
            return Int(String(digits[from..<(from + length)]))
        }
        guard let year = number(0, 4), let month = number(4, 2), let day = number(6, 2), let hour = number(8, 2), let minute = number(10, 2) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = number(12, 2) ?? 0
        var offset = 0
        if parts.count > 1 {
            let zone = parts[1]
            if zone.count == 5, let sign = zone.first, sign == "+" || sign == "-", let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)) {
                offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let from: Date
        let to: Date
        var channels: [TVGuide.Channel] = []
        var programmes: [String: [TVProgramme]] = [:]

        private var channelID: String?
        private var names: [String] = []
        private var programme: (channel: String, start: Date, stop: Date)?
        private var title: String?
        private var subtitle: String?
        private var summary: String?
        private var category: String?
        private var text = ""

        init(from: Date, to: Date) {
            self.from = from
            self.to = to
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "channel":
                channelID = attributes["id"]
                names = []
            case "programme":
                guard let channel = attributes["channel"], let start = attributes["start"].flatMap(XMLTVParser.date),
                      let stop = attributes["stop"].flatMap(XMLTVParser.date), stop > from, start < to, stop > start else {
                    programme = nil
                    return
                }
                programme = (channel, start, stop)
                title = nil
                subtitle = nil
                summary = nil
                category = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if text.count < 2000 { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            switch name {
            case "display-name":
                if channelID != nil, !value.isEmpty { names.append(value) }
            case "channel":
                if let id = channelID { channels.append(TVGuide.Channel(id: id, names: names)) }
                channelID = nil
            case "title":
                if programme != nil, title == nil, !value.isEmpty { title = value }
            case "sub-title":
                if programme != nil, subtitle == nil, !value.isEmpty { subtitle = value }
            case "desc":
                if programme != nil, summary == nil, !value.isEmpty { summary = value }
            case "category":
                if programme != nil, category == nil, !value.isEmpty { category = value }
            case "programme":
                if let current = programme, let title = title {
                    programmes[current.channel, default: []].append(TVProgramme(start: current.start, stop: current.stop, title: title,
                                                                               subtitle: subtitle, summary: summary, category: category))
                }
                programme = nil
            default:
                break
            }
        }
    }
}

// MARK: Matching playlist channels to the guide

/// Finds the guide channel of a playlist channel. The playlist's `tvg-id` is tried first as it is, then both the ids and the names
/// are compared once reduced to letters and digits, without «HD», «TV», the «.it» ending or the channel number of the listing
/// («Rai 1 HD  101» and «Rai1.it» are the same channel).
public struct TVGuideMatcher: Sendable {
    private let exact: Set<String>
    private let table: [String: String]

    public init(_ guide: TVGuide) {
        exact = Set(guide.programmes.keys)
        var table: [String: String] = [:]
        for channel in guide.channels where guide.programmes[channel.id] != nil {
            for key in [channel.id] + channel.names {
                let normal = Self.normalise(key)
                if !normal.isEmpty, table[normal] == nil { table[normal] = channel.id }
            }
        }
        self.table = table
    }

    public func channelID(tvgID: String?, name: String) -> String? {
        if let id = tvgID, !id.isEmpty, exact.contains(id) { return id }
        if let id = tvgID, let found = table[Self.normalise(id)] { return found }
        return table[Self.normalise(name)]
    }

    /// Names that are written differently in the playlists and in the guide.
    static let aliases: [String: String] = [
        "twentyseven": "27twentyseven", "20mediaset": "20", "tgcom24": "tgcom", "raisportplus": "raisport",
        "mediasetitalia2": "italia2", "rtvsanmarino": "sanmarinortv",
    ]

    public static func normalise(_ text: String) -> String {
        var value = text.lowercased().trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(".it") { value = String(value.dropLast(3)) }
        // The channel number of the listing: «Rai 1 HD  101», «Rai.1.HD..101».
        if let range = value.range(of: #"(\.\.|\s\s+)\d+$"#, options: .regularExpression) { value.removeSubrange(range) }
        value = value.replacingOccurrences(of: "&", with: "and").replacingOccurrences(of: "+", with: "plus")
        value = String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }.map(Character.init))
        while true {
            var changed = false
            for ending in ["fhd", "uhd", "hd", "tv", "channel"] where value.hasSuffix(ending) && value.count > ending.count + 1 {
                value = String(value.dropLast(ending.count))
                changed = true
                break
            }
            if !changed { break }
        }
        return aliases[value] ?? value
    }
}

// MARK: gzip

/// The guides are often served as `.xml.gz`: the gzip wrapper around the deflate data (RFC 1952). The app inflates the payload
/// with the system's decompressor, which reads raw deflate only.
public enum GzipContainer {
    public static func isGzip(_ data: Data) -> Bool {
        return data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// The raw deflate bytes inside a gzip file, or nil when the header is not one.
    public static func deflatePayload(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        return Data(bytes[index..<(bytes.count - 8)])
    }

    /// The size of the original file, from the last four bytes (modulo 4 GB).
    public static func originalSize(_ data: Data) -> Int? {
        let bytes = [UInt8](data.suffix(4))
        guard bytes.count == 4 else { return nil }
        return Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
    }
}
