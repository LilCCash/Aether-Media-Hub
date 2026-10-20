import Foundation

// Orchestration on top of `TorBoxClient` (docs/research/torbox-api.md sections 5 and 7):
//
//   availability:  POST checkcached in chunks of at most 100 canonical hashes, results cached in memory for about an hour.
//                  A failure leaves the hashes `.unknown`; it is never reported as "not cached".
//   resolve:       mylist (is the torrent already in the account?) -> [cachedOnly: fresh checkcached] -> createtorrent only
//                  when needed -> poll mylist?id= no faster than every 3 s until download_present && download_finished ->
//                  TorBoxFileMatcher -> requestdl (no redirect, no user_ip).
//
// Hard rules: the resolver never deletes, pauses, stops or "repairs" an item of the user's account (the client has no such
// call), never adds a torrent twice (DIFF_ISSUE / DUPLICATE_ITEM make it read the list again), and stops polling as soon as
// the calling task is cancelled.

public actor DebridResolver: DebridProvider {
    public struct Configuration: Equatable, Sendable {
        /// How long a `checkcached` answer is reused (the service keeps its own one-hour cache).
        public var cacheTTL: TimeInterval
        /// Seconds between two `mylist` polls. Never below `minimumPollInterval`.
        public var pollInterval: TimeInterval
        /// Longest wait for a torrent that should already be cached ("instant").
        public var cachedMaxWait: TimeInterval
        /// Longest wait when the user allowed a real download (`startIfNeeded`). The item stays in the account afterwards.
        public var startMaxWait: TimeInterval
        public var listPageSize: Int
        public var maxListPages: Int
        public var maxTrackers: Int

        public static let minimumPollInterval: TimeInterval = 3

        public init(cacheTTL: TimeInterval = 3600, pollInterval: TimeInterval = 3, cachedMaxWait: TimeInterval = 60,
                    startMaxWait: TimeInterval = 300, listPageSize: Int = 1000, maxListPages: Int = 3,
                    maxTrackers: Int = 20) {
            self.cacheTTL = cacheTTL
            self.pollInterval = pollInterval
            self.cachedMaxWait = cachedMaxWait
            self.startMaxWait = startMaxWait
            self.listPageSize = listPageSize
            self.maxListPages = maxListPages
            self.maxTrackers = maxTrackers
        }
    }

    private struct CacheEntry {
        let status: DebridCacheStatus
        let date: Date
    }

    private let client: TorBoxClient
    private let configuration: Configuration
    private let clock: DebridClock
    private let log: DiagnosticLog?
    private var availabilityCache: [String: CacheEntry] = [:]

    public init(client: TorBoxClient, configuration: Configuration = Configuration(),
                clock: DebridClock = DebridClock.system, log: DiagnosticLog? = nil) {
        var adjusted = configuration
        adjusted.pollInterval = max(Configuration.minimumPollInterval, adjusted.pollInterval)
        adjusted.listPageSize = max(1, adjusted.listPageSize)
        adjusted.maxListPages = max(1, adjusted.maxListPages)
        adjusted.maxTrackers = max(0, adjusted.maxTrackers)
        self.client = client
        self.configuration = adjusted
        self.clock = clock
        self.log = log
    }

    public nonisolated var displayName: String { return "TorBox" }

    // MARK: Account

    public func validateCredentials() async throws -> DebridAccount {
        let user = try await client.fetchUser()
        let now = clock.now()
        let isFree = user.plan == 0
        var notice: String?
        if isFree {
            notice = "Piano Free: limiti più stretti e alcune funzioni potrebbero non essere disponibili."
        } else if user.plan != nil, let expiry = user.premiumExpiresAt, expiry < now {
            notice = "L'abbonamento TorBox risulta scaduto."
        }
        if let cooldown = user.cooldownUntil, cooldown > now {
            notice = "TorBox ha sospeso temporaneamente i nuovi download (periodo di attesa)."
        }
        await note(.info, "chiave verificata (piano \(user.planName))")
        return DebridAccount(planName: user.planName, planCode: user.plan, isFreePlan: isFree,
                             premiumExpiresAt: user.premiumExpiresAt, cooldownUntil: user.cooldownUntil, notice: notice)
    }

    // MARK: Availability

    public func clearAvailabilityCache() {
        availabilityCache.removeAll()
    }

    public func availability(infoHashes: [String]) async -> DebridAvailabilityReport {
        var statuses: [String: DebridCacheStatus] = [:]
        var owners: [String: [String]] = [:]
        var pending: [String] = []
        var queued = Set<String>()
        let startedAt = clock.now()

        for raw in infoHashes {
            guard let canonical = DebridHash.normalize(raw) else {
                statuses[raw] = DebridCacheStatus.unknown
                await note(.debug, "hash saltato: \(DebridHash.rejectionReason(raw))")
                continue
            }
            owners[canonical, default: []].append(raw)
            if let entry = availabilityCache[canonical], startedAt.timeIntervalSince(entry.date) < configuration.cacheTTL {
                statuses[raw] = entry.status
            } else if !queued.contains(canonical) {
                queued.insert(canonical)
                pending.append(canonical)
            }
        }

        var failure: DebridError?
        var index = 0
        chunks: while index < pending.count {
            let end = min(index + TorBoxClient.maxHashesPerCheck, pending.count)
            let chunk = Array(pending[index..<end])
            index = end
            do {
                try Task.checkCancellation()
                let cached = try await client.checkCachedChunk(chunk)
                let stamp = clock.now()
                for hash in chunk {
                    let status: DebridCacheStatus = cached[hash] != nil ? DebridCacheStatus.cached : DebridCacheStatus.notCached
                    availabilityCache[hash] = CacheEntry(status: status, date: stamp)
                    let rawNames: [String] = owners[hash] ?? []
                    for raw in rawNames {
                        statuses[raw] = status
                    }
                }
            } catch is CancellationError {
                break chunks
            } catch let error as DebridError {
                if failure == nil { failure = error }
                await note(.warning, "checkcached non riuscito: \(error.message)")
                let fatal: Bool
                switch error {
                case .notConfigured, .authFailed, .planRestricted, .rateLimited, .refusedHost:
                    fatal = true
                default:
                    fatal = false
                }
                if fatal { break chunks }
            } catch {
                if failure == nil { failure = DebridError.network("Errore di rete verso TorBox.") }
                break chunks
            }
        }

        // Whatever could not be answered stays unknown.
        for raw in infoHashes where statuses[raw] == nil {
            statuses[raw] = DebridCacheStatus.unknown
        }
        return DebridAvailabilityReport(statuses: statuses, failure: failure)
    }

    private func verifyCached(_ hash: String) async throws -> DebridCacheStatus {
        let cached = try await client.checkCachedChunk([hash])
        let status: DebridCacheStatus = cached[hash] != nil ? DebridCacheStatus.cached : DebridCacheStatus.notCached
        availabilityCache[hash] = CacheEntry(status: status, date: clock.now())
        return status
    }

    // MARK: Resolve

    public func resolve(_ request: DebridRequest,
                        onProgress: (@Sendable (DebridProgress) -> Void)?) async throws -> DebridResolution {
        guard let hash = DebridHash.normalize(request.infoHash),
              let magnet = DebridMagnet.build(infoHash: request.infoHash, trackers: request.trackers,
                                              maxTrackers: configuration.maxTrackers) else {
            throw DebridError.invalidInfoHash(String(request.infoHash.prefix(64)))
        }
        try Task.checkCancellation()
        onProgress?(DebridProgress(phase: .checking))
        await note(.info, "risoluzione avviata (\(request.mode.rawValue))")
        let query = TorBoxFileMatcher.query(for: request)

        // 1. Is the torrent already in the account? (avoids DIFF_ISSUE and double adds)
        let existing = try await findInAccount(hash: hash)
        let wasInAccount = existing != nil

        var readyTorrent: TorBoxTorrent?
        if let item = existing, item.isReady, !item.files.isEmpty {
            readyTorrent = item
            await note(.info, "già presente nell'account e pronto")
        }

        if readyTorrent == nil {
            var trackedID: Int? = existing?.id

            // 2. cachedOnly never starts a download: ask the cache first, with a fresh request.
            if request.mode == .cachedOnly && existing?.isReady != true {
                let status = try await verifyCached(hash)
                if status != DebridCacheStatus.cached {
                    await note(.info, "non in cache: nessun download avviato")
                    throw DebridError.notCached
                }
            }

            // 3. Add it, only when it is not there yet.
            if existing == nil {
                onProgress?(DebridProgress(phase: .adding))
                trackedID = try await addTorrent(magnet: magnet, hash: hash)
                if trackedID == nil {
                    onProgress?(DebridProgress(phase: .queued, state: "queued"))
                }
            }

            // 4. Wait (bounded, cancellable) until the files are really there.
            readyTorrent = try await waitUntilReady(hash: hash, trackedID: trackedID, mode: request.mode,
                                                    onProgress: onProgress)
        }

        guard let torrent = readyTorrent else {
            throw DebridError.invalidResponse("torrent non disponibile")
        }

        // 5. Pick the file.
        onProgress?(DebridProgress(phase: .selectingFile, fraction: 1))
        let file: TorBoxFile
        switch TorBoxFileMatcher.select(from: torrent.files, query: query) {
        case .selected(let selected, let reason):
            file = selected
            await note(.info, "file scelto (\(reason.rawValue))")
        case .noConfidentMatch(let candidates):
            await note(.info, "nessun file certo tra \(candidates.count) candidati")
            throw DebridError.noMatchingFile(candidates: candidates)
        case .noVideo:
            throw DebridError.noVideoFile
        case .archivesOnly:
            throw DebridError.archivedFilesOnly
        case .infectedOnly:
            throw DebridError.infectedFiles
        }
        guard let fileID = file.id else {
            throw DebridError.invalidResponse("file senza identificativo")
        }

        // 6. The link (no redirect, no user_ip). Never stored here.
        try Task.checkCancellation()
        onProgress?(DebridProgress(phase: .requestingLink, fraction: 1))
        let url = try await client.requestDownloadLink(torrentID: torrent.id, fileID: fileID)
        await note(.info, "link ottenuto")
        return DebridResolution(url: url, fileName: file.displayName, fileSize: file.size, torrentID: torrent.id,
                                fileID: fileID, wasAlreadyInAccount: wasInAccount, resolvedAt: clock.now())
    }

    // MARK: Steps

    /// Looks for the hash in the user's list (a few pages at most). A list that cannot be read at all is not fatal: the
    /// add that follows is safe because TorBox answers DIFF_ISSUE / DUPLICATE_ITEM for something it already has.
    private func findInAccount(hash: String) async throws -> TorBoxTorrent? {
        var offset = 0
        var page = 0
        while page < configuration.maxListPages {
            try Task.checkCancellation()
            let items: [TorBoxTorrent]
            do {
                items = try await client.myList(id: nil, offset: offset, limit: configuration.listPageSize)
            } catch let error as DebridError {
                if case .invalidResponse = error {
                    await note(.warning, "lista TorBox non leggibile: controllo duplicati saltato")
                    return nil
                }
                throw error
            }
            for item in items {
                if let raw = item.hash, DebridHash.normalize(raw) == hash { return item }
            }
            if items.count < configuration.listPageSize { return nil }
            offset += configuration.listPageSize
            page += 1
        }
        return nil
    }

    /// Adds the torrent. Returns the new `torrent_id`, or nil when TorBox queued it (or already holds it in its queue).
    private func addTorrent(magnet: String, hash: String) async throws -> Int? {
        do {
            let created = try await client.createTorrent(magnet: magnet)
            availabilityCache.removeValue(forKey: hash)
            if let id = created.torrentID {
                await note(.info, "torrent aggiunto\(created.usedCachedCopy ? " (copia in cache)" : "")")
                return id
            }
            await note(.info, "torrent messo in coda da TorBox")
            return nil
        } catch let error as DebridError {
            if error == DebridError.alreadyInAccount {
                // The provider already has it (account or queue): read the list again, never add a second time.
                if let found = try await findInAccount(hash: hash) {
                    await note(.info, "TorBox lo aveva già: uso l'elemento esistente")
                    return found.id
                }
                await note(.info, "TorBox lo ha già in coda")
                return nil
            }
            throw error
        }
    }

    private func readTorrent(id: Int) async throws -> TorBoxTorrent? {
        do {
            let items = try await client.myList(id: id)
            return items.first(where: { (torrent: TorBoxTorrent) -> Bool in return torrent.id == id })
        } catch let error as DebridError {
            if error == DebridError.itemNotFound { return nil }
            throw error
        }
    }

    private func waitUntilReady(hash: String, trackedID: Int?, mode: DebridMode,
                                onProgress: (@Sendable (DebridProgress) -> Void)?) async throws -> TorBoxTorrent {
        let limit = mode == .cachedOnly ? configuration.cachedMaxWait : configuration.startMaxWait
        let interval = configuration.pollInterval
        let started = clock.now()
        var id = trackedID
        var last: DebridProgress?
        var readyWithoutFiles = false

        while true {
            try Task.checkCancellation()
            var snapshot: TorBoxTorrent?
            if let knownID = id {
                snapshot = try await readTorrent(id: knownID)
                if snapshot == nil {
                    snapshot = try await findInAccount(hash: hash)
                }
            } else {
                // Queued by the provider: it is not in `mylist` until a slot frees up, so look for the hash.
                snapshot = try await findInAccount(hash: hash)
            }

            if let item = snapshot {
                id = item.id
                if item.isReady {
                    if !item.files.isEmpty { return item }
                    readyWithoutFiles = true
                } else if let failed = DebridResolver.failureState(of: item) {
                    throw DebridError.itemFailed(state: failed)
                }
                let progress = DebridResolver.progress(from: item)
                last = progress
                onProgress?(progress)
            } else {
                let progress = DebridProgress(phase: .queued, state: "queued")
                last = progress
                onProgress?(progress)
            }

            let elapsed = clock.now().timeIntervalSince(started)
            if elapsed + interval > limit { break }
            try await clock.sleep(interval)
        }

        if readyWithoutFiles { throw DebridError.noVideoFile }
        if id == nil { throw DebridError.queuedAtProvider }
        await note(.info, "attesa terminata: il download continua su TorBox")
        throw DebridError.downloadNotReady(last)
    }

    // MARK: Pure helpers

    static func progress(from torrent: TorBoxTorrent) -> DebridProgress {
        return DebridProgress(phase: .downloading, fraction: normalizedFraction(torrent.progress),
                              downloadSpeed: torrent.downloadSpeed, etaSeconds: torrent.eta,
                              state: torrent.downloadState)
    }

    /// TorBox's `progress` scale is not verified: 0...1 is taken as a fraction, (1, 100] as a percentage.
    static func normalizedFraction(_ raw: Double?) -> Double? {
        guard let value = raw, value.isFinite else { return nil }
        if value <= 0 { return 0 }
        if value <= 1 { return value }
        if value <= 100 { return value / 100 }
        return 1
    }

    /// A state that means the torrent will not finish by itself. Stalled / paused states keep being polled until the deadline.
    static func failureState(of torrent: TorBoxTorrent) -> String? {
        guard let state = torrent.downloadState?.trimmingCharacters(in: .whitespacesAndNewlines), !state.isEmpty else {
            return nil
        }
        let lowered = state.lowercased()
        if lowered == "failed" || lowered == "missingfiles" || lowered.hasPrefix("error") {
            return String(state.prefix(60))
        }
        return nil
    }

    private func note(_ level: LogLevel, _ message: String) async {
        await log?.log(level, "torbox", message)
    }
}
