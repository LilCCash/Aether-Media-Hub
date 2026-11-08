import Foundation
import AetherCore

/// Why the phone could not convert a file for its own player.
enum LocalRemuxError: Error, Equatable {
    /// This build has no converter.
    case unavailable
    /// The file's address is not one the app may read.
    case blocked
    /// The player asked for a file that is not on the network (a download).
    case notOnTheNetwork

    var message: String {
        switch self {
        case .unavailable: return "La conversione dei file MKV non è inclusa in questa versione."
        case .blocked: return "L'indirizzo della sorgente non è consentito."
        case .notOnTheNetwork: return "I file scaricati non si possono convertire al volo."
        }
    }
}

/// Converts a Matroska file into HLS for the phone's own player (AVPlayer): the pieces are made on demand and served by a small
/// server that listens on this phone only (127.0.0.1), so playing a converted file needs neither Wi-Fi nor the Local Network
/// permission. One file at a time.
///
/// When the picture has to reach an AirPlay receiver the receiver must be able to fetch the pieces, and 127.0.0.1 is not an address it
/// can use: the player then moves the file to the relay on the Wi-Fi address (`RelayService`).
@MainActor
final class LocalRemuxService {
    struct Session: Equatable {
        let id: RelaySessionID
        let url: URL
        let plan: RemuxPlan

        static func == (lhs: Session, rhs: Session) -> Bool { return lhs.id == rhs.id }
    }

    typealias FetcherFactory = (RelayUpstream, UpstreamGuard) -> RelayRangeFetcher

    private let settings: SettingsStore
    private let diagnostics: DiagnosticLog?
    private let resolver: HostResolving
    private let engineMaker: RemuxEngineFactory.Maker
    private let fetcherFactory: FetcherFactory
    private let serverFactory: RelayService.ServerFactory
    private let registry = RelaySessionRegistry()

    private var server: RelayServing?
    private var current: Session?
    /// The live channel being converted, if one is.
    private var liveSession: RelaySessionID?
    /// A video read from inside a ZIP, offered as a file of its own.
    private var archiveSession: RelaySessionID?
    private var currentFetcher: RelayRangeFetcher?
    /// The port the playlist address was made with: a restarted listener must take the same one, or the player's address is dead.
    private var lastPort: UInt16?
    private var restartingServer = false
    /// Counts the starts and ends of a conversion: an `open` that finds the count changed while it was waiting has been
    /// replaced (another file was asked for) or cancelled (the player closed), and gives up without touching the newer session.
    private var openEpoch = 0

    init(settings: SettingsStore,
         diagnostics: DiagnosticLog? = nil,
         resolver: HostResolving = SystemHostResolver(),
         engineMaker: RemuxEngineFactory.Maker? = nil,
         fetcherFactory: FetcherFactory? = nil,
         serverFactory: RelayService.ServerFactory? = nil) {
        self.settings = settings
        self.diagnostics = diagnostics
        self.resolver = resolver
        self.engineMaker = engineMaker ?? RemuxEngineFactory.standard
        self.fetcherFactory = fetcherFactory ?? { upstream, guardian in URLSessionRangeFetcher(upstream: upstream, guardian: guardian) }
        self.serverFactory = serverFactory ?? { registry, configuration, emit in RelayServer(registry: registry, configuration: configuration, log: emit) }
    }

    var hasSession: Bool { return current != nil || liveSession != nil || archiveSession != nil }

    /// What was found inside an archive.
    struct ArchiveVideo {
        let url: URL
        let name: String
        let size: Int64
    }

    /// A video inside an archive: where its bytes are, in which file of the archive.
    struct LocatedArchiveVideo {
        let name: String
        let contentType: String
        let leaf: String
        let length: Int64
        /// (archive file, offset, length), in reading order: one piece in a ZIP or a single RAR, one per volume in a split RAR.
        let pieces: [(part: DebridArchivePart, offset: Int64, length: Int64)]
        let fetcher: RelayRangeFetcher
    }

    /// The fetcher, file name and type of the video read from an archive now, for the AirPlay address.
    private var archiveSource: (fetcher: RelayRangeFetcher, leaf: String, contentType: String)?

