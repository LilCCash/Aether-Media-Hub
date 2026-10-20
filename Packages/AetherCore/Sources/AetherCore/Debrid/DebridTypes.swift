import Foundation

// Provider-neutral vocabulary for debrid services (today only TorBox). Value types and one protocol, no I/O.
// Nothing in here ever holds an API key; error messages are user-facing Italian text and are built from constants,
// never from raw server text that could echo a credential.

// MARK: - Request

/// How far `resolve` may go to obtain a playable link.
public enum DebridMode: String, Codable, Hashable, Sendable {
    /// Never starts a download: when the torrent is not in the provider's cache the call fails with `DebridError.notCached`.
    case cachedOnly
    /// Adds the torrent to the user's account when needed and reports progress while the provider downloads it.
    case startIfNeeded
}

/// Season and episode taken from a Stremio video id (`tt0944947:1:2`).
public struct DebridEpisode: Hashable, Sendable {
    public var season: Int
    public var episode: Int

    public init(season: Int, episode: Int) {
        self.season = season
        self.episode = episode
    }

    /// Understands IMDb style episode ids only (`tt…:season:episode`). Ids of other schemes (`kitsu:1234:5`, where the
    /// middle number is not a season) return nil: guessing would pick the wrong file.
    public static func parse(stremioID: String?) -> DebridEpisode? {
        guard let id = stremioID else { return nil }
        let parts: [String] = id.split(separator: ":", omittingEmptySubsequences: false).map { (part: Substring) -> String in
            return String(part)
        }
        guard parts.count == 3 else { return nil }
        let base = parts[0].lowercased()
        guard base.hasPrefix("tt"), base.count > 2 else { return nil }
        guard let season = Int(parts[1]), let episode = Int(parts[2]), season >= 0, episode >= 0 else { return nil }
        return DebridEpisode(season: season, episode: episode)
    }

    /// True when the id has the `<id>:<a>:<b>` shape of a series episode, whether or not `parse` understands it.
    public static func expectsEpisode(stremioID: String?) -> Bool {
        guard let id = stremioID else { return false }
        return id.split(separator: ":", omittingEmptySubsequences: false).count >= 3
    }
}

/// Everything the resolver needs to turn a torrent stream into a playable link.
public struct DebridRequest: Hashable, Sendable {
    /// As received from the addon: 40 hex characters or a 32 character base32 `btih`.
    public var infoHash: String
    /// Tracker URLs (`tracker:` prefixes from Stremio `sources` are accepted).
    public var trackers: [String]
    /// Stremio `fileIdx`. Only a positional hint used to break ties: it is not the provider's file id.
    public var fileIndex: Int?
    /// `behaviorHints.filename`.
    public var filename: String?
    /// `behaviorHints.videoSize`.
    public var videoSize: Int64?
    /// Stremio video id: `tt0111161` for a movie, `tt0944947:1:2` for an episode.
    public var stremioID: String?
    public var mode: DebridMode

    public init(infoHash: String, trackers: [String] = [], fileIndex: Int? = nil, filename: String? = nil,
                videoSize: Int64? = nil, stremioID: String? = nil, mode: DebridMode = .cachedOnly) {
        self.infoHash = infoHash
        self.trackers = trackers
        self.fileIndex = fileIndex
        self.filename = filename
        self.videoSize = videoSize
        self.stremioID = stremioID
        self.mode = mode
    }

    /// Builds a request from an addon stream; nil when the stream is not a torrent.
    public init?(stream: AddonStream, stremioID: String?, mode: DebridMode = .cachedOnly) {
        guard case .torrent(let hash, let index, let trackers) = stream.source else { return nil }
        self.init(infoHash: hash, trackers: trackers, fileIndex: index, filename: stream.behaviorHints.filename,
                  videoSize: stream.behaviorHints.videoSize, stremioID: stremioID, mode: mode)
    }
}

// MARK: - Results

public enum DebridCacheStatus: String, Codable, Hashable, Sendable {
    case cached
    case notCached
    /// The provider could not be asked (or answered nonsense). Never means "not cached".
    case unknown

    public var label: String {
        switch self {
        case .cached: return "In cache"
        case .notCached: return "Non in cache"
        case .unknown: return "Sconosciuto"
        }
    }
}

