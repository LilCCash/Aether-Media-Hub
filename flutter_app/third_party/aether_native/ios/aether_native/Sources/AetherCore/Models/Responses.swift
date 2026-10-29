import Foundation

/// Cache related hints an addon may put in any response (`cacheMaxAge`, `staleRevalidate`, `staleError`), in seconds.
public struct CacheHints: Hashable, Sendable {
    public var maxAge: Int?
    public var staleRevalidate: Int?
    public var staleError: Int?

    public init(maxAge: Int? = nil, staleRevalidate: Int? = nil, staleError: Int? = nil) {
        self.maxAge = maxAge
        self.staleRevalidate = staleRevalidate
        self.staleError = staleError
    }
}

/// Entry of an `addon_catalog` response: `{ transportName, transportUrl, manifest }`.
public struct AddonCatalogEntry: Hashable, Sendable {
    public var transportName: String
    public var transportUrl: String
    public var manifest: AddonManifest
}

extension AddonCatalogEntry: Decodable {
    private enum CodingKeys: String, CodingKey { case transportName, transportUrl, manifest }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.transportName = container.flexString(.transportName) ?? "http"
        guard let url = container.flexString(.transportUrl) else {
            throw DecodingError.keyNotFound(CodingKeys.transportUrl,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "transportUrl"))
        }
        self.transportUrl = url
        self.manifest = try container.decode(AddonManifest.self, forKey: .manifest)
    }
}

public enum AddonPayload: Sendable {
    case metas([MetaItem])
    case metasDetailed([MetaItem])
    case meta(MetaItem)
    case streams([AddonStream])
    case subtitles([AddonSubtitle])
    case addons([AddonCatalogEntry])
}

public struct AddonResponse: Sendable {
    public var payload: AddonPayload
    public var cache: CacheHints
    /// True if served from cache past its freshness (stale-if-error).
    public var isStale: Bool

    public init(payload: AddonPayload, cache: CacheHints = CacheHints(), isStale: Bool = false) {
        self.payload = payload
        self.cache = cache
        self.isStale = isStale
    }
}

/// Failure while turning bytes from an addon into model objects.
public enum ResponseDecodingError: Error, Equatable, Sendable {
    case notJSON
    case notAnObject
    case missingKey(String)
}

public enum ResponseDecoder {
    private struct Envelope: Decodable {
        var metas: [MetaItem]?
        var metasDetailed: [MetaItem]?
        var meta: MetaItem?
        var streams: [AddonStream]?
        var subtitles: [AddonSubtitle]?
        var addons: [AddonCatalogEntry]?
        var hints: CacheHints
        var presentKeys: Set<String>

        private struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var keys = Set<String>()
            for key in container.allKeys { keys.insert(key.stringValue) }
            presentKeys = keys

            func key(_ name: String) -> DynamicKey { return DynamicKey(stringValue: name)! }

            metas = (try? container.decodeIfPresent(LossyArray<MetaItem>.self, forKey: key("metas")))?.elements
            metasDetailed = (try? container.decodeIfPresent(LossyArray<MetaItem>.self, forKey: key("metasDetailed")))?.elements
            meta = try? container.decodeIfPresent(MetaItem.self, forKey: key("meta"))
            streams = (try? container.decodeIfPresent(LossyArray<AddonStream>.self, forKey: key("streams")))?.elements
            subtitles = (try? container.decodeIfPresent(LossyArray<AddonSubtitle>.self, forKey: key("subtitles")))?.elements
            addons = (try? container.decodeIfPresent(LossyArray<AddonCatalogEntry>.self, forKey: key("addons")))?.elements

            let maxAge = (try? container.decodeIfPresent(FlexInt.self, forKey: key("cacheMaxAge")))?.value
            let revalidate = (try? container.decodeIfPresent(FlexInt.self, forKey: key("staleRevalidate")))?.value
            let staleError = (try? container.decodeIfPresent(FlexInt.self, forKey: key("staleError")))?.value
            hints = CacheHints(maxAge: maxAge, staleRevalidate: revalidate, staleError: staleError)
        }
    }

    /// Decodes an addon response for the requested resource. Missing top-level keys throw `missingKey`
    /// (an addon answering `{}` for a catalog is malformed); `null`/empty arrays are valid empty results.
    public static func decode(_ data: Data, resource: String, expectsDetailedCatalog: Bool = false) throws -> AddonResponse {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                throw ResponseDecodingError.notJSON
            }
            throw ResponseDecodingError.notAnObject
        }
        switch resource {
        case ResourceName.catalog:
            if expectsDetailedCatalog, envelope.presentKeys.contains("metasDetailed") {
                return AddonResponse(payload: .metasDetailed(envelope.metasDetailed ?? []), cache: envelope.hints)
            }
            if envelope.presentKeys.contains("metas") {
                return AddonResponse(payload: .metas(envelope.metas ?? []), cache: envelope.hints)
            }
            if envelope.presentKeys.contains("metasDetailed") {
                return AddonResponse(payload: .metasDetailed(envelope.metasDetailed ?? []), cache: envelope.hints)
            }
            throw ResponseDecodingError.missingKey("metas")
        case ResourceName.meta:
            if let meta = envelope.meta {
                return AddonResponse(payload: .meta(meta), cache: envelope.hints)
            }
            throw ResponseDecodingError.missingKey("meta")
        case ResourceName.stream:
            if envelope.presentKeys.contains("streams") {
                return AddonResponse(payload: .streams(envelope.streams ?? []), cache: envelope.hints)
            }
            throw ResponseDecodingError.missingKey("streams")
        case ResourceName.subtitles:
            if envelope.presentKeys.contains("subtitles") {
                return AddonResponse(payload: .subtitles(envelope.subtitles ?? []), cache: envelope.hints)
            }
            throw ResponseDecodingError.missingKey("subtitles")
        case ResourceName.addonCatalog:
            if envelope.presentKeys.contains("addons") {
                return AddonResponse(payload: .addons(envelope.addons ?? []), cache: envelope.hints)
            }
            throw ResponseDecodingError.missingKey("addons")
        default:
            throw ResponseDecodingError.missingKey(resource)
        }
    }

    public static func decodeManifest(_ data: Data) throws -> AddonManifest {
        let manifest: AddonManifest
        do {
            manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
        } catch let error as DecodingError {
            if case .keyNotFound(let key, _) = error {
                throw ManifestValidationError.missingField(key.stringValue)
            }
            if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                throw ResponseDecodingError.notJSON
            }
            throw ResponseDecodingError.notAnObject
        } catch {
            throw ResponseDecodingError.notJSON
        }
        try ManifestValidator.validate(manifest)
        return manifest
    }
}
