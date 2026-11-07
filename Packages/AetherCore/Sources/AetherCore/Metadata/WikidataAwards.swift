import Foundation

/// An award a person received, as Wikidata (the open knowledge base behind Wikipedia) states it.
public struct PersonAward: Equatable, Hashable, Identifiable, Sendable {
    public var title: String
    public var year: Int?
    public var id: String { return title + "\(year ?? 0)" }
    public var line: String { return year.map { "\(title) (\($0))" } ?? title }
}

/// Awards from Wikidata: no key, no account. Two small requests (the person's statements «award received», then the names of those
/// awards in Italian or English). Any failure gives an empty list: the page just has no awards section.
public struct WikidataClient: Sendable {
    private let http: HTTPClient
    static let host = "www.wikidata.org"

    public init(http: HTTPClient) { self.http = http }

    public func awards(wikidataID: String, language: String, limit: Int = 14) async -> [PersonAward] {
        guard wikidataID.range(of: "^Q[0-9]{1,12}$", options: .regularExpression) != nil else { return [] }
        guard let claims = await fetch(["action": "wbgetentities", "ids": wikidataID, "props": "claims", "format": "json"]) else { return [] }
        let found = Self.awardClaims(claims, personID: wikidataID)
        guard !found.isEmpty else { return [] }
        let ids = Array(Set(found.map { $0.id })).prefix(50)
        let languages = language.hasPrefix("it") ? "it|en" : "en|it"
        guard let labels = await fetch(["action": "wbgetentities", "ids": ids.joined(separator: "|"), "props": "labels", "languages": languages, "format": "json"]) else { return [] }
        return Self.awards(from: found, labels: labels, preferring: language.hasPrefix("it") ? ["it", "en"] : ["en", "it"], limit: limit)
    }

    private func fetch(_ query: [String: String]) async -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = "/w/api.php"
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        let request = HTTPRequest(url: url, headers: ["Accept": "application/json", "User-Agent": "Aether/1.5 (media hub; personal use)"], timeout: 15, maxBytes: 6 * 1024 * 1024)
        guard let response = try? await MetadataHTTP.send(request, using: http), response.isSuccess else { return nil }
        return response.data
    }

    /// The «award received» (P166) statements: the award's entity id and, when there is one, the year of the «point in time» (P585).
    static func awardClaims(_ data: Data, personID: String) -> [(id: String, year: Int?)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = root["entities"] as? [String: Any], let person = entities[personID] as? [String: Any],
              let claims = person["claims"] as? [String: Any], let list = claims["P166"] as? [[String: Any]] else { return [] }
        var result: [(String, Int?)] = []
        for claim in list {
            guard let snak = claim["mainsnak"] as? [String: Any], let value = (snak["datavalue"] as? [String: Any])?["value"] as? [String: Any],
                  let id = value["id"] as? String, id.range(of: "^Q[0-9]{1,12}$", options: .regularExpression) != nil else { continue }
            var year: Int?
            if let times = (claim["qualifiers"] as? [String: Any])?["P585"] as? [[String: Any]],
               let time = (times.first?["datavalue"] as? [String: Any])?["value"] as? [String: Any], let text = time["time"] as? String {
                // "+2005-02-27T00:00:00Z"
                let digits = text.drop { $0 == "+" || $0 == "-" }.prefix(4)
                year = Int(digits)
            }
            result.append((id, year))
        }
        return result
    }

    static func awards(from claims: [(id: String, year: Int?)], labels data: Data, preferring languages: [String], limit: Int) -> [PersonAward] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entities = root["entities"] as? [String: Any] else { return [] }
        func title(_ id: String) -> String? {
            guard let labels = (entities[id] as? [String: Any])?["labels"] as? [String: Any] else { return nil }
            for language in languages { if let value = (labels[language] as? [String: Any])?["value"] as? String, !value.isEmpty { return value } }
            return nil
        }
        var seen = Set<String>()
        var result: [PersonAward] = []
        for claim in claims {
            guard let name = title(claim.id) else { continue }
            let award = PersonAward(title: name, year: claim.year)
            if seen.insert(award.id).inserted { result.append(award) }
        }
        result.sort { ($0.year ?? 0) != ($1.year ?? 0) ? ($0.year ?? 0) > ($1.year ?? 0) : $0.title < $1.title }
        return Array(result.prefix(limit))
    }
}

/// A person who shares films with another: the ones they appear in together.
public struct PersonCollaborator: Equatable, Identifiable, Sendable {
    public var tmdbID: Int
    public var name: String
    public var photoURL: String?
    public var shared: [String]
    public var id: Int { return tmdbID }
}