    /// Finds the video `query` asks for in the archive made of `parts` (a ZIP, or the volumes of a RAR in order) through ranged
    /// reads. Only a video stored without compression can be read this way (what packers do with video); otherwise it throws
    /// `DebridError.archivedFilesOnly`, and the log says why.
    func locateArchiveVideo(_ parts: [DebridArchivePart], query: TorBoxFileMatcher.Query) async throws -> LocatedArchiveVideo {
        guard let first = parts.first else { throw DebridError.archivedFilesOnly }
        let guardian = UpstreamGuard(allowPrivateOrigin: false, selfAddresses: [], resolver: resolver)
        var fetchers: [RelayRangeFetcher] = []
        var totals: [Int64] = []
        do {
            for part in parts {
                try await guardian.validateOrigin(part.url)
            }
        } catch {
            throw LocalRemuxError.blocked
        }
        do {
            for part in parts {
                let fetcher = fetcherFactory(RelayUpstream(url: part.url), guardian)
                fetchers.append(fetcher)
                let resource = try await fetcher.probe()
                guard let total = resource.length, total > 0 else { throw RelayError.upstreamNoRanges }
                totals.append(total)
            }
            let isZip = TorBoxFileMatcher.fileExtension(of: first.name) == "zip"
            var name = ""
            var pieces: [(part: DebridArchivePart, offset: Int64, length: Int64)] = []
            var pieceFetchers: [ConcatenatedRangeFetcher.Piece] = []
            if isZip {
                let fetcher = fetchers[0]
                let entries = try await ZipArchive.entries(total: totals[0]) { range in try await fetcher.fetch(range) }
                let videos = entries.filter { TorBoxFileMatcher.isVideo(TorBoxFile(id: 0, name: $0.name)) }
                diagnostics?.logDetached(.info, "torbox", "ZIP: \(entries.count) file, \(videos.count) video, \(videos.filter { $0.isStored }.count) senza compressione")
                guard let entry = ZipArchive.choose(entries, query: query) else {
                    diagnostics?.logDetached(.warning, "torbox", "ZIP: nessun episodio certo tra i video dell'archivio")
                    throw DebridError.noMatchingFile(candidates: [])
                }
                name = String(entry.name.split(separator: "/").last ?? Substring(entry.name))
                guard entry.isStored, !entry.isEncrypted else {
                    diagnostics?.logDetached(.warning, "torbox", "ZIP: «\(name)» è compresso (metodo \(entry.method)\(entry.isEncrypted ? ", cifrato" : "")): non si può leggere a pezzi")
                    throw DebridError.archivedFilesOnly
                }
                let window = try await ZipArchive.window(of: entry, total: totals[0]) { range in try await fetcher.fetch(range) }
                pieces = [(first, window.offset, window.length)]
                pieceFetchers = [ConcatenatedRangeFetcher.Piece(fetcher: fetcher, offset: window.offset, length: window.length)]
            } else {
                // RAR: the first volume says which file, the others carry the rest of it.
                let firstFetcher = fetchers[0]
                let entries = try await RarArchive.entries(total: totals[0], fetch: { range in try await firstFetcher.fetch(range) },
                                                           firstFileOnly: parts.count > 1)
                let videos = entries.filter { !$0.isDirectory && TorBoxFileMatcher.isVideo(TorBoxFile(id: 0, name: $0.name)) }
                diagnostics?.logDetached(.info, "torbox", "RAR: \(parts.count) volumi, \(entries.count) file nel primo, \(videos.count) video, \(videos.filter { $0.isStored }.count) senza compressione")
                let files = videos.enumerated().map { index, entry in TorBoxFile(id: index, name: entry.name, size: entry.unpackedSize) }
                let pick: RarArchive.Entry?
                if videos.count == 1 {
                    pick = videos.first
                } else if case .selected(let file, _) = TorBoxFileMatcher.select(from: files, query: query), let index = file.id {
                    pick = videos[index]
                } else {
                    pick = nil
                }
                guard let entry = pick else {
                    diagnostics?.logDetached(.warning, "torbox", "RAR: nessun video certo nell'archivio")
                    throw DebridError.noMatchingFile(candidates: [])
                }
                name = String(entry.name.split(separator: "/").last ?? Substring(entry.name))
                guard entry.isStored, !entry.isEncrypted else {
                    diagnostics?.logDetached(.warning, "torbox", "RAR: «\(name)» è \(entry.isEncrypted ? "cifrato" : "compresso"): non si può leggere a pezzi")
                    throw DebridError.archivedFilesOnly
                }
                pieces.append((first, entry.dataOffset, entry.packedSize))
                pieceFetchers.append(ConcatenatedRangeFetcher.Piece(fetcher: firstFetcher, offset: entry.dataOffset, length: entry.packedSize))
                var continues = entry.continuesInNext
                var index = 1
                while continues && index < parts.count {
                    let fetcher = fetchers[index]
                    let next = try await RarArchive.entries(total: totals[index], fetch: { range in try await fetcher.fetch(range) }, firstFileOnly: true)
                    guard let piece = next.first, piece.name == entry.name, piece.continuesFromPrevious else {
                        diagnostics?.logDetached(.warning, "torbox", "RAR: il volume \(index + 1) non continua «\(name)»")
                        throw DebridError.archivedFilesOnly
                    }
                    pieces.append((parts[index], piece.dataOffset, piece.packedSize))
                    pieceFetchers.append(ConcatenatedRangeFetcher.Piece(fetcher: fetcher, offset: piece.dataOffset, length: piece.packedSize))
                    continues = piece.continuesInNext
                    index += 1
                }
                let read = pieces.map { $0.length }.reduce(0, +)
                guard !continues, read == entry.unpackedSize else {
                    diagnostics?.logDetached(.warning, "torbox", "RAR: «\(name)» incompleto (\(read) di \(entry.unpackedSize) byte nei volumi)")
                    throw DebridError.archivedFilesOnly
                }
            }
            let ext = TorBoxFileMatcher.fileExtension(of: name)
            let leaf = "video." + (RelayMime.allowedExtensions.contains(ext) ? ext : "mp4")
            let type = ext == "mkv" ? "video/x-matroska" : (ext == "avi" ? "video/x-msvideo" : "video/mp4")
            let length = pieces.map { $0.length }.reduce(0, +)
            let fetcher: RelayRangeFetcher = pieceFetchers.count == 1
                ? WindowRangeFetcher(base: pieceFetchers[0].fetcher, offset: pieceFetchers[0].offset, length: pieceFetchers[0].length, contentType: type)
                : ConcatenatedRangeFetcher(pieces: pieceFetchers, contentType: type)
            diagnostics?.logDetached(.info, "torbox", "\(isZip ? "ZIP" : "RAR"): episodio «\(name)», \(length / 1_048_576) MB in \(pieces.count) pezzi: lo leggo dall'interno")
            return LocatedArchiveVideo(name: name, contentType: type, leaf: leaf, length: length, pieces: pieces, fetcher: fetcher)
        } catch {
            for fetcher in fetchers { fetcher.invalidate() }
            if let failure = error as? ZipArchive.Failure {
                diagnostics?.logDetached(.warning, "torbox", "ZIP: indice non leggibile (\(failure))")
                throw DebridError.archivedFilesOnly
            }
            if let failure = error as? RarArchive.Failure {
                diagnostics?.logDetached(.warning, "torbox", "RAR: intestazioni non leggibili (\(failure))")
                throw DebridError.archivedFilesOnly
            }
            throw error
        }
    }

