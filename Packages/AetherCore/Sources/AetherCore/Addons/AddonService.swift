import Foundation

/// Outcome of asking one addon for one resource.
public struct AddonOutcome<Value: Sendable>: Sendable {
    public var addonID: UUID
    public var addonName: String
    public var result: Result<Value, AddonError>
    public var latency: TimeInterval
    public var isStale: Bool

    public var value: Value? {
        if case .success(let value) = result { return value }
        return nil
    }

    public var error: AddonError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}

struct IndexedMetaOutcome: Sendable {
    var index: Int
    var outcome: AddonOutcome<MetaItem>
}

public struct MetaResolution: Sendable {
    public var meta: MetaItem
    /// Addon that supplied the detail (nil when only the catalog preview was available).
    public var providerName: String?
    public var failures: [AddonError]
    public var hadDetailProvider: Bool
}

public struct CatalogResult: Sendable {
    public var items: [MetaItem]
    public var isStale: Bool
}

/// High level façade used by view-models: plans requests from manifests, runs them concurrently with
/// per-request deadlines and a global concurrency cap, and merges results.
public final class AddonService: Sendable {
    public let registry: AddonRegistry
    public let client: AddonClient
    public let limiter: ConcurrencyLimiter
    public let requestTimeout: TimeInterval

    public init(registry: AddonRegistry, client: AddonClient, maxConcurrentRequests: Int = 6,
                requestTimeout: TimeInterval = 15) {
        self.registry = registry
        self.client = client
        self.limiter = ConcurrencyLimiter(limit: maxConcurrentRequests)
        self.requestTimeout = requestTimeout
    }

    public func handles() async -> [AddonHandle] {
        return await registry.handles()
    }

    // MARK: Single request

    /// One request to one addon: concurrency cap, hard deadline, health bookkeeping.
    func perform(_ handle: AddonHandle, path: ResourcePath, mode: AddonClient.LoadMode) async throws -> AddonResponse {
        let timeout = requestTimeout
        let client = self.client
        do {
            let response = try await limiter.withPermit {
                try await withDeadline(seconds: timeout + 1) {
                    try await client.fetch(transport: handle.transportURL, path: path, mode: mode, timeout: timeout)
                }
            }
            await registry.recordHealth(id: handle.id, error: nil)
            return response
        } catch {
            if error is CancellationError { throw error }
            let addonError = AddonService.normalise(error)
            if case .notFound = addonError {
                await registry.recordHealth(id: handle.id, error: nil)
            } else {
                await registry.recordHealth(id: handle.id, error: addonError.message)
            }
            throw addonError
        }
    }

    static func normalise(_ error: Error) -> AddonError {
        if let addonError = error as? AddonError { return addonError }
        if error is CancellationError { return .cancelled }
        return .unreachable(error.localizedDescription)
    }

    private func outcome<Value: Sendable>(_ handle: AddonHandle, path: ResourcePath, mode: AddonClient.LoadMode,
                                          transform: (AddonPayload) -> Value?) async -> AddonOutcome<Value> {
        let start = Date()
        do {
            let response = try await perform(handle, path: path, mode: mode)
            if let value = transform(response.payload) {
                return AddonOutcome(addonID: handle.id, addonName: handle.addon.displayName,
                                    result: .success(value), latency: Date().timeIntervalSince(start),
                                    isStale: response.isStale)
            }
            return AddonOutcome(addonID: handle.id, addonName: handle.addon.displayName,
                                result: .failure(.malformedResponse("tipo di risposta inatteso")),
                                latency: Date().timeIntervalSince(start), isStale: false)
        } catch {
            return AddonOutcome(addonID: handle.id, addonName: handle.addon.displayName,
                                result: .failure(AddonService.normalise(error)),
                                latency: Date().timeIntervalSince(start), isStale: false)
        }
    }

    // MARK: Catalog

    public func catalog(_ ref: CatalogRef, extra: [ExtraValue] = [], mode: AddonClient.LoadMode = .normal) async throws -> CatalogResult {
        let all = await registry.handles()
        guard let handle = all.first(where: { $0.id == ref.addonID }) else { throw AddonError.notFound }
        let path = ResourcePath(resource: ResourceName.catalog, type: ref.catalog.type, id: ref.catalog.id, extra: extra)
        guard handle.addon.manifest.supports(path) else {
            throw AddonError.unsupported("Il catalogo non supporta i filtri richiesti.")
        }
        let response = try await perform(handle, path: path, mode: mode)
        switch response.payload {
        case .metas(let items), .metasDetailed(let items):
            return CatalogResult(items: items, isStale: response.isStale)
        default:
            throw AddonError.malformedResponse("tipo di risposta inatteso")
        }
    }

