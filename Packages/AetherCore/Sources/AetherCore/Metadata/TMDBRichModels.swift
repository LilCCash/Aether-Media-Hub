import Foundation

// Tolerant models of the extra fields the title page reads (`append_to_response=credits,videos,similar,…`). As with the models
// next to them every field is optional: a title page is built from whatever TMDB happens to know.

typealias TMDBNamed = TMDBGenre

struct TMDBCompany: Decodable {
    var name: String?
    var logoPath: String?
    var originCountry: String?
    private enum CodingKeys: String, CodingKey { case name, logo_path, origin_country }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        logoPath = c.flexString(.logo_path)
        originCountry = c.flexString(.origin_country)
    }
}

struct TMDBCountry: Decodable {
    var code: String?
    var name: String?
    private enum CodingKeys: String, CodingKey { case iso_3166_1, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.flexString(.iso_3166_1)
        name = c.flexString(.name)
    }
}

struct TMDBVideo: Decodable {
    var key: String?
    var site: String?
    var type: String?
    var name: String?
    var official: Bool?
    var language: String?
    var publishedAt: String?
    private enum CodingKeys: String, CodingKey { case key, site, type, name, official, iso_639_1, published_at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.flexString(.key)
        site = c.flexString(.site)
        type = c.flexString(.type)
        name = c.flexString(.name)
        official = c.flexBool(.official)
        language = c.flexString(.iso_639_1)
        publishedAt = c.flexString(.published_at)
    }
}

struct TMDBVideos: Decodable {
    var results: [TMDBVideo]
    private enum CodingKeys: String, CodingKey { case results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lossyArray(TMDBVideo.self, forKey: .results)
    }
}

struct TMDBSimilarItem: Decodable {
    var id: Int?
    var title: String?
    var posterPath: String?
    var voteAverage: Double?
    var date: String?
    var genreIDs: [Int]
    private enum CodingKeys: String, CodingKey { case id, title, name, poster_path, vote_average, release_date, first_air_date, genre_ids }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        title = c.flexString(.title) ?? c.flexString(.name)
        posterPath = c.flexString(.poster_path)
        voteAverage = c.flexString(.vote_average).flatMap { Double($0) }
        date = c.flexString(.release_date) ?? c.flexString(.first_air_date)
        genreIDs = (try? c.decodeIfPresent([Int].self, forKey: .genre_ids)) ?? []
    }
}

struct TMDBSimilar: Decodable {
    var results: [TMDBSimilarItem]
    private enum CodingKeys: String, CodingKey { case results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lossyArray(TMDBSimilarItem.self, forKey: .results)
    }
}

/// One entry of a movie's `release_dates`: the rating a country gave it.
struct TMDBRegionRelease: Decodable {
    var region: String?
    var certifications: [(type: Int?, certification: String)]

    private enum CodingKeys: String, CodingKey { case iso_3166_1, release_dates }
    private struct Entry: Decodable {
        var type: Int?
        var certification: String?
        private enum CodingKeys: String, CodingKey { case type, certification }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.flexInt(.type)
            certification = c.flexString(.certification)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = c.flexString(.iso_3166_1)
        certifications = c.lossyArray(Entry.self, forKey: .release_dates).compactMap { entry in
            guard let text = entry.certification?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return (entry.type, text)
        }
    }
}

struct TMDBReleaseDates: Decodable {
    var results: [TMDBRegionRelease]
    private enum CodingKeys: String, CodingKey { case results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lossyArray(TMDBRegionRelease.self, forKey: .results)
    }
}

/// One entry of a series' `content_ratings`.
struct TMDBContentRating: Decodable {
    var region: String?
    var rating: String?
    private enum CodingKeys: String, CodingKey { case iso_3166_1, rating }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        region = c.flexString(.iso_3166_1)
        rating = c.flexString(.rating).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct TMDBContentRatings: Decodable {
    var results: [TMDBContentRating]
    private enum CodingKeys: String, CodingKey { case results }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lossyArray(TMDBContentRating.self, forKey: .results)
    }
}

/// `/3/movie/{id}` and `/3/tv/{id}` with everything the title page shows appended.
struct TMDBRichDetails: Decodable {
    var id: Int?
    var status: String?
    var releaseDate: String?
    var lastAirDate: String?
    var runtime: Int?
    var episodeRunTime: [Int]
    var originalLanguage: String?
    var productionCountries: [TMDBCountry]
    var originCountry: [String]
    var companies: [TMDBCompany]
    var networks: [TMDBCompany]
    var createdBy: [TMDBNamed]
    var budget: Int?
    var revenue: Int?
    var seasonCount: Int?
    var episodeCount: Int?
    var voteAverage: Double?
    var voteCount: Int?
    var credits: TMDBCredits?
    var videos: TMDBVideos?
    var similar: TMDBSimilar?
    var releaseDates: TMDBReleaseDates?
    var contentRatings: TMDBContentRatings?
    var externalIDs: TMDBExternalIDs?
    var collection: TMDBCollectionRef?

