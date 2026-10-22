import Foundation

/// Everything the title page shows beyond what an addon's meta carries, read from TMDB with the user's own key: the cast with their
/// photos and roles, who produced it, what it cost and earned (films only), the trailers, the facts table and similar titles.
///
/// Every field is optional or may be empty: a section that has nothing to show is not shown. Image addresses are complete and
/// point at TMDB's image host only.
public struct TitleRichDetails: Codable, Equatable, Sendable {
    public struct Person: Codable, Equatable, Sendable {
        public var name: String
        /// The character, for an actor.
        public var role: String?
        public var photoURL: String?
    }

    public struct Company: Codable, Equatable, Sendable {
        public var name: String
        public var logoURL: String?
    }

    public struct Trailer: Codable, Equatable, Sendable {
        /// The YouTube video id, only ever letters, digits, `-` and `_`.
        public var key: String
        public var name: String
        /// "Trailer" or "Teaser".
        public var type: String
        public var language: String?
        public var isOfficial: Bool

        public var watchURL: URL? { return URL(string: "https://www.youtube.com/watch?v=\(key)") }
    }

    public struct Similar: Codable, Equatable, Sendable {
        public var tmdbID: Int
        public var title: String
        public var posterURL: String?
        public var year: String?
        public var rating: Double?
    }

    /// One line of the facts table.
    public struct Row: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    public var tmdbID: Int
    public var isMovie: Bool
    public var cast: [Person]
    /// Directors of a film.
    public var directors: [String]
    /// Creators of a series.
    public var creators: [String]
    public var companies: [Company]
    /// US dollars; only ever set for a film, and only when TMDB knows a figure.
    public var budget: Int?
    public var revenue: Int?
    public var trailers: [Trailer]
    public var similar: [Similar]
    /// TMDB's own status text ("Released", "Returning Series"…).
    public var status: String?
    /// "yyyy-MM-dd".
    public var releaseDate: String?
    public var lastAirDate: String?
    public var runtimeMinutes: Int?
    public var certification: String?
    public var countries: [String]
    /// ISO 639-1 code.
    public var originalLanguage: String?
    public var seasonCount: Int?
    public var episodeCount: Int?
    public var imdbID: String?

    public var isEmpty: Bool {
        return cast.isEmpty && directors.isEmpty && creators.isEmpty && companies.isEmpty && budget == nil && revenue == nil
            && trailers.isEmpty && similar.isEmpty && detailRows().isEmpty
    }

    // MARK: Facts table

    /// Status, release, length, rating, country and original language, in Italian. A row with nothing to say is left out.
    public func detailRows(locale: Locale = Locale(identifier: "it_IT")) -> [Row] {
        var rows: [Row] = []
        if let status = TitleRichDetails.statusText(status, isMovie: isMovie) { rows.append(Row(label: "Stato", value: status)) }
        if let release = TitleRichDetails.releaseText(first: releaseDate, last: lastAirDate, isMovie: isMovie, ended: status, locale: locale) {
            rows.append(Row(label: "Info rilascio", value: release))
        }
        if let minutes = runtimeMinutes, minutes > 0 { rows.append(Row(label: "Durata", value: TitleRichDetails.runtimeText(minutes))) }
        if !isMovie, let seasons = seasonCount, seasons > 0 {
            var text = seasons == 1 ? "1 stagione" : "\(seasons) stagioni"
            if let episodes = episodeCount, episodes > 0 { text += " · " + (episodes == 1 ? "1 episodio" : "\(episodes) episodi") }
            rows.append(Row(label: "Stagioni", value: text))
        }
        if let certification = certification, !certification.isEmpty { rows.append(Row(label: "Certificazione", value: certification)) }
        if !countries.isEmpty { rows.append(Row(label: countries.count > 1 ? "Paesi" : "Paese", value: countries.joined(separator: ", "))) }
        if let code = originalLanguage, !code.isEmpty, code != "xx", code != "cn" {
            rows.append(Row(label: "Lingua originale", value: LanguageCodes.displayName(code, locale: locale)))
        } else if originalLanguage == "cn" {
            rows.append(Row(label: "Lingua originale", value: LanguageCodes.displayName("yue", locale: locale)))
        }
        return rows
    }