    // MARK: Meta

    /// Resolves the detail page metadata. Asks every addon that declares `meta` for the type/id concurrently;
    /// the first addon *in user order* that answers successfully wins, missing fields are filled from `fallback`
    /// (the catalog preview the user tapped) and from lower-priority answers already received.
    public func meta(type: String, id: String, fallback: MetaItem? = nil, mode: AddonClient.LoadMode = .normal) async -> MetaResolution {
        let path = ResourcePath(resource: ResourceName.meta, type: type, id: id)
        let candidates = RequestPlanner.addons(for: path, handles: await registry.handles())
        var failures: [AddonError] = []

        guard !candidates.isEmpty else {
            let base = fallback ?? MetaItem(id: id, type: type, name: id)
            return MetaResolution(meta: base, providerName: nil, failures: [], hadDetailProvider: false)
        }

        // rank (position in user order) -> outcome
        var results: [Int: AddonOutcome<MetaItem>] = [:]
        await withTaskGroup(of: IndexedMetaOutcome.self) { group in
            for (index, handle) in candidates.enumerated() {
                group.addTask { [self] in
                    let outcome: AddonOutcome<MetaItem> = await self.outcome(handle, path: path, mode: mode) { payload in
                        if case .meta(let meta) = payload { return meta }
                        return nil
                    }
                    return IndexedMetaOutcome(index: index, outcome: outcome)
                }
            }
            for await item in group {
                results[item.index] = item.outcome
                // Done as soon as the best-ranked candidate that can still win has answered.
                var decided = false
                for rank in 0..<candidates.count {
                    guard let known = results[rank] else { break }
                    if known.value != nil {
                        decided = true
                        break
                    }
                }
                if decided {
                    group.cancelAll()
                    break
                }
            }
        }

        var winner: AddonOutcome<MetaItem>?
        var merged: MetaItem?
        for rank in 0..<candidates.count {
            guard let outcome = results[rank] else { continue }
            if let meta = outcome.value {
                if winner == nil {
                    winner = outcome
                    merged = meta
                } else if let current = merged {
                    merged = current.merging(fallback: meta)
                }
            } else if let error = outcome.error, error != .cancelled {
                failures.append(error)
            }
        }
        guard var resolved = merged else {
            let base = fallback ?? MetaItem(id: id, type: type, name: id)
            return MetaResolution(meta: base, providerName: nil, failures: failures, hadDetailProvider: true)
        }
        if let fallback = fallback { resolved = resolved.merging(fallback: fallback) }
        return MetaResolution(meta: resolved, providerName: winner?.addonName, failures: failures, hadDetailProvider: true)
    }

    // MARK: Streams

    public struct StreamBatch: Sendable {
        public var addonID: UUID
        public var addonName: String
        public var streams: [AddonStream]
        public var error: AddonError?
        public var isStale: Bool
        public var latency: TimeInterval
    }