/// Answer of an availability check. `statuses` is keyed by the hash string exactly as the caller passed it.
public struct DebridAvailabilityReport: Equatable, Sendable {
    public var statuses: [String: DebridCacheStatus]
    /// First failure met while asking the provider, if any (the affected hashes are `.unknown`).
    public var failure: DebridError?

    public init(statuses: [String: DebridCacheStatus] = [:], failure: DebridError? = nil) {
        self.statuses = statuses
        self.failure = failure
    }

    public func status(for hash: String) -> DebridCacheStatus {
        return statuses[hash] ?? .unknown
    }
}

/// A file of a torrent offered to the user when the right one cannot be picked automatically.
public struct DebridFileCandidate: Hashable, Sendable {
    public var id: Int
    /// File name without folders.
    public var name: String
    /// Path inside the torrent (the root folder included).
    public var path: String
    public var size: Int64?

    public init(id: Int, name: String, path: String, size: Int64?) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
    }
}

/// A playable link. The URL is short lived: use it for the current playback session and ask again later.
public struct DebridResolution: Equatable, Sendable, CustomStringConvertible {
    public var url: URL
    public var fileName: String
    public var fileSize: Int64?
    public var torrentID: Int
    public var fileID: Int
    /// The torrent was already in the user's TorBox account before this call.
    public var wasAlreadyInAccount: Bool
    public var resolvedAt: Date

    public init(url: URL, fileName: String, fileSize: Int64?, torrentID: Int, fileID: Int,
                wasAlreadyInAccount: Bool, resolvedAt: Date) {
        self.url = url
        self.fileName = fileName
        self.fileSize = fileSize
        self.torrentID = torrentID
        self.fileID = fileID
        self.wasAlreadyInAccount = wasAlreadyInAccount
        self.resolvedAt = resolvedAt
    }

    /// Host only: the CDN URL carries a per-download token and must not end up in logs.
    public var description: String {
        return "DebridResolution(host: \(url.host ?? "?"), torrent: \(torrentID), file: \(fileID))"
    }

    /// A direct-URL stream the player pipeline (`StreamAnalyzer`, `PlaybackPlanner`) understands. The file name is kept in
    /// `behaviorHints.filename` because CDN URLs do not always end with the file extension.
    public func playableStream(from original: AddonStream) -> AddonStream {
        var hints = original.behaviorHints
        hints.filename = fileName
        if let size = fileSize, size > 0 { hints.videoSize = size }
        return AddonStream(source: .url(url.absoluteString), name: original.name, details: original.details,
                           thumbnail: original.thumbnail, subtitles: original.subtitles, behaviorHints: hints,
                           addonID: original.addonID, addonName: original.addonName)
    }
}

/// Progress of a resolution, for the UI.
public struct DebridProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case checking
        case adding
        case queued
        case downloading
        case selectingFile
        case requestingLink
    }

    public var phase: Phase
    /// 0...1 when the provider reports it.
    public var fraction: Double?
    /// Bytes per second.
    public var downloadSpeed: Int64?
    public var etaSeconds: Int?
    /// Provider state as reported (`downloading`, `metaDL`, `stalled (no seeds)`…).
    public var state: String?

    public init(phase: Phase, fraction: Double? = nil, downloadSpeed: Int64? = nil, etaSeconds: Int? = nil,
                state: String? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.downloadSpeed = downloadSpeed
        self.etaSeconds = etaSeconds
        self.state = state
    }

    public var message: String {
        switch phase {
        case .checking: return "Controllo il tuo account TorBox…"
        case .adding: return "Aggiungo il torrent a TorBox…"
        case .queued: return "In coda su TorBox…"
        case .downloading: return DebridProgress.describe(state: state)
        case .selectingFile: return "Scelgo il file giusto…"
        case .requestingLink: return "Richiedo il link di riproduzione…"
        }
    }

    static func describe(state: String?) -> String {
        guard let raw = state?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "Download su TorBox in corso…"
        }
        switch raw.lowercased() {
        case "downloading": return "Download su TorBox in corso…"
        case "metadl": return "Recupero dei metadati del torrent…"
        case "checkingresumedata", "checking": return "TorBox sta verificando i dati…"
        case "stalled (no seeds)", "stalleddl", "stalled": return "Download fermo: nessun seed disponibile."
        case "paused", "pauseddl": return "Download in pausa su TorBox."
        case "cached": return "Contenuto in cache su TorBox…"
        case "completed", "uploading", "seeding": return "Download completato, preparo i file…"
        default: return "Stato TorBox: \(raw)"
        }
    }
}

