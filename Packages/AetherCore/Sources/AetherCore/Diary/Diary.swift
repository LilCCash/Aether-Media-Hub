import Foundation

/// One viewing written in the diary: when, how it went, what the viewer thought. Written by the viewer or marked from the player.
public struct DiaryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var metaID: String
    public var type: String
    public var name: String
    public var poster: String?
    public var year: String?
    public var genres: [String]
    public var watchedAt: Date
    /// Half-stars: 1...10 (0.5 to 5 stars); nil = not rated.
    public var rating: Int?
    public var note: String
    public var rewatch: Bool
    public var runtimeMinutes: Int?
    /// Directors and main cast, to count who appears most in the viewer's history.
    public var people: [String]

    public init(id: String = UUID().uuidString, metaID: String, type: String, name: String, poster: String? = nil, year: String? = nil, genres: [String] = [],
                watchedAt: Date = Date(), rating: Int? = nil, note: String = "", rewatch: Bool = false, runtimeMinutes: Int? = nil, people: [String] = []) {
        self.id = id
        self.metaID = metaID
        self.type = type
        self.name = name
        self.poster = poster
        self.year = year
        self.genres = genres
        self.watchedAt = watchedAt
        self.rating = rating.map { min(10, max(1, $0)) }
        self.note = note
        self.rewatch = rewatch
        self.runtimeMinutes = runtimeMinutes
        self.people = people
    }
}

public struct DiarySettings: Codable, Equatable, Sendable {
    public var entries: [DiaryEntry] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decode([DiaryEntry].self, forKey: .entries)) ?? []
    }

    /// Newest first.
    public var timeline: [DiaryEntry] { return entries.sorted { $0.watchedAt > $1.watchedAt } }
    public func entries(for metaID: String) -> [DiaryEntry] { return timeline.filter { $0.metaID == metaID } }
    public func latest(for metaID: String) -> DiaryEntry? { return entries(for: metaID).first }
    public var watchedIDs: Set<String> { return Set(entries.map { $0.metaID }) }

    /// Adds a viewing; a second one of the same title is marked as a rewatch.
    public mutating func add(_ entry: DiaryEntry) {
        var entry = entry
        if entries.contains(where: { $0.metaID == entry.metaID && $0.id != entry.id }) { entry.rewatch = true }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
    }
    public mutating func remove(id: String) { entries.removeAll { $0.id == id } }
    public mutating func removeAll(metaID: String) { entries.removeAll { $0.metaID == metaID } }
}

public struct DiaryStats: Equatable, Sendable {
    public struct Count: Equatable, Sendable { public var name: String; public var count: Int }
    public var films: Int
    public var episodesAndSeries: Int
    public var minutes: Int
    public var rewatches: Int
    public var averageRating: Double?
    public var topGenres: [Count]
    public var topPeople: [Count]
    public var perMonth: [Int]

    public var hours: Int { return minutes / 60 }

    /// Statistics of a year (nil = every viewing): films and series counted apart, hours, genres, people and the viewings of each month.
    public static func compute(_ entries: [DiaryEntry], year: Int? = nil, calendar: Calendar = .current) -> DiaryStats {
        let used = entries.filter { year == nil || calendar.component(.year, from: $0.watchedAt) == year }
        func top(_ lists: [[String]]) -> [Count] {
            var counts: [String: Int] = [:]
            for item in lists.flatMap({ $0 }) where !item.isEmpty { counts[item, default: 0] += 1 }
            return counts.map { Count(name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }.prefix(5).map { $0 }
        }
        var months = [Int](repeating: 0, count: 12)
        for entry in used { months[calendar.component(.month, from: entry.watchedAt) - 1] += 1 }
        let rated = used.compactMap { $0.rating }
        return DiaryStats(films: used.filter { $0.type == "movie" }.count, episodesAndSeries: used.filter { $0.type != "movie" }.count,
                          minutes: used.compactMap { $0.runtimeMinutes }.reduce(0, +), rewatches: used.filter { $0.rewatch }.count,
                          averageRating: rated.isEmpty ? nil : Double(rated.reduce(0, +)) / Double(rated.count) / 2,
                          topGenres: top(used.map { $0.genres }), topPeople: top(used.map { $0.people }), perMonth: months)
    }

    /// The years that have viewings, newest first.
    public static func years(_ entries: [DiaryEntry], calendar: Calendar = .current) -> [Int] {
        return Array(Set(entries.map { calendar.component(.year, from: $0.watchedAt) })).sorted(by: >)
    }
}
