import Foundation

public enum PosterShape: String, Codable, Hashable, Sendable {
    case poster
    case square
    case landscape

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self))?.lowercased() ?? ""
        self = PosterShape(rawValue: raw) ?? .poster
    }

    /// width / height
    public var aspectRatio: Double {
        switch self {
        case .poster: return 0.675
        case .square: return 1.0
        case .landscape: return 1.77
        }
    }
}

public struct MetaLink: Codable, Hashable, Sendable {
    public var name: String
    public var category: String
    public var url: String

    public init(name: String, category: String, url: String) {
        self.name = name
        self.category = category
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case name, category, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = container.flexString(.name),
              let category = container.flexString(.category),
              let url = container.flexString(.url) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "link"))
        }
        self.name = name
        self.category = category
        self.url = url
    }
}

/// Trailer reference. Legacy shape `{source: "<youtubeId>", type: "Trailer"}`, modern shape is a Stream-like object (`ytId`).
public struct TrailerRef: Codable, Hashable, Sendable {
    public var youtubeID: String
    public var type: String

    public init(youtubeID: String, type: String = "Trailer") {
        self.youtubeID = youtubeID
        self.type = type
    }

    private enum CodingKeys: String, CodingKey { case source, type, ytId, title }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexString(.source) ?? container.flexString(.ytId), !id.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "trailer"))
        }
        self.youtubeID = id
        self.type = container.flexString(.type) ?? container.flexString(.title) ?? "Trailer"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(youtubeID, forKey: .source)
        try container.encode(type, forKey: .type)
    }

    public var watchURL: URL? {
        return URL(string: "https://www.youtube.com/watch?v=\(youtubeID)")
    }
}

/// An episode / upload / programme of a meta item.
public struct Video: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var released: Date?
    public var season: Int?
    public var episode: Int?
    public var thumbnail: String?
    public var overview: String?
    public var available: Bool?
    public var startTime: Date?
    public var endTime: Date?
    /// Streams embedded in the meta response. When present Stremio does not ask other addons.
    public var streams: [AddonStream]

    public init(id: String, title: String, released: Date? = nil, season: Int? = nil, episode: Int? = nil,
                thumbnail: String? = nil, overview: String? = nil, available: Bool? = nil,
                startTime: Date? = nil, endTime: Date? = nil, streams: [AddonStream] = []) {
        self.id = id
        self.title = title
        self.released = released
        self.season = season
        self.episode = episode
        self.thumbnail = thumbnail
        self.overview = overview
        self.available = available
        self.startTime = startTime
        self.endTime = endTime
        self.streams = streams
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, name, released, season, episode, thumbnail, overview, description
        case available, startTime, endTime, streams, stream
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexString(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "video id"))
        }
        self.id = id
        self.title = container.flexString(.title) ?? container.flexString(.name) ?? ""
        self.released = AddonDate.parse(container.flexString(.released))
        self.season = container.flexInt(.season)
        self.episode = container.flexInt(.episode)
        self.thumbnail = container.flexString(.thumbnail)
        self.overview = container.flexString(.overview) ?? container.flexString(.description)
        self.available = container.flexBool(.available)
        self.startTime = AddonDate.parse(container.flexString(.startTime))
        self.endTime = AddonDate.parse(container.flexString(.endTime))
        var streams = container.lossyArray(AddonStream.self, forKey: .streams)
        if streams.isEmpty {
            // `stream` may be a single object or an array (OneOrMany in stremio-core).
            if let single = container.lenient(AddonStream.self, forKey: .stream) {
                streams = [single]
            } else {
                streams = container.lossyArray(AddonStream.self, forKey: .stream)
            }
        }
        self.streams = streams
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        if let released = released { try container.encode(AddonDate.format(released), forKey: .released) }
        try container.encodeIfPresent(season, forKey: .season)
        try container.encodeIfPresent(episode, forKey: .episode)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(available, forKey: .available)
        if let startTime = startTime { try container.encode(AddonDate.format(startTime), forKey: .startTime) }
        if let endTime = endTime { try container.encode(AddonDate.format(endTime), forKey: .endTime) }
        if !streams.isEmpty { try container.encode(streams, forKey: .streams) }
    }

    public var isEpisode: Bool { return season != nil && episode != nil }

    /// "S01E03" style label, nil for non-episodes.
    public var episodeLabel: String? {
        guard let season = season, let episode = episode else { return nil }
        let s = season < 10 ? "0\(season)" : "\(season)"
        let e = episode < 10 ? "0\(episode)" : "\(episode)"
        return "S\(s)E\(e)"
    }
}

public struct MetaBehaviorHints: Codable, Hashable, Sendable {
    public var defaultVideoId: String?
    public var isLive: Bool
    public var hasScheduledVideos: Bool

