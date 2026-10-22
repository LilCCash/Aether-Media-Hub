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

    var hasSession: Bool { return current != nil }

    /// Opens `upstream` for conversion and returns the address of its HLS on this phone. Throws `RemuxError`, `RelayError` or
    /// `LocalRemuxError`; `RemuxFailureText.explain` says it in Italian.
    func open(_ upstream: RelayUpstream, audio: RemuxAudioChoice) async throws -> Session {
        close()
        let scheme = upstream.url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw LocalRemuxError.notOnTheNetwork }

        let allowPrivate = settings.value.privacy.allowLocalNetwork && RelayService.isLocalSource(upstream.url)
        let guardian = UpstreamGuard(allowPrivateOrigin: allowPrivate, selfAddresses: [], resolver: resolver)
        do {
            try await guardian.validateOrigin(upstream.url)
        } catch {
            throw LocalRemuxError.blocked
        }

        let fetcher = fetcherFactory(upstream, guardian)
        var source: RemuxSource?
        do {
            let resource = try await fetcher.probe()
            guard let total = resource.length, total > 0 else { throw RelayError.upstreamNoRanges }
            guard let engine = engineMaker(fetcher, total, audio) else { throw LocalRemuxError.unavailable }
            let made = RemuxSource(engine: engine)
            source = made
            let prepared = try await made.prepare()

            let port = try await startServer()
            let created = try registry.create(source: made, leaf: nil, owner: .airPlay, peerRule: .any)
            guard let url = server?.url(host: "127.0.0.1", token: created.token, leaf: RemuxSource.Leaf.masterName), port > 0 else {
                registry.revoke(created.id, reason: .loadFailed)
                throw LocalRemuxError.unavailable
            }
            let session = Session(id: created.id, url: url, plan: prepared.plan)
            current = session
            diagnostics?.logDetached(.info, "remux", "Conversione MKV → HLS avviata (\(prepared.segments.count) pezzi)")
            return session
        } catch {
            source?.close()
            fetcher.invalidate()
            stopServerIfIdle()
            throw error
        }
    }

    /// Ends the conversion: the pieces already made are dropped and the file is no longer read.
    func close() {
        guard let session = current else { return }
        current = nil
        registry.revoke(session.id, reason: .userStopped)
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
        let port = try await created.start(preferredPort: nil)
        server = created
        return port
    }

    private func stopServerIfIdle() {
        guard current == nil else { return }
        server?.stop()
        server = nil
    }
}
