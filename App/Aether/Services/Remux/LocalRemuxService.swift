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

    var hasSession: Bool { return current != nil || liveSession != nil }

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
        guard isFile || scheme == "http" || scheme == "https" else { throw LocalRemuxError.notOnTheNetwork }

        let allowPrivate = settings.value.privacy.allowLocalNetwork && RelayService.isLocalSource(upstream.url)
        let guardian = UpstreamGuard(allowPrivateOrigin: allowPrivate, selfAddresses: [], resolver: resolver)
        if !isFile {
            do {
                try await guardian.validateOrigin(upstream.url)
            } catch {
                throw LocalRemuxError.blocked
            }
        }
        guard epoch == openEpoch else { throw CancellationError() }

        let fetcher: RelayRangeFetcher = isFile ? FileRangeFetcher(url: upstream.url) : fetcherFactory(upstream, guardian)
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
        guard current != nil || liveSession != nil, !restartingServer else { return }
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
        guard current == nil, liveSession == nil else { return }
        server?.stop()
        server = nil
    }
}
