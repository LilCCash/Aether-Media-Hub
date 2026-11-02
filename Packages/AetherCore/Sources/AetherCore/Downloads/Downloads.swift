import Foundation

public enum DownloadEligibility: Equatable, Sendable {
    case allowed(URL)
    case notAllowed(String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Only plain files served over http(s) can be downloaded. Streams (HLS/DASH), torrents, archives, YouTube and web
/// pages are refused up front instead of failing halfway.
public enum DownloadPlanner {
    public static func evaluate(stream: AddonStream, info: StreamInfo, allowLocalNetwork: Bool) -> DownloadEligibility {
        switch info.kind {
        case .file:
            break
        case .hls:
            return .notAllowed("Questo è un flusso HLS (playlist .m3u8): non è un file scaricabile.")
        case .dash:
            return .notAllowed("I flussi DASH non sono scaricabili.")
        case .torrent:
            return .notAllowed("I torrent non sono scaricabili da Aether.")
        case .youtube:
            return .notAllowed("I video YouTube non sono scaricabili.")
        case .externalPage, .playerFrame:
            return .notAllowed("Questa sorgente è una pagina web, non un file.")
        case .archive:
            return .notAllowed("Gli archivi/usenet richiedono il server Stremio e non sono scaricabili.")
        case .other:
            return .notAllowed("Sorgente non scaricabile.")
        }
        guard let url = stream.directURL else { return .notAllowed("URL della sorgente non valido.") }
        if case .unsupported(let reason) = info.support {
            return .notAllowed("Il file non sarebbe riproducibile offline. \(reason.message)")
        }
        switch CastCompatibility.hostKind(of: url) {
        case .loopback:
            return .notAllowed("L'indirizzo punta a questo dispositivo e non è scaricabile.")
        case .localNetwork:
            if !allowLocalNetwork {
                return .notAllowed("La sorgente è nella rete locale: abilita «Rete locale» nelle impostazioni.")
            }
        case .publicInternet:
            if url.scheme?.lowercased() == "http" {
                return .notAllowed("La sorgente usa HTTP non cifrato: iOS blocca i download in background verso Internet (App Transport Security).")
            }
        }
        return .allowed(url)
    }
}

public enum DownloadState: String, Codable, Sendable {
    case queued, downloading, paused, completed, failed
}

public struct DownloadItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var metaID: String
    public var videoID: String?
    public var type: String
    public var title: String
    public var subtitle: String?
    public var poster: String?
    public var sourceURL: String
    public var headers: [String: String]
    public var state: DownloadState
    public var bytesWritten: Int64
    public var totalBytes: Int64
    /// File name inside the app's Downloads directory (never an absolute path: containers move between installs).
    public var localFileName: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    /// Intro / recap of an episode kept with the file, so the skip button also works offline (seconds from the start).
    public var introStart: Double?
    public var introEnd: Double?
    public var recapStart: Double?
    public var recapEnd: Double?
    /// True once the skip data was looked up successfully (even if the episode has none): no more lookups for this file.
    public var skipChecked: Bool?

    public init(id: UUID = UUID(), metaID: String, videoID: String?, type: String, title: String, subtitle: String? = nil,
                poster: String? = nil, sourceURL: String, headers: [String: String] = [:],
                state: DownloadState = .queued, bytesWritten: Int64 = 0, totalBytes: Int64 = 0,
                localFileName: String? = nil, createdAt: Date = Date(), completedAt: Date? = nil,
                errorMessage: String? = nil) {
        self.id = id
        self.metaID = metaID
        self.videoID = videoID
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.poster = poster
        self.sourceURL = sourceURL
        self.headers = headers
        self.state = state
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.localFileName = localFileName
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return max(0, min(1, Double(bytesWritten) / Double(totalBytes)))
    }

    public var isFinished: Bool { return state == .completed }

    /// Season and episode of a series episode whose video id is `tt…:season:episode`; nil for a film.
    public var episodeCoordinates: (season: Int, episode: Int)? {
        guard let videoID = videoID else { return nil }
        let parts = videoID.split(separator: ":")
        guard parts.count >= 3, let episode = Int(parts[parts.count - 1]), let season = Int(parts[parts.count - 2]) else { return nil }
        return (season, episode)
    }

    /// The skippable parts kept with the file, or nil when none are stored.
    public var storedSkipSegments: EpisodeSkipSegments? {
        var found = EpisodeSkipSegments()
        if let start = introStart, let end = introEnd, end > start { found.intro = SkipSegment(kind: .intro, start: start, end: end) }
        if let start = recapStart, let end = recapEnd, end > start { found.recap = SkipSegment(kind: .recap, start: start, end: end) }
        return found.isEmpty ? nil : found
    }

    public mutating func store(skipSegments segments: EpisodeSkipSegments) {
        introStart = segments.intro?.start
        introEnd = segments.intro?.end
        recapStart = segments.recap?.start
        recapEnd = segments.recap?.end
        skipChecked = true
    }
}

/// What a file really is, from its first bytes: a download saved as ".mp4" can hold Matroska (the server sent no useful type),
/// and AVPlayer then refuses it while MPV, which looks inside, plays it.
public enum ContainerSniffer {
    public static func container(header: Data) -> String? {
        let b = [UInt8](header.prefix(16))
        guard b.count >= 12 else { return nil }
        if b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            // EBML: Matroska or WebM (the doc type sits near the start).
            let text = String(decoding: header.prefix(64), as: UTF8.self)
            return text.contains("webm") ? "webm" : "mkv"
        }
        if b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {   // "ftyp"
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            return brand.hasPrefix("qt") ? "mov" : "mp4"
        }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x41, b[9] == 0x56, b[10] == 0x49 { return "avi" }
        return nil
    }

    public static func container(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64) else { return nil }
        return container(header: data)
    }
}

public struct DownloadStoreState: Codable, Sendable {
    public var items: [DownloadItem]

    public init(items: [DownloadItem] = []) {
        self.items = items
    }
}

/// Persistent list of downloads. File transfer is performed by the app (background `URLSession`).
public actor DownloadStore {
    private let store: JSONFileStore<DownloadStoreState>
    private var items: [DownloadItem] = []
    private var loaded = false

    public init(store: JSONFileStore<DownloadStoreState>) {
        self.store = store
    }

    private func load() {
        if loaded { return }
        loaded = true
        items = store.load()?.items ?? []
    }

    public func all() -> [DownloadItem] {
        load()
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    public func item(id: UUID) -> DownloadItem? {
        load()
        return items.first(where: { $0.id == id })
    }

    /// An existing non-failed download of the same title/video, to avoid duplicates.
    public func existing(metaID: String, videoID: String?) -> DownloadItem? {
        load()
        return items.first(where: { $0.metaID == metaID && $0.videoID == videoID && $0.state != .failed })
    }

    public func add(_ item: DownloadItem) {
        load()
        items.removeAll(where: { $0.id == item.id })
        items.append(item)
        persist()
    }

    public func update(id: UUID, _ change: (inout DownloadItem) -> Void) {
        load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        persist()
    }

    @discardableResult
    public func remove(id: UUID) -> DownloadItem? {
        load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        persist()
        return removed
    }

    public func removeAll() {
        load()
        items = []
        persist()
    }

    public func totalBytesOnDisk() -> Int64 {
        load()
        return items.filter { $0.state == .completed }.reduce(0) { $0 + $1.totalBytes }
    }

    private func persist() {
        try? store.save(DownloadStoreState(items: items))
    }
}
