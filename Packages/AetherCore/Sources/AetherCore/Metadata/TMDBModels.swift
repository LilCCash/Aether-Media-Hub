import Foundation

// Tolerant models of the TMDB v3 responses Aether reads. Every field is optional on purpose: TMDB omits or nulls fields
// freely, and an enrichment must never fail because a tagline is missing.

struct TMDBImageConfiguration: Decodable {
    var secureBaseURL: String?
    var posterSizes: [String]
    var backdropSizes: [String]
    var logoSizes: [String]
    var stillSizes: [String]
    var profileSizes: [String]

    private enum CodingKeys: String, CodingKey {
        case secure_base_url, poster_sizes, backdrop_sizes, logo_sizes, still_sizes, profile_sizes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        secureBaseURL = c.flexString(.secure_base_url)
        posterSizes = c.stringList(.poster_sizes)
        backdropSizes = c.stringList(.backdrop_sizes)
        logoSizes = c.stringList(.logo_sizes)
        stillSizes = c.stringList(.still_sizes)
        profileSizes = c.stringList(.profile_sizes)
    }

    init() {
        secureBaseURL = "https://image.tmdb.org/t/p/"
        posterSizes = ["w342", "w500", "original"]
        backdropSizes = ["w780", "w1280", "original"]
        logoSizes = ["w300", "w500", "original"]
        stillSizes = ["w300", "original"]
        profileSizes = ["w185", "h632", "original"]
    }

    /// Picks the smallest size that is at least `minimum` pixels wide ("w500" -> 500), else the largest numbered one, else "original".
    static func pick(_ sizes: [String], atLeast minimum: Int) -> String {
        let numbered = sizes.compactMap { size -> (String, Int)? in
            guard size.hasPrefix("w"), let value = Int(size.dropFirst()) else { return nil }
            return (size, value)
        }.sorted { $0.1 < $1.1 }
        if let fit = numbered.first(where: { $0.1 >= minimum }) { return fit.0 }
        return numbered.last?.0 ?? "original"
    }
}

struct TMDBConfigurationResponse: Decodable {
    var images: TMDBImageConfiguration?

    private enum CodingKeys: String, CodingKey { case images }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = c.lenient(TMDBImageConfiguration.self, forKey: .images)
    }
}

struct TMDBFindResult: Decodable {
    var id: Int?
    private enum CodingKeys: String, CodingKey { case id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
    }
}

struct TMDBFindResponse: Decodable {
    var movieResults: [TMDBFindResult]
    var tvResults: [TMDBFindResult]

    private enum CodingKeys: String, CodingKey { case movie_results, tv_results }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movieResults = c.lossyArray(TMDBFindResult.self, forKey: .movie_results)
        tvResults = c.lossyArray(TMDBFindResult.self, forKey: .tv_results)
    }
}

struct TMDBGenre: Decodable {
    var name: String?
    private enum CodingKeys: String, CodingKey { case name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
    }
}

struct TMDBCastMember: Decodable {
    var id: Int?
    var name: String?
    var character: String?
    var order: Int?
    var profilePath: String?
    private enum CodingKeys: String, CodingKey { case id, name, character, order, profile_path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        name = c.flexString(.name)
        character = c.flexString(.character)
        order = c.flexInt(.order)
        profilePath = c.flexString(.profile_path)
    }
}

struct TMDBCrewMember: Decodable {
    var name: String?
    var job: String?
    private enum CodingKeys: String, CodingKey { case name, job }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        job = c.flexString(.job)
    }
}

struct TMDBCredits: Decodable {
    var cast: [TMDBCastMember]
    var crew: [TMDBCrewMember]
    private enum CodingKeys: String, CodingKey { case cast, crew }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cast = c.lossyArray(TMDBCastMember.self, forKey: .cast)
        crew = c.lossyArray(TMDBCrewMember.self, forKey: .crew)
    }
}