    public init(defaultVideoId: String? = nil, isLive: Bool = false, hasScheduledVideos: Bool = false) {
        self.defaultVideoId = defaultVideoId
        self.isLive = isLive
        self.hasScheduledVideos = hasScheduledVideos
    }

    private enum CodingKeys: String, CodingKey { case defaultVideoId, isLive, hasScheduledVideos }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultVideoId = container.flexString(.defaultVideoId)
        self.isLive = container.flexBool(.isLive) ?? false
        self.hasScheduledVideos = container.flexBool(.hasScheduledVideos) ?? false
    }
}

/// Used both for catalog entries (preview: no `videos`) and for the full detail response.
public struct MetaItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public var posterShape: PosterShape
    public var background: String?
    public var logo: String?
    public var description: String?
    public var releaseInfo: String?
    public var imdbRating: String?
    public var released: Date?
    public var runtime: String?
    public var genres: [String]
    public var cast: [String]
    public var directors: [String]
    public var writers: [String]
    public var language: String?
    public var country: String?
    public var awards: String?
    public var website: String?
    public var trailers: [TrailerRef]
    public var links: [MetaLink]
    public var videos: [Video]
    public var behaviorHints: MetaBehaviorHints
    /// Ids of the same title in IMDb / TMDB / TheTVDB, when the addon or the id itself tells them.
    public var externalIDs: ExternalIDs

    public init(id: String, type: String, name: String, poster: String? = nil,
                posterShape: PosterShape = .poster, background: String? = nil, logo: String? = nil,
                description: String? = nil, releaseInfo: String? = nil, imdbRating: String? = nil,
                released: Date? = nil, runtime: String? = nil, genres: [String] = [], cast: [String] = [],
                directors: [String] = [], writers: [String] = [], language: String? = nil,
                country: String? = nil, awards: String? = nil, website: String? = nil,
                trailers: [TrailerRef] = [], links: [MetaLink] = [], videos: [Video] = [],
                behaviorHints: MetaBehaviorHints = MetaBehaviorHints(),
                externalIDs: ExternalIDs = ExternalIDs()) {
        self.id = id
        self.type = type
        self.name = name
        self.externalIDs = externalIDs
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.description = description
        self.releaseInfo = releaseInfo
        self.imdbRating = imdbRating
        self.released = released
        self.runtime = runtime
        self.genres = genres
        self.cast = cast
        self.directors = directors
        self.writers = writers
        self.language = language
        self.country = country
        self.awards = awards
        self.website = website
        self.trailers = trailers
        self.links = links
        self.videos = videos
        self.behaviorHints = behaviorHints
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description, releaseInfo
        case imdbRating, released, runtime, genres, cast, director, directors, writer, writers
        case language, country, awards, website, trailers, links, videos, behaviorHints
        case year, title
        case imdb_id, moviedb_id, tmdb_id, tvdb_id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.flexString(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "meta id"))
        }
        let declaredIMDb = container.flexString(.imdb_id).flatMap { ExternalIDs.imdbID(fromMetaID: $0) }
        let declared = ExternalIDs(imdb: declaredIMDb,
                                   tmdb: container.flexInt(.moviedb_id) ?? container.flexInt(.tmdb_id),
                                   tvdb: container.flexInt(.tvdb_id))
        // The id itself wins over what the body declares (an addon's `imdb_id` must not contradict its own `tt…` id).
        self.externalIDs = ExternalIDs.fromMetaID(id).filling(from: declared)
        guard let name = container.flexString(.name) ?? container.flexString(.title) else {
            throw DecodingError.keyNotFound(CodingKeys.name,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "meta name"))
        }
        self.id = id
        self.name = name
        self.type = container.flexString(.type) ?? ContentType.other
        self.poster = container.flexString(.poster)
        self.posterShape = container.lenient(PosterShape.self, forKey: .posterShape) ?? .poster
        self.background = container.flexString(.background)
        self.logo = container.flexString(.logo)
        self.description = container.flexString(.description)
        self.releaseInfo = container.flexString(.releaseInfo) ?? container.flexString(.year)
        self.imdbRating = container.flexString(.imdbRating)
        self.released = AddonDate.parse(container.flexString(.released))
        self.runtime = container.flexString(.runtime)
        self.genres = container.stringList(.genres)
        self.cast = container.stringList(.cast)
        let directorList = container.stringList(.directors)
        self.directors = directorList.isEmpty ? container.stringList(.director) : directorList
        let writerList = container.stringList(.writers)
        self.writers = writerList.isEmpty ? container.stringList(.writer) : writerList
        self.language = container.flexString(.language)
        self.country = container.flexString(.country)
        self.awards = container.flexString(.awards)
        self.website = container.flexString(.website)
        self.trailers = container.lossyArray(TrailerRef.self, forKey: .trailers)
        self.links = container.lossyArray(MetaLink.self, forKey: .links)
        self.videos = MetaItem.sortedVideos(container.lossyArray(Video.self, forKey: .videos))
        self.behaviorHints = container.lenient(MetaBehaviorHints.self, forKey: .behaviorHints)
            ?? MetaBehaviorHints()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(poster, forKey: .poster)
        try container.encode(posterShape, forKey: .posterShape)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(logo, forKey: .logo)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(releaseInfo, forKey: .releaseInfo)
        try container.encodeIfPresent(imdbRating, forKey: .imdbRating)
        if let released = released { try container.encode(AddonDate.format(released), forKey: .released) }
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encode(genres, forKey: .genres)
        try container.encode(cast, forKey: .cast)
        try container.encode(directors, forKey: .directors)
        try container.encode(writers, forKey: .writers)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(awards, forKey: .awards)
        try container.encodeIfPresent(website, forKey: .website)
        try container.encode(trailers, forKey: .trailers)
        try container.encode(links, forKey: .links)
        try container.encode(videos, forKey: .videos)
        try container.encodeIfPresent(externalIDs.imdb, forKey: .imdb_id)
        try container.encodeIfPresent(externalIDs.tmdb, forKey: .moviedb_id)
        try container.encodeIfPresent(externalIDs.tvdb, forKey: .tvdb_id)
        try container.encode(behaviorHints, forKey: .behaviorHints)
    }

    // MARK: Derived

    public var isLive: Bool {
        return behaviorHints.isLive || ContentType.isLive(type)
    }

    /// IMDb identifier when the id is one (`tt1234567`).
    public var imdbID: String? {
        return MetaItem.isIMDbID(id) ? id : nil
    }

    public static func isIMDbID(_ id: String) -> Bool {
        guard id.hasPrefix("tt"), id.count >= 3 else { return false }
        return id.dropFirst(2).allSatisfy { $0.isNumber && $0.isASCII }
    }

    /// First 4-digit year found in `releaseInfo` (e.g. "2010", "2000-2014").
    public var year: Int? {
        if let info = releaseInfo, let year = MetaItem.firstYear(in: info) { return year }
        if let released = released {
            return Calendar(identifier: .gregorian).component(.year, from: released)
        }
        return nil
    }

    static func firstYear(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isASCII && character.isNumber {
                digits.append(character)
                if digits.count == 4 { return Int(digits) }
            } else {
                digits = ""
            }
        }
        return nil
    }

    public var ratingValue: Double? {
        guard let rating = imdbRating else { return nil }
        return Double(rating.replacingOccurrences(of: ",", with: "."))
    }

    /// Seasons that have at least one video, ascending. Season 0 (specials) comes first.
    public var seasons: [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for video in videos {
            if let season = video.season, !seen.contains(season) {
                seen.insert(season)
                result.append(season)
            }
        }
        return result.sorted()
    }

    public func videos(inSeason season: Int) -> [Video] {
        return videos.filter { $0.season == season }
    }

    /// Sort episodes by (season, episode); videos without series info keep their relative order after them.
    static func sortedVideos(_ videos: [Video]) -> [Video] {
        let hasSeriesInfo = videos.contains(where: { $0.isEpisode })
        guard hasSeriesInfo else { return videos }
        let indexed = videos.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            let l = lhs.1
            let r = rhs.1
            let ls = l.season ?? Int.max
            let rs = r.season ?? Int.max
            if ls != rs { return ls < rs }
            let le = l.episode ?? Int.max
            let re = r.episode ?? Int.max
            if le != re { return le < re }
            return lhs.0 < rhs.0
        }
        return sorted.map { $0.1 }
    }

    /// Fills empty fields of `self` from `other` (used to merge metadata from several addons).
    public func merging(fallback other: MetaItem) -> MetaItem {
        var result = self
        if result.poster == nil { result.poster = other.poster }
        if result.background == nil { result.background = other.background }
        if result.logo == nil { result.logo = other.logo }
        if result.description == nil || result.description?.isEmpty == true { result.description = other.description }
        if result.releaseInfo == nil { result.releaseInfo = other.releaseInfo }
        if result.imdbRating == nil { result.imdbRating = other.imdbRating }
        if result.released == nil { result.released = other.released }
        if result.runtime == nil { result.runtime = other.runtime }
        if result.genres.isEmpty { result.genres = other.genres }
        if result.cast.isEmpty { result.cast = other.cast }
        if result.directors.isEmpty { result.directors = other.directors }
        if result.writers.isEmpty { result.writers = other.writers }
        if result.language == nil { result.language = other.language }
        if result.country == nil { result.country = other.country }
        if result.awards == nil { result.awards = other.awards }
        if result.website == nil { result.website = other.website }
        if result.trailers.isEmpty { result.trailers = other.trailers }
        if result.links.isEmpty { result.links = other.links }
        if result.videos.isEmpty { result.videos = other.videos }
        return result
    }
}