    private enum CodingKeys: String, CodingKey {
        case belongs_to_collection
        case id, status, release_date, first_air_date, last_air_date, runtime, episode_run_time, original_language
        case production_countries, origin_country, production_companies, networks, created_by, budget, revenue
        case number_of_seasons, number_of_episodes, vote_average, vote_count
        case credits, videos, similar, release_dates, content_ratings, external_ids
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        status = c.flexString(.status)
        releaseDate = c.flexString(.release_date) ?? c.flexString(.first_air_date)
        lastAirDate = c.flexString(.last_air_date)
        runtime = c.flexInt(.runtime)
        episodeRunTime = c.lossyArray(FlexInt.self, forKey: .episode_run_time).compactMap { $0.value }
        originalLanguage = c.flexString(.original_language)
        productionCountries = c.lossyArray(TMDBCountry.self, forKey: .production_countries)
        originCountry = c.stringList(.origin_country)
        companies = c.lossyArray(TMDBCompany.self, forKey: .production_companies)
        networks = c.lossyArray(TMDBCompany.self, forKey: .networks)
        createdBy = c.lossyArray(TMDBNamed.self, forKey: .created_by)
        budget = c.flexInt(.budget)
        revenue = c.flexInt(.revenue)
        seasonCount = c.flexInt(.number_of_seasons)
        episodeCount = c.flexInt(.number_of_episodes)
        voteAverage = c.flexString(.vote_average).flatMap { Double($0) }
        voteCount = c.flexInt(.vote_count)
        credits = c.lenient(TMDBCredits.self, forKey: .credits)
        videos = c.lenient(TMDBVideos.self, forKey: .videos)
        similar = c.lenient(TMDBSimilar.self, forKey: .similar)
        releaseDates = c.lenient(TMDBReleaseDates.self, forKey: .release_dates)
        contentRatings = c.lenient(TMDBContentRatings.self, forKey: .content_ratings)
        externalIDs = c.lenient(TMDBExternalIDs.self, forKey: .external_ids)
        collection = c.lenient(TMDBCollectionRef.self, forKey: .belongs_to_collection)
    }
}

/// The saga a film belongs to, as the film's own details name it.
struct TMDBCollectionRef: Decodable {
    var id: Int?
    var name: String?
    private enum CodingKeys: String, CodingKey { case id, name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        name = c.flexString(.name)
    }
}

struct TMDBCollectionPart: Decodable {
    var id: Int?
    var title: String?
    var posterPath: String?
    var releaseDate: String?
    var voteAverage: Double?
    private enum CodingKeys: String, CodingKey { case id, title, poster_path, release_date, vote_average }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        title = c.flexString(.title)
        posterPath = c.flexString(.poster_path)
        releaseDate = c.flexString(.release_date)
        voteAverage = c.flexString(.vote_average).flatMap { Double($0) }
    }
}

struct TMDBCollection: Decodable {
    var name: String?
    var parts: [TMDBCollectionPart]
    private enum CodingKeys: String, CodingKey { case name, parts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexString(.name)
        parts = c.lossyArray(TMDBCollectionPart.self, forKey: .parts)
    }
}

/// One line of a person's `combined_credits` (a film or a series with the character played).
struct TMDBPersonCreditEntry: Decodable {
    var id: Int?
    var mediaType: String?
    var title: String?
    var character: String?
    var posterPath: String?
    var releaseDate: String?
    var popularity: Double?
    var genreIDs: [Int]
    private enum CodingKeys: String, CodingKey { case id, media_type, title, name, character, poster_path, release_date, first_air_date, popularity, genre_ids }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.flexInt(.id)
        mediaType = c.flexString(.media_type)
        title = c.flexString(.title) ?? c.flexString(.name)
        character = c.flexString(.character)
        posterPath = c.flexString(.poster_path)
        releaseDate = c.flexString(.release_date) ?? c.flexString(.first_air_date)
        popularity = try? c.decodeIfPresent(Double.self, forKey: .popularity)
        genreIDs = (try? c.decodeIfPresent([Int].self, forKey: .genre_ids)) ?? []
    }
}

struct TMDBPersonCredits: Decodable {
    var cast: [TMDBPersonCreditEntry]
    private enum CodingKeys: String, CodingKey { case cast }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cast = c.lossyArray(TMDBPersonCreditEntry.self, forKey: .cast)
    }
}
