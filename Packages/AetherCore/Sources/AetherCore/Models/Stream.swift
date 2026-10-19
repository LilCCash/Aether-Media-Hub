import Foundation

/// Where a stream's bytes come from. Mirrors `StreamSource` in stremio-core (types/resource/stream.rs).
/// `Foundation.Stream` exists, hence the `Addon` prefix on the public stream type.
public enum StreamSource: Hashable, Sendable {
    /// Direct link (http/https/ftp/rtmp…).
    case url(String)
    case youtube(String)
    case torrent(infoHash: String, fileIndex: Int?, trackers: [String])
    /// Page to open in a browser / another app.
    case external(String)
    case playerFrame(String)
    /// nzb / rar / zip / 7zip / tgz / tar — require the Stremio streaming server.
    case archive(kind: String)
    case unknown
}

public struct StreamBehaviorHints: Hashable, Sendable {
    public var notWebReady: Bool
    public var bingeGroup: String?
    public var countryWhitelist: [String]
    public var proxyRequestHeaders: [String: String]
    public var proxyResponseHeaders: [String: String]
    public var videoHash: String?
    public var videoSize: Int64?
    public var filename: String?

    public init(notWebReady: Bool = false, bingeGroup: String? = nil, countryWhitelist: [String] = [],
                proxyRequestHeaders: [String: String] = [:], proxyResponseHeaders: [String: String] = [:],
                videoHash: String? = nil, videoSize: Int64? = nil, filename: String? = nil) {
        self.notWebReady = notWebReady
        self.bingeGroup = bingeGroup
        self.countryWhitelist = countryWhitelist
        self.proxyRequestHeaders = proxyRequestHeaders
        self.proxyResponseHeaders = proxyResponseHeaders
        self.videoHash = videoHash
        self.videoSize = videoSize
        self.filename = filename
    }
}

extension StreamBehaviorHints: Codable {
    private enum CodingKeys: String, CodingKey {
        case notWebReady, bingeGroup, countryWhitelist, proxyHeaders, videoHash, videoSize, filename
    }

    private enum ProxyKeys: String, CodingKey { case request, response }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.notWebReady = container.flexBool(.notWebReady) ?? false
        self.bingeGroup = container.flexString(.bingeGroup)
        self.countryWhitelist = container.stringList(.countryWhitelist)
        var requestHeaders: [String: String] = [:]
        var responseHeaders: [String: String] = [:]
        if let proxy = try? container.nestedContainer(keyedBy: ProxyKeys.self, forKey: .proxyHeaders) {
            requestHeaders = StreamBehaviorHints.headers(from: proxy, key: .request)
            responseHeaders = StreamBehaviorHints.headers(from: proxy, key: .response)
        }
        self.proxyRequestHeaders = requestHeaders
        self.proxyResponseHeaders = responseHeaders
        self.videoHash = container.flexString(.videoHash)
        if let sizeString = container.flexString(.videoSize) {
            self.videoSize = Int64(sizeString)
        } else {
            self.videoSize = nil
        }
        self.filename = container.flexString(.filename)
    }

    private static func headers(from container: KeyedDecodingContainer<ProxyKeys>, key: ProxyKeys) -> [String: String] {
        guard let raw = try? container.decodeIfPresent([String: FlexString].self, forKey: key) else {
            return [:]
        }
        var result: [String: String] = [:]
        for (name, value) in raw {
            if let string = value.value { result[name] = string }
        }
        return result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if notWebReady { try container.encode(true, forKey: .notWebReady) }
        try container.encodeIfPresent(bingeGroup, forKey: .bingeGroup)
        if !countryWhitelist.isEmpty { try container.encode(countryWhitelist, forKey: .countryWhitelist) }
        if !proxyRequestHeaders.isEmpty || !proxyResponseHeaders.isEmpty {
            var proxy = container.nestedContainer(keyedBy: ProxyKeys.self, forKey: .proxyHeaders)
            if !proxyRequestHeaders.isEmpty { try proxy.encode(proxyRequestHeaders, forKey: .request) }
            if !proxyResponseHeaders.isEmpty { try proxy.encode(proxyResponseHeaders, forKey: .response) }
        }
        try container.encodeIfPresent(videoHash, forKey: .videoHash)
        try container.encodeIfPresent(videoSize, forKey: .videoSize)
        try container.encodeIfPresent(filename, forKey: .filename)
    }
}

/// Subtitle track offered by an addon (`subtitles` resource or `stream.subtitles`).
public struct AddonSubtitle: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var url: String
    public var lang: String
    public var label: String?
    /// Annotated by the service layer, never decoded from JSON.
    public var addonName: String?

    public init(id: String, url: String, lang: String, label: String? = nil, addonName: String? = nil) {
        self.id = id
        self.url = url
        self.lang = lang
        self.label = label
        self.addonName = addonName
    }

    private enum CodingKeys: String, CodingKey { case id, url, lang, label }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = container.flexString(.url), !url.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.url,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "subtitle url"))
        }
        self.url = url
        self.lang = container.flexString(.lang) ?? "und"
        self.id = container.flexString(.id) ?? url
        self.label = container.flexString(.label)
        self.addonName = nil
    }
}

/// One playable (or not) option returned by a `stream` resource.
public struct AddonStream: Hashable, Identifiable, Sendable {
    public var source: StreamSource
    public var name: String?
    public var details: String?
    public var thumbnail: String?
    public var subtitles: [AddonSubtitle]
    public var behaviorHints: StreamBehaviorHints
    /// Annotated by the aggregator, never decoded from JSON.
    public var addonID: String?
    public var addonName: String?

