import Foundation

/// Talks the Stremio addon HTTP protocol: manifest + resources, with validation, caching and error mapping.
public final class AddonClient: Sendable {
    public let http: HTTPClient
    public let cache: ResponseCache?

    public init(http: HTTPClient, cache: ResponseCache? = nil) {
        self.http = http
        self.cache = cache
    }

    // MARK: Manifest

    public func fetchManifest(_ url: URL, timeout: TimeInterval = 12) async throws -> AddonManifest {
        let request = HTTPRequest(url: url, timeout: timeout, maxBytes: HTTPLimits.manifest)
        let response = try await http.send(request)
        try AddonClient.checkStatus(response)
        do {
            return try ResponseDecoder.decodeManifest(response.data)
        } catch let error as ManifestValidationError {
            throw AddonError.invalidManifest(error.message)
        } catch let error as ResponseDecodingError {
            switch error {
            case .notJSON:
                throw AddonError.invalidManifest("La risposta non è JSON: l'URL non punta al manifest di un addon.")
            case .notAnObject, .missingKey:
                throw AddonError.invalidManifest("Il manifest non è un oggetto JSON valido.")
            }
        }
    }

    // MARK: Resources

    public enum LoadMode: Sendable {
        /// Fresh cache wins; stale cache is used when the network fails.
        case normal
        /// Bypass the cache for reading (pull-to-refresh) but still write it.
        case reload
        /// Never touch the cache.
        case noCache
    }

    /// Fetches `{resource}/{type}/{id}[/{extra}].json` from the addon at `transport`.
    public func fetch(transport: URL, path: ResourcePath, mode: LoadMode = .normal,
                      timeout: TimeInterval = 15) async throws -> AddonResponse {
        guard let url = ResourceURLBuilder.url(transport: transport, path: path) else {
            throw AddonError.invalidURL("impossibile costruire l'URL della risorsa «\(path.resource)»")
        }
        let key = url.absoluteString
        let kind = CacheKind.forResource(path.resource)
        let detailedCatalog = path.extra.contains(where: { $0.name == "date" })

        var staleCandidate: CacheLookup?
        if mode != .noCache, let cache = cache, let hit = await cache.lookup(key) {
            if hit.isFresh && mode == .normal,
               let decoded = try? ResponseDecoder.decode(hit.data, resource: path.resource,
                                                         expectsDetailedCatalog: detailedCatalog) {
                return decoded
            }
            if hit.usableAsStale { staleCandidate = hit }
        }

        do {
            let response = try await http.send(HTTPRequest(url: url, timeout: timeout, maxBytes: HTTPLimits.resource))
            try AddonClient.checkStatus(response)
            let decoded: AddonResponse
            do {
                decoded = try ResponseDecoder.decode(response.data, resource: path.resource,
                                                     expectsDetailedCatalog: detailedCatalog)
            } catch let error as ResponseDecodingError {
                switch error {
                case .notJSON: throw AddonError.malformedResponse("non è JSON")
                case .notAnObject: throw AddonError.malformedResponse("non è un oggetto JSON")
                case .missingKey(let missing): throw AddonError.malformedResponse("manca «\(missing)»")
                }
            }
            if mode != .noCache, let cache = cache {
                await cache.store(key: key, data: response.data, kind: kind, hints: decoded.cache)
            }
            return decoded
        } catch {
            if error is CancellationError { throw error }
            if let stale = staleCandidate, AddonClient.isTransient(error),
               var decoded = try? ResponseDecoder.decode(stale.data, resource: path.resource,
                                                         expectsDetailedCatalog: detailedCatalog) {
                decoded.isStale = true
                return decoded
            }
            throw error
        }
    }

    // MARK: Helpers

    static func checkStatus(_ response: HTTPResponse) throws {
        if response.isSuccess { return }
        if response.statusCode == 404 { throw AddonError.notFound }
        throw AddonError.http(status: response.statusCode)
    }

    static func isTransient(_ error: Error) -> Bool {
        if let addonError = error as? AddonError { return addonError.isTransient }
        return false
    }
}