    static func statusText(_ raw: String?, isMovie: Bool) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "released": return "Uscito"
        case "post production": return "In post-produzione"
        case "in production": return "In produzione"
        case "planned": return "Pianificato"
        case "rumored": return "Solo voci"
        case "returning series": return "In corso"
        case "ended": return "Conclusa"
        case "canceled", "cancelled": return isMovie ? "Cancellato" : "Cancellata"
        case "pilot": return "Episodio pilota"
        default: return raw
        }
    }

    /// "2 h 14 min", "2 h", "45 min".
    static func runtimeText(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private static func parseDay(_ raw: String?) -> Date? {
        guard let raw = raw, raw.count >= 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(raw.prefix(10)))
    }

    private static func longDay(_ date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// A film: the day it came out. A series: the day it started, and the day of the last episode once it has ended.
    static func releaseText(first: String?, last: String?, isMovie: Bool, ended status: String?, locale: Locale) -> String? {
        guard let start = parseDay(first) else { return nil }
        let startText = longDay(start, locale: locale)
        if isMovie { return startText }
        let isOver = ["ended", "canceled", "cancelled"].contains((status ?? "").lowercased())
        if isOver, let end = parseDay(last), end != start { return "\(startText) – \(longDay(end, locale: locale))" }
        return "Dal \(startText)"
    }

    /// "150.000.000 $": whole dollars with dots between the thousands, the way Italian prints them (no locale data involved).
    public static func moneyText(_ dollars: Int) -> String {
        let digits = String(abs(dollars))
        var grouped = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { grouped.append(".") }
            grouped.append(character)
        }
        return (dollars < 0 ? "-" : "") + String(grouped.reversed()) + " $"
    }

    // MARK: Building

    /// YouTube ids are 11 characters of `[A-Za-z0-9_-]`; anything else is not put into an address.
    static func isSafeVideoKey(_ key: String) -> Bool {
        guard (6...20).contains(key.utf8.count) else { return false }
        return key.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }
    }

    static func trailers(from videos: [TMDBVideo], language: String) -> [Trailer] {
        let wanted = String(language.prefix(2)).lowercased()
        var seen = Set<String>()
        let usable: [Trailer] = videos.compactMap { video in
            guard (video.site ?? "").lowercased() == "youtube", let key = video.key, isSafeVideoKey(key),
                  let type = video.type, ["trailer", "teaser"].contains(type.lowercased()), seen.insert(key).inserted else { return nil }
            let name = (video.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Trailer(key: key, name: name.isEmpty ? type : name, type: type.capitalized,
                           language: video.language?.lowercased(), isOfficial: video.official ?? false)
        }
        func published(_ key: String) -> String {
            return videos.first { $0.key == key }?.publishedAt ?? ""
        }
        func languageRank(_ trailer: Trailer) -> Int {
            if trailer.language == wanted { return 0 }
            if trailer.language == "en" { return 1 }
            if trailer.language == nil || trailer.language == "" { return 2 }
            return 3
        }
        let sorted = usable.sorted { lhs, rhs in
            let leftType = lhs.type == "Trailer" ? 0 : 1, rightType = rhs.type == "Trailer" ? 0 : 1
            if leftType != rightType { return leftType < rightType }
            let leftLanguage = languageRank(lhs), rightLanguage = languageRank(rhs)
            if leftLanguage != rightLanguage { return leftLanguage < rightLanguage }
            if lhs.isOfficial != rhs.isOfficial { return lhs.isOfficial }
            return published(lhs.key) > published(rhs.key)
        }
        return Array(sorted.prefix(8))
    }

    /// The rating of the first country in `regions` that has one. A rating from another country than the first is marked with it.
    static func certification(movie: TMDBReleaseDates?, series: TMDBContentRatings?, regions: [String]) -> String? {
        for (index, region) in regions.enumerated() {
            var found: String?
            if let movie = movie, let entry = movie.results.first(where: { ($0.region ?? "").uppercased() == region }) {
                // Theatrical (3) first, then whatever else was rated.
                found = entry.certifications.first(where: { $0.type == 3 })?.certification ?? entry.certifications.first?.certification
            }
            if found == nil, let series = series {
                found = series.results.first(where: { ($0.region ?? "").uppercased() == region })?.rating
            }
            if let text = found { return index == 0 ? text : "\(text) (\(region))" }
        }
        return nil
    }

    /// The countries to try for a rating: the one in the language tag ("it-IT"), then Italy, the USA and Britain.
    static func ratingRegions(language: String) -> [String] {
        var regions: [String] = []
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-")
        if parts.count > 1, let region = parts.last, region.count == 2 { regions.append(region.uppercased()) }
        for fallback in ["IT", "US", "GB"] where !regions.contains(fallback) { regions.append(fallback) }
        return regions
    }

    static func make(from details: TMDBRichDetails, tmdbID: Int, isMovie: Bool, configuration: TMDBImageConfiguration,
                     language: String, locale: Locale = Locale(identifier: "it_IT")) -> TitleRichDetails {
        func image(_ sizes: [String], _ minimum: Int, _ path: String?) -> String? {
            return MetadataEnricher.imageURL(configuration, sizes: sizes, minimum: minimum, path: path)
        }
        func logo(_ path: String?) -> String? {
            // Vector logos cannot be drawn by the app's image pipeline.
            guard let path = path, !path.lowercased().hasSuffix(".svg") else { return nil }
            return image(configuration.logoSizes, 185, path)
        }

        var cast: [Person] = []
        var directors: [String] = []
        if let credits = details.credits {
            let ordered = credits.cast.sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            var seen = Set<String>()
            for member in ordered {
                guard let name = member.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                // The same person can be listed for more than one role: the first (leading) entry is kept.
                guard seen.insert(member.id.map(String.init) ?? name).inserted else { continue }
                let role = member.character?.trimmingCharacters(in: .whitespacesAndNewlines)
                cast.append(Person(name: name, role: (role ?? "").isEmpty ? nil : role,
                                   photoURL: image(configuration.profileSizes, 185, member.profilePath)))
                if cast.count >= 24 { break }
            }
            if isMovie {
                var seenDirectors = Set<String>()
                directors = credits.crew.filter { $0.job == "Director" }.compactMap { $0.name }.filter { !$0.isEmpty && seenDirectors.insert($0).inserted }
            }
        }
        let creators = isMovie ? [] : details.createdBy.compactMap { $0.name }.filter { !$0.isEmpty }

        var companies: [Company] = []
        var seenCompanies = Set<String>()
        // A series is also known by the channels that carry it, a film only by who produced it.
        for company in (isMovie ? [] : details.networks) + details.companies {
            guard let name = company.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, seenCompanies.insert(name).inserted else { continue }
            companies.append(Company(name: name, logoURL: logo(company.logoPath)))
            if companies.count >= 12 { break }
        }

        let countryNames: [String]
        if !details.productionCountries.isEmpty {
            countryNames = details.productionCountries.compactMap { country in
                if let code = country.code, let local = locale.localizedString(forRegionCode: code), !local.isEmpty { return local }
                return country.name
            }
        } else {
            countryNames = details.originCountry.compactMap { locale.localizedString(forRegionCode: $0) }
        }

        let regions = ratingRegions(language: language)
        let runtime = isMovie ? details.runtime : details.episodeRunTime.first(where: { $0 > 0 })

        return TitleRichDetails(
            tmdbID: tmdbID, isMovie: isMovie, cast: cast, directors: directors, creators: creators, companies: companies,
            budget: isMovie ? details.budget.flatMap { $0 > 0 ? $0 : nil } : nil,
            revenue: isMovie ? details.revenue.flatMap { $0 > 0 ? $0 : nil } : nil,
            trailers: trailers(from: details.videos?.results ?? [], language: language),
            similar: (details.similar?.results ?? []).compactMap { item -> Similar? in
                guard let id = item.id, let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
                return Similar(tmdbID: id, title: title, posterURL: image(configuration.posterSizes, 342, item.posterPath),
                               year: MetadataEnricher.year(from: item.date),
                               rating: item.voteAverage.flatMap { $0 > 0 ? $0 : nil })
            }.prefix(20).map { $0 },
            status: details.status, releaseDate: details.releaseDate, lastAirDate: details.lastAirDate,
            runtimeMinutes: runtime.flatMap { $0 > 0 ? $0 : nil },
            certification: certification(movie: isMovie ? details.releaseDates : nil, series: isMovie ? nil : details.contentRatings, regions: regions),
            countries: countryNames, originalLanguage: details.originalLanguage?.lowercased(),
            seasonCount: isMovie ? nil : details.seasonCount, episodeCount: isMovie ? nil : details.episodeCount,
            imdbID: details.externalIDs?.imdbID)
    }
}
