import Foundation

/// Client of fanart.tv (API v3) with the user's own API key. It only fetches the transparent logo of a film or a series, which the
/// player shows while a source is being prepared. The key is read from a provider on every call, is never stored here and
/// appears in no error: every failure simply means "no logo" (the player then shows the title).
public struct FanartClient: Sendable {
    public static let productionBaseURL = URL(string: "https://webservice.fanart.tv/v3")!
    public static let productionHost = "webservice.fanart.tv"

    public typealias CredentialProvider = @Sendable () -> String?

    public enum Kind: String, Sendable {
        /// Films are looked up by their TMDB or IMDb id.
        case movie = "movies"
        /// Series are looked up by their TheTVDB id.
        case tv = "tv"
    }

    private let http: HTTPClient
    private let credentials: CredentialProvider
    private let baseURL: URL
    private let timeout: TimeInterval

    public init(http: HTTPClient, credentials: @escaping CredentialProvider,
                baseURL: URL = FanartClient.productionBaseURL, timeout: TimeInterval = 8) {
        self.http = http
        self.credentials = credentials
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// Whether a key is stored (it does not say the service accepts it).
    public var isConfigured: Bool {
        return !(credentials() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The best logo of the title, in the viewer's language when there is one, else English, else the best liked.
    /// Nil without a key, for an unknown title, or on any failure.
    public func logoURL(kind: Kind, id: String, language: String) async -> URL? {
        guard MetadataHTTP.isTrusted(baseURL, productionHost: FanartClient.productionHost) else { return nil }
        let key = (credentials() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        guard var components = URLComponents(string: baseURL.absoluteString + "/\(kind.rawValue)/\(id)") else { return nil }
        components.queryItems = [URLQueryItem(name: "api_key", value: key)]
        guard let url = components.url else { return nil }
        guard let response = try? await MetadataHTTP.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: timeout), using: http),
              response.isSuccess,
              let images = try? JSONDecoder().decode(FanartImages.self, from: response.data) else { return nil }
        return FanartClient.bestLogo(images.logos, language: language)
    }

    static func bestLogo(_ logos: [FanartImage], language: String) -> URL? {
        let wanted = String(language.prefix(2)).lowercased()
        func rank(_ logo: FanartImage) -> (tier: Int, likes: Int) {
            let lang = (logo.lang ?? "").lowercased()
            let tier = lang == wanted ? 0 : (lang == "en" ? 1 : 2)
            return (tier, -logo.likes)
        }
        let ordered = logos.sorted { first, second in
            let a = rank(first)
            let b = rank(second)
            if a.tier != b.tier { return a.tier < b.tier }
            return a.likes < b.likes
        }
        for logo in ordered {
            guard let raw = logo.url, let url = URL(string: raw), url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(), host == "fanart.tv" || host.hasSuffix(".fanart.tv") else { continue }
            return url
        }
        return nil
    }
}

struct FanartImage: Decodable {
    var url: String?
    var lang: String?
    var likes: Int
    private enum CodingKeys: String, CodingKey { case url, lang, likes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.flexString(.url)
        lang = c.flexString(.lang)
        likes = c.flexInt(.likes) ?? 0
    }
}

struct FanartImages: Decodable {
    var logos: [FanartImage]
    private enum CodingKeys: String, CodingKey { case hdmovielogo, movielogo, hdtvlogo, clearlogo }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hdMovie = c.lossyArray(FanartImage.self, forKey: .hdmovielogo)
        let hdTV = c.lossyArray(FanartImage.self, forKey: .hdtvlogo)
        let movie = c.lossyArray(FanartImage.self, forKey: .movielogo)
        let clear = c.lossyArray(FanartImage.self, forKey: .clearlogo)
        logos = hdMovie + hdTV + movie + clear
    }
}