    /// Offers the video of the archive on this phone as a file of its own (`127.0.0.1/…/video.<ext>`): the player plays it and
    /// seeks in it as in any file.
    func openArchive(_ parts: [DebridArchivePart], query: TorBoxFileMatcher.Query) async throws -> ArchiveVideo {
        closeArchive()
        let located = try await locateArchiveVideo(parts, query: query)
        let source = HTTPRangeSource(leaf: located.leaf, contentType: located.contentType, fetcher: located.fetcher)
        do {
            try await source.prepare()
            _ = try await startServer()
            let created = try registry.create(source: source, leaf: located.leaf, owner: .player, peerRule: .any)
            guard let url = server?.url(host: "127.0.0.1", token: created.token, leaf: located.leaf) else {
                registry.revoke(created.id, reason: .loadFailed)
                throw LocalRemuxError.unavailable
            }
            archiveSession = created.id
            archiveSource = (located.fetcher, located.leaf, located.contentType)
            return ArchiveVideo(url: url, name: located.name, size: located.length)
        } catch {
            located.fetcher.invalidate()
            stopServerIfIdle()
            throw error
        }
    }

    /// The video read from an archive now, as a source for the relay on the Wi-Fi address (AirPlay). It shares the reading with
    /// the phone's own address: closing it does not stop the phone's player.
    func archiveRelaySource() -> RelaySource? {
        guard archiveSession != nil, let current = archiveSource else { return nil }
        let source = HTTPRangeSource(leaf: current.leaf, contentType: current.contentType, fetcher: SharedRangeFetcher(current.fetcher))
        return source
    }