/// Account facts worth showing in Settings. There is deliberately no field for the e-mail address.
public struct DebridAccount: Equatable, Sendable {
    public var planName: String
    /// Provider plan code when known (TorBox: 0 Free, 1 Essential, 2 Pro, 3 Standard).
    public var planCode: Int?
    public var isFreePlan: Bool
    public var premiumExpiresAt: Date?
    public var cooldownUntil: Date?
    /// Short Italian remark (free plan limits, expired subscription), nil when there is nothing to warn about.
    public var notice: String?

    public init(planName: String, planCode: Int?, isFreePlan: Bool, premiumExpiresAt: Date?, cooldownUntil: Date?,
                notice: String?) {
        self.planName = planName
        self.planCode = planCode
        self.isFreePlan = isFreePlan
        self.premiumExpiresAt = premiumExpiresAt
        self.cooldownUntil = cooldownUntil
        self.notice = notice
    }
}

// MARK: - Errors

public enum DebridLimitKind: String, Hashable, Sendable {
    case activeDownloads
    case monthly
    case cooldown
    case downloadTooLarge
}

public enum DebridError: Error, Equatable, Sendable {
    /// No API key available from the key provider.
    case notConfigured
    case authFailed
    case planRestricted
    case limitReached(DebridLimitKind)
    case rateLimited(retryAfter: TimeInterval?)
    /// `cachedOnly` mode and the torrent is not in the provider's cache.
    case notCached
    case invalidInfoHash(String)
    /// The provider says the torrent is already in the account (or queued).
    case alreadyInAccount
    case itemNotFound
    /// Waiting in the provider's queue (no free download slot).
    case queuedAtProvider
    /// The provider is still downloading; the item stays in the user's account and a later call continues.
    case downloadNotReady(DebridProgress?)
    case itemFailed(state: String)
    /// An episode was requested but no file could be matched with confidence; the user can choose among `candidates`.
    case noMatchingFile(candidates: [DebridFileCandidate])
    case noVideoFile
    case archivedFilesOnly
    case infectedFiles
    case serviceUnavailable(statusCode: Int?)
    case invalidResponse(String)
    case timeout
    case offline
    case unreachable
    /// TLS / policy / other transport failure; the text is a constant, never taken from the underlying error.
    case network(String)
    /// The configured base URL or a response came from a host other than TorBox's.
    case refusedHost(String)
    /// Any other provider error code (sanitised).
    case api(code: String, detail: String?)