    /// Streams from every addon that declares `stream` for this type/video id, delivered as each addon answers.
    /// Cancelling the consuming task cancels the outstanding requests. 404 means "no streams", not an error.
    public func streams(type: String, videoID: String, mode: AddonClient.LoadMode = .normal) -> AsyncStream<StreamBatch> {
        return AsyncStream { continuation in
            let task = Task {
                let path = ResourcePath(resource: ResourceName.stream, type: type, id: videoID)
                let candidates = RequestPlanner.addons(for: path, handles: await self.registry.handles())
                await withTaskGroup(of: StreamBatch.self) { group in
                    for handle in candidates {
                        group.addTask { [self] in
                            let outcome: AddonOutcome<[AddonStream]> = await self.outcome(handle, path: path, mode: mode) { payload in
                                if case .streams(let streams) = payload { return streams }
                                return nil
                            }
                            var streams = outcome.value ?? []
                            for index in streams.indices {
                                streams[index].addonID = handle.addon.id.uuidString
                                streams[index].addonName = handle.addon.displayName
                            }
                            var error = outcome.error
                            if case .notFound? = error { error = nil }
                            return StreamBatch(addonID: handle.id, addonName: handle.addon.displayName,
                                               streams: streams, error: error, isStale: outcome.isStale,
                                               latency: outcome.latency)
                        }
                    }
                    for await batch in group {
                        continuation.yield(batch)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: waits for all addons and returns de-duplicated streams in addon order.
    public func allStreams(type: String, videoID: String) async -> (streams: [AddonStream], errors: [String: AddonError]) {
        var batches: [StreamBatch] = []
        for await batch in streams(type: type, videoID: videoID) { batches.append(batch) }
        let order = await registry.handles().map { $0.id }
        batches.sort { lhs, rhs in
            (order.firstIndex(of: lhs.addonID) ?? Int.max) < (order.firstIndex(of: rhs.addonID) ?? Int.max)
        }
        var seen = Set<String>()
        var merged: [AddonStream] = []
        var errors: [String: AddonError] = [:]
        for batch in batches {
            if let error = batch.error { errors[batch.addonName] = error }
            for stream in batch.streams where seen.insert(stream.id).inserted {
                merged.append(stream)
            }
        }
        return (merged, errors)
    }

    // MARK: Subtitles

    /// Subtitles for a video from every addon that declares `subtitles` for the type and the id prefix, in addon order,
    /// de-duplicated by URL. Hash, size and file name come from the stream's `behaviorHints` first; `local` is a hash computed
    /// on this device (`SubtitleHashProbe`) and `filename` a name the caller already knows. See `SubtitleVideoParams.resolve`.
    public func subtitles(type: String, videoID: String, stream: AddonStream?, local: SubtitleHashResult? = nil,
                          filename: String? = nil) async -> [AddonSubtitle] {
        let params = SubtitleVideoParams.resolve(stream: stream, local: local, filename: filename)
        return await subtitles(type: type, videoID: videoID, params: params)
    }

    /// Explicit values, sent exactly as given (the URL builder percent-encodes them).
    public func subtitles(type: String, videoID: String, videoHash: String? = nil, videoSize: Int64? = nil,
                          filename: String? = nil) async -> [AddonSubtitle] {
        let params = SubtitleVideoParams(hash: videoHash, size: videoSize, filename: filename)
        return await subtitles(type: type, videoID: videoID, params: params)
    }

    public func subtitles(type: String, videoID: String, params: SubtitleVideoParams) async -> [AddonSubtitle] {
        let path = ResourcePath(resource: ResourceName.subtitles, type: type, id: videoID, extra: params.extras)
        let barePath = ResourcePath(resource: ResourceName.subtitles, type: type, id: videoID)
        let allHandles = await registry.handles()
        // Only addons that declare this type AND this id prefix are asked (OpenSubtitles v3 declares `tt`: a `kitsu:` id never reaches it).
        let planned = RequestPlanner.addons(for: barePath, handles: allHandles)
        let candidates = planned.filter { (handle: AddonHandle) -> Bool in
            return AddonService.declaresSubtitleID(handle.addon.manifest, id: videoID)
        }

        var collected: [(Int, [AddonSubtitle])] = []
        await withTaskGroup(of: (Int, [AddonSubtitle]).self) { group in
            for (index, handle) in candidates.enumerated() {
                group.addTask { [self] in
                    let outcome: AddonOutcome<[AddonSubtitle]> = await self.outcome(handle, path: path, mode: .normal) { payload in
                        if case .subtitles(let subs) = payload { return subs }
                        return nil
                    }
                    var subs = outcome.value ?? []
                    for i in subs.indices { subs[i].addonName = handle.addon.displayName }
                    return (index, subs)
                }
            }
            for await item in group { collected.append(item) }
        }
        collected.sort { $0.0 < $1.0 }
        var seen = Set<String>()
        var result: [AddonSubtitle] = []
        for (_, subs) in collected {
            for sub in subs where seen.insert(sub.url).inserted { result.append(sub) }
        }
        return result
    }

    /// True when the id starts with one of the prefixes the addon declares for `subtitles`: the resource's own `idPrefixes`,
    /// otherwise the manifest's (a resource object that lists only `types` inherits them). No prefixes at all means every id.
    static func declaresSubtitleID(_ manifest: AddonManifest, id: String) -> Bool {
        guard let resource = manifest.resource(named: ResourceName.subtitles) else { return false }
        let declared: [String]? = resource.idPrefixes ?? manifest.idPrefixes
        guard let prefixes = declared, !prefixes.isEmpty else { return true }
        return prefixes.contains(where: { id.hasPrefix($0) })
    }
}