    var archiveLeaf: String? { return archiveSession == nil ? nil : archiveSource?.leaf }

    /// Whether `url` is an address of this service's own server (127.0.0.1, its port, a live session).
    func serves(_ url: URL) -> Bool {
        guard archiveSession != nil || current != nil || liveSession != nil,
              let port = server?.port, url.host == "127.0.0.1", url.port == Int(port) else { return false }
        return url.scheme?.lowercased() == "http"
    }

    func closeArchive() {
        guard let session = archiveSession else { return }
        archiveSession = nil
        archiveSource = nil
        registry.revoke(session, reason: .userStopped)
        stopServerIfIdle()
    }

    /// Opens a live channel for conversion and returns the address of its live HLS on this phone, with the engine (which the relay
    /// can also serve on the Wi-Fi address for AirPlay). Throws `LiveRemuxError`, `LocalRemuxError` or a cancellation.
    func openLive(_ upstream: RelayUpstream, full: Bool) async throws -> (url: URL, engine: LiveRemuxEngine) {
        close()
        let epoch = openEpoch
        let scheme = upstream.url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw LocalRemuxError.notOnTheNetwork }
        guard RemuxEngineFactory.isAvailable else { throw LiveRemuxError.unavailable }
        let allowPrivate = settings.value.privacy.allowLocalNetwork && RelayService.isLocalSource(upstream.url)
        let guardian = UpstreamGuard(allowPrivateOrigin: allowPrivate, selfAddresses: [], resolver: resolver)
        do {
            try await guardian.validateOrigin(upstream.url)
        } catch {
            throw LocalRemuxError.blocked
        }
        guard epoch == openEpoch else { throw CancellationError() }
        let engine = LiveRemuxEngine(url: upstream.url, headers: upstream.headers, full: full)
        do {
            try await engine.start()
        } catch {
            engine.close()
            throw error
        }
        guard epoch == openEpoch else { engine.close(); throw CancellationError() }
        do {
            let port = try await startServer()
            guard epoch == openEpoch else { engine.close(); throw CancellationError() }
            let created = try registry.create(source: LiveRemuxSource(engine: engine), leaf: nil, owner: .airPlay, peerRule: .any)
            guard let url = server?.url(host: "127.0.0.1", token: created.token, leaf: "index.m3u8"), port > 0 else {
                registry.revoke(created.id, reason: .loadFailed)
                throw LocalRemuxError.unavailable
            }
            liveSession = created.id
            diagnostics?.logDetached(.info, "remux", "Conversione della diretta avviata: \(engine.summary)")
            return (url, engine)
        } catch {
            engine.close()
            if epoch == openEpoch { stopServerIfIdle() }
            throw error
        }
    }

    /// Opens `upstream` for conversion and returns the address of its HLS on this phone. Throws `RemuxError`, `RelayError` or
    /// `LocalRemuxError`; `RemuxFailureText.explain` says it in Italian.
    func open(_ upstream: RelayUpstream, audio: RemuxAudioChoice) async throws -> Session {
        close()
        let epoch = openEpoch
        let scheme = upstream.url.scheme?.lowercased() ?? ""
        // A finished download is a file on this phone: it is converted from the file, with no network and no origin check.
        let isFile = scheme == "file" && upstream.url.isFileURL
        // A video read from inside an archive is already served here: it is converted from the same reading.
        let ownArchive: RelayRangeFetcher? = (serves(upstream.url) ? archiveSource?.fetcher : nil).map { SharedRangeFetcher($0) }
        guard isFile || ownArchive != nil || scheme == "http" || scheme == "https" else { throw LocalRemuxError.notOnTheNetwork }

        let allowPrivate = settings.value.privacy.allowLocalNetwork && RelayService.isLocalSource(upstream.url)
        let guardian = UpstreamGuard(allowPrivateOrigin: allowPrivate, selfAddresses: [], resolver: resolver)
        if !isFile && ownArchive == nil {
            do {
                try await guardian.validateOrigin(upstream.url)
            } catch {
                throw LocalRemuxError.blocked
            }
        }
        guard epoch == openEpoch else { throw CancellationError() }

        let fetcher: RelayRangeFetcher = ownArchive ?? (isFile ? FileRangeFetcher(url: upstream.url) : fetcherFactory(upstream, guardian))
        var source: RemuxSource?
        do {
            let resource = try await fetcher.probe()
            guard epoch == openEpoch else { throw CancellationError() }
            guard let total = resource.length, total > 0 else { throw RelayError.upstreamNoRanges }
            guard let engine = engineMaker(fetcher, total, audio) else { throw LocalRemuxError.unavailable }
            let made = RemuxSource(engine: engine)
            source = made
            let prepared = try await made.prepare()
            guard epoch == openEpoch else { throw CancellationError() }

            let port = try await startServer()
            guard epoch == openEpoch else { throw CancellationError() }
            let created = try registry.create(source: made, leaf: nil, owner: .airPlay, peerRule: .any)
            guard let url = server?.url(host: "127.0.0.1", token: created.token, leaf: RemuxSource.Leaf.masterName), port > 0 else {
                registry.revoke(created.id, reason: .loadFailed)
                throw LocalRemuxError.unavailable
            }
            let session = Session(id: created.id, url: url, plan: prepared.plan)
            current = session
            currentFetcher = fetcher
            diagnostics?.logDetached(.info, "remux", "Conversione MKV → HLS avviata (\(prepared.segments.count) pezzi)")
            return session
        } catch {
            source?.close()
            fetcher.invalidate()
            // Only the newest start may stop the server: an older one that was replaced must leave it to its successor.
            if epoch == openEpoch { stopServerIfIdle() }
            throw error
        }
    }

    /// Ends the conversion: the pieces already made are dropped and the file is no longer read.
    func close() {
        openEpoch += 1
        if let live = liveSession {
            liveSession = nil
            registry.revoke(live, reason: .userStopped)
            stopServerIfIdle()
        }
        guard let session = current else { return }
        current = nil
        registry.revoke(session.id, reason: .userStopped)
        currentFetcher?.invalidate()
        currentFetcher = nil
        stopServerIfIdle()
    }

    func close(_ session: Session) {
        guard current == session else { return }
        close()
    }

    // MARK: Listener

    private func startServer() async throws -> UInt16 {
        if let running = server, let port = running.port { return port }
        let configuration = RelayServer.Configuration(bindAddress: "127.0.0.1", lan: nil, allowLoopbackPeers: true)
        let diagnostics = self.diagnostics
        let created = serverFactory(registry, configuration, { event in diagnostics?.logDetached(event.level, "remux", event.message) })
        created.onFailure = { [weak self, weak created] in
            Task { @MainActor in
                if let self = self, let created = created { self.serverFailed(created) }
            }
        }
        let port: UInt16
        do {
            port = try await created.start(preferredPort: lastPort)
        } catch {
            // The old port may be taken: any port will do for a new conversion; a conversion that is playing needs its own back.
            guard lastPort != nil, current == nil else { throw error }
            lastPort = nil
            port = try await created.start(preferredPort: nil)
        }
        server = created
        lastPort = port
        return port
    }

    /// The system takes a listening socket away from an app that was suspended (a paused video, a locked phone): when the viewer
    /// comes back the pieces must be served again on the same address.
    private func serverFailed(_ failed: RelayServing) {
        guard server === failed else { return }
        server = nil
        failed.stop()
        guard current != nil || liveSession != nil || archiveSession != nil, !restartingServer else { return }
        restartingServer = true
        diagnostics?.logDetached(.warning, "remux", "Il server locale si è fermato: lo riavvio")
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.restartingServer = false }
            do {
                _ = try await self.startServer()
            } catch {
                self.diagnostics?.logDetached(.warning, "remux", "Il server locale non riparte")
            }
        }
    }

    private func stopServerIfIdle() {
        guard current == nil, liveSession == nil, archiveSession == nil else { return }
        server?.stop()
        server = nil
    }
}
