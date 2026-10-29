import Foundation

/// A title the user saved. Exists while it is in the watchlist or favourites; when both are cleared it stays as a
/// tombstone (`isRemoved`) so that a later merge/restore does not resurrect it.
public struct LibraryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public var posterShape: PosterShape
    public var background: String?
    public var logo: String?
    public var releaseInfo: String?
    public var imdbRating: String?
    public var inWatchlist: Bool
    public var isFavorite: Bool
    public var addedAt: Date
    public var modifiedAt: Date
    public var isRemoved: Bool

    public init(id: String, type: String, name: String, poster: String? = nil, posterShape: PosterShape = .poster,
                background: String? = nil, logo: String? = nil, releaseInfo: String? = nil, imdbRating: String? = nil,
                inWatchlist: Bool = false, isFavorite: Bool = false, addedAt: Date = Date(),
                modifiedAt: Date = Date(), isRemoved: Bool = false) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.inWatchlist = inWatchlist
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
        self.isRemoved = isRemoved
    }


    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, releaseInfo, imdbRating
        case inWatchlist, isFavorite, addedAt, modifiedAt, isRemoved
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.type = c.flexString(.type) ?? ContentType.other
        self.name = c.flexString(.name) ?? id
        self.poster = c.flexString(.poster)
        self.posterShape = c.lenient(PosterShape.self, forKey: .posterShape) ?? .poster
        self.background = c.flexString(.background)
        self.logo = c.flexString(.logo)
        self.releaseInfo = c.flexString(.releaseInfo)
        self.imdbRating = c.flexString(.imdbRating)
        self.inWatchlist = c.flexBool(.inWatchlist) ?? false
        self.isFavorite = c.flexBool(.isFavorite) ?? false
        let modified = c.lenient(Date.self, forKey: .modifiedAt) ?? Date(timeIntervalSince1970: 0)
        self.modifiedAt = modified
        self.addedAt = c.lenient(Date.self, forKey: .addedAt) ?? modified
        self.isRemoved = c.flexBool(.isRemoved) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encode(posterShape, forKey: .posterShape)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(logo, forKey: .logo)
        try c.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try c.encodeIfPresent(imdbRating, forKey: .imdbRating)
        try c.encode(inWatchlist, forKey: .inWatchlist)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(addedAt, forKey: .addedAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
        try c.encode(isRemoved, forKey: .isRemoved)
    }

    public init(meta: MetaItem, now: Date) {
        self.init(id: meta.id, type: meta.type, name: meta.name, poster: meta.poster, posterShape: meta.posterShape,
                  background: meta.background, logo: meta.logo, releaseInfo: meta.releaseInfo,
                  imdbRating: meta.imdbRating, addedAt: now, modifiedAt: now)
    }

    /// A lightweight `MetaItem` for navigation / poster cards.
    public var asMeta: MetaItem {
        return MetaItem(id: id, type: type, name: name, poster: poster, posterShape: posterShape,
                        background: background, logo: logo, releaseInfo: releaseInfo, imdbRating: imdbRating)
    }
}

/// Position of one video (movie or episode). Doubles as the watch history record.
public struct PlaybackProgress: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var metaID: String
    public var videoID: String
    public var type: String
    public var title: String
    public var episodeTitle: String?
    public var season: Int?
    public var episode: Int?
    public var poster: String?
    public var posterShape: PosterShape
    public var background: String?
    /// Seconds.
    public var position: Double
    /// Seconds; 0 when unknown.
    public var duration: Double
    public var updatedAt: Date
    public var isCompleted: Bool
    /// Removed from "Continue watching" by the user without deleting the history.
    public var isDismissed: Bool

    public init(metaID: String, videoID: String, type: String, title: String, episodeTitle: String? = nil,
                season: Int? = nil, episode: Int? = nil, poster: String? = nil, posterShape: PosterShape = .poster,
                background: String? = nil, position: Double = 0, duration: Double = 0, updatedAt: Date = Date(),
                isCompleted: Bool = false, isDismissed: Bool = false) {
        self.id = PlaybackProgress.key(metaID: metaID, videoID: videoID)
        self.metaID = metaID
        self.videoID = videoID
        self.type = type
        self.title = title
        self.episodeTitle = episodeTitle
        self.season = season
        self.episode = episode
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
        self.isCompleted = isCompleted
        self.isDismissed = isDismissed
    }


    private enum CodingKeys: String, CodingKey {
        case id, metaID, videoID, type, title, episodeTitle, season, episode, poster, posterShape, background
        case position, duration, updatedAt, isCompleted, isDismissed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let metaID = try c.decode(String.self, forKey: .metaID)
        let videoID = try c.decode(String.self, forKey: .videoID)
        self.metaID = metaID
        self.videoID = videoID
        self.id = PlaybackProgress.key(metaID: metaID, videoID: videoID)
        self.type = c.flexString(.type) ?? ContentType.other
        self.title = c.flexString(.title) ?? metaID
        self.episodeTitle = c.flexString(.episodeTitle)
        self.season = c.flexInt(.season)
        self.episode = c.flexInt(.episode)
        self.poster = c.flexString(.poster)
        self.posterShape = c.lenient(PosterShape.self, forKey: .posterShape) ?? .poster
        self.background = c.flexString(.background)
        self.position = c.lenient(Double.self, forKey: .position) ?? 0
        self.duration = c.lenient(Double.self, forKey: .duration) ?? 0
        self.updatedAt = c.lenient(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        self.isCompleted = c.flexBool(.isCompleted) ?? false
        self.isDismissed = c.flexBool(.isDismissed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(metaID, forKey: .metaID)
        try c.encode(videoID, forKey: .videoID)
        try c.encode(type, forKey: .type)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try c.encodeIfPresent(season, forKey: .season)
        try c.encodeIfPresent(episode, forKey: .episode)
        try c.encodeIfPresent(poster, forKey: .poster)
        try c.encode(posterShape, forKey: .posterShape)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encode(position, forKey: .position)
        try c.encode(duration, forKey: .duration)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isCompleted, forKey: .isCompleted)
        try c.encode(isDismissed, forKey: .isDismissed)
    }

    public static func key(metaID: String, videoID: String) -> String {
        return "\(metaID)|\(videoID)"
    }

    /// 0...1
    public var fraction: Double {
        guard duration > 0 else { return 0 }
        return max(0, min(1, position / duration))
    }

    public var remaining: Double? {
        return duration > 0 ? max(0, duration - position) : nil
    }

    public var episodeLabel: String? {
        guard let season = season, let episode = episode else { return nil }
        let s = season < 10 ? "0\(season)" : "\(season)"
        let e = episode < 10 ? "0\(episode)" : "\(episode)"
        return "S\(s)E\(e)"
    }

    public var asMeta: MetaItem {
        return MetaItem(id: metaID, type: type, name: title, poster: poster, posterShape: posterShape, background: background)
    }
}