    /// User-facing Italian text.
    public var message: String {
        switch self {
        case .notConfigured:
            return "Nessuna chiave API TorBox configurata: aggiungila nelle impostazioni."
        case .authFailed:
            return "TorBox ha rifiutato la chiave API. Controlla o rigenera la chiave nelle impostazioni."
        case .planRestricted:
            return "Questa funzione non è inclusa nel tuo piano TorBox."
        case .limitReached(let kind):
            switch kind {
            case .activeDownloads:
                return "Hai raggiunto il numero massimo di download attivi su TorBox. Attendi che uno finisca: Aether non cancella mai i tuoi elementi."
            case .monthly:
                return "Hai esaurito il limite mensile del tuo piano TorBox."
            case .cooldown:
                return "TorBox ha sospeso temporaneamente i nuovi download (periodo di attesa): riprova più tardi."
            case .downloadTooLarge:
                return "Il contenuto è troppo grande per il tuo piano TorBox."
            }
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter, seconds > 0 {
                return "TorBox sta limitando le richieste. Riprova tra circa \(Int(seconds.rounded(.up))) secondi."
            }
            return "TorBox sta limitando le richieste. Riprova tra poco."
        case .notCached:
            return "Questo contenuto non è nella cache di TorBox: andrebbe prima scaricato."
        case .invalidInfoHash:
            return "Hash del torrent non valido."
        case .alreadyInAccount:
            return "TorBox segnala che il torrent è già presente o in coda, ma non è visibile nella tua lista."
        case .itemNotFound:
            return "Elemento non trovato su TorBox."
        case .queuedAtProvider:
            return "Il torrent è in coda su TorBox e partirà appena si libera uno slot. Riprova tra poco."
        case .downloadNotReady(let progress):
            if let fraction = progress?.fraction {
                let percent = Int((min(1, max(0, fraction)) * 100).rounded())
                return "Il download su TorBox non è ancora completo (\(percent)%). Resta nella tua lista: riprova tra poco."
            }
            return "Il download su TorBox non è ancora completo. Resta nella tua lista: riprova tra poco."
        case .itemFailed(let state):
            return "TorBox segnala un errore su questo torrent (stato: \(state))."
        case .noMatchingFile:
            return "Non trovo con certezza l'episodio giusto tra i file del torrent: scegli il file."
        case .noVideoFile:
            return "Il torrent non contiene file video riproducibili."
        case .archivedFilesOnly:
            return "I file del torrent sono compressi in un archivio e non si possono riprodurre."
        case .infectedFiles:
            return "TorBox ha segnalato i file del torrent come infetti: non verranno riprodotti."
        case .serviceUnavailable(let status):
            if let status = status {
                return "Il servizio TorBox non risponde correttamente (errore \(status)). Riprova più tardi."
            }
            return "Il servizio TorBox non risponde correttamente. Riprova più tardi."
        case .invalidResponse(let detail):
            return "Risposta di TorBox non valida: \(detail)"
        case .timeout:
            return "TorBox non ha risposto in tempo."
        case .offline:
            return "Nessuna connessione a Internet."
        case .unreachable:
            return "Impossibile raggiungere TorBox."
        case .network(let reason):
            return reason
        case .refusedHost:
            return "Connessione bloccata: l'indirizzo non è quello di TorBox."
        case .api(let code, _):
            switch code {
            case "BOZO_TORRENT":
                return "TorBox non riesce a leggere questo torrent (hash o magnet non valido)."
            case "LINK_OFFLINE":
                return "Il link su TorBox non è più disponibile."
            case "TOO_MUCH_DATA":
                return "La richiesta contiene troppi dati per TorBox."
            case "NOT_ALLOWED":
                return "TorBox non consente questa operazione con il tuo account."
            default:
                return "TorBox ha risposto con un errore (\(code))."
            }
        }
    }

    /// True when trying the same thing again a little later could plausibly work. Limits, auth and plan problems are
    /// not retryable: the user has to act first.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serviceUnavailable, .timeout, .offline, .unreachable, .downloadNotReady, .queuedAtProvider:
            return true
        case .notConfigured, .authFailed, .planRestricted, .limitReached, .notCached, .invalidInfoHash,
             .alreadyInAccount, .itemNotFound, .itemFailed, .noMatchingFile, .noVideoFile, .archivedFilesOnly,
             .infectedFiles, .invalidResponse, .network, .refusedHost, .api:
            return false
        }
    }

    /// Seconds the provider asked us to wait, when known.
    public var retryAfter: TimeInterval? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }
}

extension DebridError: LocalizedError {
    public var errorDescription: String? { return message }
}

extension DebridError: CustomStringConvertible {
    public var description: String { return message }
}

// MARK: - Time

/// Time source of the resolver and the client: injectable so tests never really wait.
public struct DebridClock: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system: DebridClock = DebridClock(
        now: { return Date() },
        sleep: { (seconds: TimeInterval) async throws -> Void in
            let nanoseconds = UInt64(max(0, min(seconds, 3600)) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        })
}

// MARK: - Provider

public enum DebridEvent: Sendable {
    case progress(DebridProgress)
    case resolved(DebridResolution)
}

/// A debrid service able to say what is instantly available and to turn a torrent into a playable link.
public protocol DebridProvider: Sendable {
    var displayName: String { get }

    /// Checks the account / key and returns plan facts.
    func validateCredentials() async throws -> DebridAccount

    /// Never throws: failures show up as `.unknown` statuses (never as `.notCached`) plus `failure`.
    func availability(infoHashes: [String]) async -> DebridAvailabilityReport

    /// Resolves a torrent stream into a link. Honours task cancellation: polling stops at once.
    /// Progress is reported through `onProgress` (may be called from any thread).
    func resolve(_ request: DebridRequest,
                 onProgress: (@Sendable (DebridProgress) -> Void)?) async throws -> DebridResolution
}

public extension DebridProvider {
    func resolve(_ request: DebridRequest) async throws -> DebridResolution {
        return try await resolve(request, onProgress: nil)
    }