    public init(source: StreamSource, name: String? = nil, details: String? = nil, thumbnail: String? = nil,
                subtitles: [AddonSubtitle] = [], behaviorHints: StreamBehaviorHints = StreamBehaviorHints(),
                addonID: String? = nil, addonName: String? = nil) {
        self.source = source
        self.name = name
        self.details = details
        self.thumbnail = thumbnail
        self.subtitles = subtitles
        self.behaviorHints = behaviorHints
        self.addonID = addonID
        self.addonName = addonName
    }

    /// Stable within one result list; includes the addon so identical URLs from different addons stay distinct.
    public var id: String {
        return "\(addonID ?? "")|\(AddonStream.sourceKey(source))|\(name ?? "")|\(details ?? "")"
    }

    public static func sourceKey(_ source: StreamSource) -> String {
        switch source {
        case .url(let url): return "url:\(url)"
        case .youtube(let id): return "yt:\(id)"
        case .torrent(let hash, let index, _): return "bt:\(hash.lowercased()):\(index.map(String.init) ?? "-")"
        case .external(let url): return "ext:\(url)"
        case .playerFrame(let url): return "frame:\(url)"
        case .archive(let kind): return "archive:\(kind)"
        case .unknown: return "unknown"
        }
    }

    /// Direct http(s) URL if this stream is a plain link.
    public var directURL: URL? {
        if case .url(let string) = source { return URL.lenient(string) }
        return nil
    }

    public var displayTitle: String {
        let parts = [name, details].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }

    /// Text scanned by the analyzer: name + description + filename + URL last path component.
    public var searchableText: String {
        var parts: [String] = []
        if let name = name { parts.append(name) }
        if let details = details { parts.append(details) }
        if let filename = behaviorHints.filename { parts.append(filename) }
        if let url = directURL { parts.append(url.lastPathComponent) }
        return parts.joined(separator: " ")
    }
}

extension AddonStream: Codable {
    private enum CodingKeys: String, CodingKey {
        case url, ytId, infoHash, fileIdx, sources, announce, externalUrl, playerFrameUrl
        case nzbUrl, rarUrls, zipUrls, sevenZipUrls = "7zipUrls", tgzUrls, tarUrls
        case name, title, description, thumbnail, subtitles, behaviorHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source: StreamSource
        if let url = container.flexString(.url), !url.isEmpty {
            source = .url(url)
        } else if let yt = container.flexString(.ytId), !yt.isEmpty {
            source = .youtube(yt)
        } else if let hash = container.flexString(.infoHash), !hash.isEmpty {
            var trackers = container.stringList(.sources)
            trackers.append(contentsOf: container.stringList(.announce))
            source = .torrent(infoHash: hash, fileIndex: container.flexInt(.fileIdx), trackers: trackers)
        } else if let external = container.flexString(.externalUrl), !external.isEmpty {
            source = .external(external)
        } else if let frame = container.flexString(.playerFrameUrl), !frame.isEmpty {
            source = .playerFrame(frame)
        } else if container.contains(.nzbUrl) {
            source = .archive(kind: "nzb")
        } else if container.contains(.rarUrls) {
            source = .archive(kind: "rar")
        } else if container.contains(.zipUrls) {
            source = .archive(kind: "zip")
        } else if container.contains(.sevenZipUrls) {
            source = .archive(kind: "7zip")
        } else if container.contains(.tgzUrls) {
            source = .archive(kind: "tgz")
        } else if container.contains(.tarUrls) {
            source = .archive(kind: "tar")
        } else {
            source = .unknown
        }
        self.source = source
        self.name = container.flexString(.name)
        self.details = container.flexString(.description) ?? container.flexString(.title)
        self.thumbnail = container.flexString(.thumbnail)
        self.subtitles = container.lossyArray(AddonSubtitle.self, forKey: .subtitles)
        self.behaviorHints = container.lenient(StreamBehaviorHints.self, forKey: .behaviorHints)
            ?? StreamBehaviorHints()
        self.addonID = nil
        self.addonName = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .url(let url): try container.encode(url, forKey: .url)
        case .youtube(let id): try container.encode(id, forKey: .ytId)
        case .torrent(let hash, let index, let trackers):
            try container.encode(hash, forKey: .infoHash)
            try container.encodeIfPresent(index, forKey: .fileIdx)
            if !trackers.isEmpty { try container.encode(trackers, forKey: .sources) }
        case .external(let url): try container.encode(url, forKey: .externalUrl)
        case .playerFrame(let url): try container.encode(url, forKey: .playerFrameUrl)
        case .archive, .unknown: break
        }
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(details, forKey: .description)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        if !subtitles.isEmpty { try container.encode(subtitles, forKey: .subtitles) }
        try container.encode(behaviorHints, forKey: .behaviorHints)
    }
}

extension URL {
    /// Builds a URL from an addon-supplied string, percent-encoding characters Foundation would reject
    /// (spaces, non-ASCII). Returns nil for strings that are not a URL at all.
    public static func lenient(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.formUnion(.urlPathAllowed)
        allowed.formUnion(.urlHostAllowed)
        allowed.insert(charactersIn: "%:/?#[]@!$&'()*+,;=")
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded)
    }
}