public struct SearchHistoryItem: Codable, Hashable, Identifiable, Sendable {
    public var query: String
    public var date: Date
    public var id: String { return query.lowercased() }

    public init(query: String, date: Date = Date()) {
        self.query = query
        self.date = date
    }

    private enum CodingKeys: String, CodingKey { case query, date }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let query = c.flexString(.query), !query.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "query"))
        }
        self.query = query
        self.date = c.lenient(Date.self, forKey: .date) ?? Date(timeIntervalSince1970: 0)
    }
}

public struct LibraryState: Codable, Sendable {
    public var schemaVersion: Int
    public var entries: [String: LibraryEntry]
    public var progress: [String: PlaybackProgress]
    public var searchHistory: [SearchHistoryItem]

    public static let currentSchema = 1

    private enum CodingKeys: String, CodingKey { case schemaVersion, entries, progress, searchHistory }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = c.flexInt(.schemaVersion) ?? LibraryState.currentSchema
        // Skip individual corrupt records instead of losing the whole library.
        let entries = c.lossyArray(LibraryEntry.self, forKey: .entries)
        var entryMap: [String: LibraryEntry] = [:]
        for entry in entries { entryMap[entry.id] = entry }
        self.entries = entryMap
        let records = c.lossyArray(PlaybackProgress.self, forKey: .progress)
        var progressMap: [String: PlaybackProgress] = [:]
        for record in records { progressMap[record.id] = record }
        self.progress = progressMap
        self.searchHistory = c.lossyArray(SearchHistoryItem.self, forKey: .searchHistory)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        // Arrays (sorted) keep the file diff-friendly and deterministic.
        try c.encode(entries.values.sorted { $0.id < $1.id }, forKey: .entries)
        try c.encode(progress.values.sorted { $0.id < $1.id }, forKey: .progress)
        try c.encode(searchHistory, forKey: .searchHistory)
    }

    public init(schemaVersion: Int = LibraryState.currentSchema, entries: [String: LibraryEntry] = [:],
                progress: [String: PlaybackProgress] = [:], searchHistory: [SearchHistoryItem] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.progress = progress
        self.searchHistory = searchHistory
    }
}

/// User-tunable behaviour of the library (wired to Settings).
public struct LibraryPolicy: Sendable, Equatable {
    /// Fraction of the duration after which a video counts as watched.
    public var watchedThreshold: Double
    /// Positions shorter than this are not recorded (accidental taps).
    public var minimumRecordedSeconds: Double
    /// Whether playback creates history/progress at all (privacy switch).
    public var recordHistory: Bool
    public var maxProgressRecords: Int
    public var maxSearchHistory: Int

    public init(watchedThreshold: Double = 0.9, minimumRecordedSeconds: Double = 10, recordHistory: Bool = true,
                maxProgressRecords: Int = 2000, maxSearchHistory: Int = 30) {
        self.watchedThreshold = watchedThreshold
        self.minimumRecordedSeconds = minimumRecordedSeconds
        self.recordHistory = recordHistory
        self.maxProgressRecords = maxProgressRecords
        self.maxSearchHistory = maxSearchHistory
    }
}