    /// Progress and result as one `AsyncThrowingStream`. Cancelling the consumer (breaking out of the `for try await`
    /// loop or cancelling its task) cancels the resolution and with it the polling.
    func resolveEvents(_ request: DebridRequest) -> AsyncThrowingStream<DebridEvent, Error> {
        return AsyncThrowingStream<DebridEvent, Error> { (continuation: AsyncThrowingStream<DebridEvent, Error>.Continuation) in
            let task = Task {
                do {
                    let resolution = try await self.resolve(request, onProgress: { (progress: DebridProgress) -> Void in
                        continuation.yield(DebridEvent.progress(progress))
                    })
                    continuation.yield(DebridEvent.resolved(resolution))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable (_: AsyncThrowingStream<DebridEvent, Error>.Continuation.Termination) -> Void in
                task.cancel()
            }
        }
    }
}

// MARK: - Info hashes and magnets

public enum DebridHash {
    private static let base32Alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Canonical form: 40 lowercase hex characters. Accepts upper case, a `urn:btih:` prefix and the 32 character
    /// base32 spelling of magnet links. Returns nil for anything else.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("urn:btih:") {
            text = String(text.dropFirst(9))
        }
        if text.count == 40 {
            guard isHex(text) else { return nil }
            return text.lowercased()
        }
        if text.count == 32 {
            guard let bytes = decodeBase32(text) else { return nil }
            var hex = ""
            for byte in bytes {
                hex += String(format: "%02x", byte)
            }
            return hex
        }
        return nil
    }

    /// True for exactly 40 lowercase hex characters.
    public static func isCanonical(_ text: String) -> Bool {
        guard text.count == 40 else { return false }
        for scalar in text.unicodeScalars {
            let isDigit = scalar.value >= 0x30 && scalar.value <= 0x39
            let isLowerHex = scalar.value >= 0x61 && scalar.value <= 0x66
            if !isDigit && !isLowerHex { return false }
        }
        return true
    }

    /// Why `normalize` rejected the text (for logs; contains no part of the input).
    public static func rejectionReason(_ raw: String) -> String {
        let count = raw.trimmingCharacters(in: .whitespacesAndNewlines).count
        if count == 40 || count == 32 { return "caratteri non validi" }
        return "lunghezza \(count) non supportata"
    }

    private static func isHex(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 0x30 && value <= 0x39
            let isLower = value >= 0x61 && value <= 0x66
            let isUpper = value >= 0x41 && value <= 0x46
            if !isDigit && !isLower && !isUpper { return false }
        }
        return true
    }

    static func decodeBase32(_ text: String) -> [UInt8]? {
        var buffer: UInt32 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        for character in text.uppercased() {
            guard let index = base32Alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(index)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                let byte = UInt8((buffer >> UInt32(bitCount)) & 0xFF)
                bytes.append(byte)
                buffer &= (UInt32(1) << UInt32(bitCount)) - 1
            }
        }
        return bytes.count == 20 ? bytes : nil
    }
}

public enum DebridMagnet {
    /// `magnet:?xt=urn:btih:<hash>&tr=<tracker>…`, built from the canonical hash and the addon's trackers.
    /// Trackers are cleaned (`tracker:` prefix removed, `dht:` entries and unknown schemes dropped), de-duplicated and capped.
    /// Returns nil when the hash is not valid.
    public static func build(infoHash: String, trackers: [String], maxTrackers: Int = 20) -> String? {
        guard let hash = DebridHash.normalize(infoHash) else { return nil }
        var result = "magnet:?xt=urn:btih:" + hash
        var seen = Set<String>()
        var used = 0
        for raw in trackers {
            if used >= maxTrackers { break }
            guard let tracker = cleanTracker(raw) else { continue }
            if seen.contains(tracker) { continue }
            seen.insert(tracker)
            result += "&tr=" + URIComponent.encode(tracker)
            used += 1
        }
        return result
    }

    static func cleanTracker(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("tracker:") {
            text = String(text.dropFirst(8))
        }
        guard !text.isEmpty, text.count <= 300 else { return nil }
        guard let separator = text.range(of: "://") else { return nil }
        let scheme = text[text.startIndex..<separator.lowerBound].lowercased()
        let allowed: Set<String> = ["udp", "http", "https", "ws", "wss"]
        guard allowed.contains(scheme) else { return nil }
        let rest = text[separator.upperBound...]
        guard !rest.isEmpty else { return nil }
        return text
    }
}