struct TMDBLogo: Decodable {
    var filePath: String?
    var language: String?
    var voteAverage: Double?
    var width: Int?
    private enum CodingKeys: String, CodingKey { case file_path, iso_639_1, vote_average, width }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filePath = c.flexString(.file_path)
        language = c.flexString(.iso_639_1)
        voteAverage = c.flexString(.vote_average).flatMap { Double($0) }
        width = c.flexInt(.width)
    }
}

struct TMDBImages: Decodable {
    var logos: [TMDBLogo]
    private enum CodingKeys: String, CodingKey { case logos }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logos = c.lossyArray(TMDBLogo.self, forKey: .logos)
    }
}

struct TMDBExternalIDs: Decodable {
    var imdbID: String?
    var tvdbID: Int?
    private enum CodingKeys: String, CodingKey { case imdb_id, tvdb_id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imdbID = c.flexString(.imdb_id).flatMap { $0.isEmpty ? nil : $0 }
        tvdbID = c.flexInt(.tvdb_id)
    }
}

/// `/3/movie/{id}` and `/3/tv/{id}` share enough fields to be read by one model.
struct TMDBDetails: Decodable {
    var id: Int?
    var title: String?
    var overview: String?
    var tagline: String?
    var posterPath: String?
    var backdropPath: String?
    var genres: [TMDBGenre]
    var runtime: Int?
    var episodeRunTime: [Int]
    var voteAverage: Double?
    var voteCount: Int?
    var releaseDate: String?
    var credits: TMDBCredits?
    var images: TMDBImages?
    var externalIDs: TMDBExternalIDs?

    private enum CodingKeys: String, CodingKey {
        case id, title, name, overview, tagline, poster_path, backdrop_path, genres, runtime, episode_run_time
        case vote_average, vote_count, release_date, first_air_date, credits, images, external_ids
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        title = c.flexString(.title) ?? c.flexString(.name)
        overview = c.flexString(.overview).flatMap { $0.isEmpty ? nil : $0 }
        tagline = c.flexString(.tagline).flatMap { $0.isEmpty ? nil : $0 }
        posterPath = c.flexString(.poster_path)
        backdropPath = c.flexString(.backdrop_path)
        genres = c.lossyArray(TMDBGenre.self, forKey: .genres)
        runtime = c.flexInt(.runtime)
        episodeRunTime = c.lossyArray(FlexInt.self, forKey: .episode_run_time).compactMap { $0.value }
        voteAverage = c.flexString(.vote_average).flatMap { Double($0) }
        voteCount = c.flexInt(.vote_count)
        releaseDate = c.flexString(.release_date) ?? c.flexString(.first_air_date)
        credits = c.lenient(TMDBCredits.self, forKey: .credits)
        images = c.lenient(TMDBImages.self, forKey: .images)
        externalIDs = c.lenient(TMDBExternalIDs.self, forKey: .external_ids)
    }
}

struct TMDBEpisode: Decodable {
    var number: Int?
    var season: Int?
    var name: String?
    var overview: String?
    var stillPath: String?
    var airDate: String?
    var runtime: Int?
    private enum CodingKeys: String, CodingKey { case episode_number, season_number, name, overview, still_path, air_date, runtime }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = c.flexInt(.episode_number)
        season = c.flexInt(.season_number)
        name = c.flexString(.name)
        overview = c.flexString(.overview).flatMap { $0.isEmpty ? nil : $0 }
        stillPath = c.flexString(.still_path)
        airDate = c.flexString(.air_date)
        runtime = c.flexInt(.runtime)
    }
}

struct TMDBSeason: Decodable {
    var episodes: [TMDBEpisode]
    private enum CodingKeys: String, CodingKey { case episodes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = c.lossyArray(TMDBEpisode.self, forKey: .episodes)
    }
}

/// TMDB's error body: `{"status_code":7,"status_message":"Invalid API key: …","success":false}`.
struct TMDBErrorBody: Decodable {
    var statusCode: Int?
    var statusMessage: String?
    private enum CodingKeys: String, CodingKey { case status_code, status_message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = c.flexInt(.status_code)
        statusMessage = c.flexString(.status_message)
    }
}
