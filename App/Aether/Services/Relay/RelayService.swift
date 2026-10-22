import SwiftUI
import UIKit
import AetherCore

/// What the relay needs from its server. `RelayServer` is the real one; tests use a fake.
protocol RelayServing: AnyObject {
    var port: UInt16? { get }
    var onFailure: (@Sendable () -> Void)? { get set }
    func start(preferredPort: UInt16?) async throws -> UInt16
    func stop()
    func url(host: String, token: String, leaf: String) -> URL?
}

extension RelayServer: RelayServing {}

/// What is published through the relay: where the video really is, and who it is for.
struct RelayPublishRequest {
    var upstream: RelayUpstream
    var contentType: String
    var fileExtension: String
    var owner: RelayOwner
    /// The receiver's address, when known: only that device may fetch the session.
    var receiverAddress: String?
    /// Convert the Matroska file into HLS on the fly, copying this audio track (nil: serve the file as it is).
    var remux: RemuxAudioChoice? = nil
}

/// A published session. Holds the keyless address handed to the receiver; it never prints.
struct RelayLease: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: RelaySessionID
    let url: URL
    /// What the conversion copies, when the lease serves a converted file.
    var remuxPlan: RemuxPlan? = nil

    static func == (lhs: RelayLease, rhs: RelayLease) -> Bool { return lhs.id == rhs.id }

    var description: String { return "RelayLease" }
    var debugDescription: String { return "RelayLease" }
    var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
}

@MainActor
protocol RelayPublishing: AnyObject {
    var availability: RelayAvailability { get }
    func publish(_ request: RelayPublishRequest) async throws -> RelayLease
    func release(_ lease: RelayLease, reason: RelayEndReason)
    func requestsServed(_ lease: RelayLease) -> Int
    /// The session ended by itself (the link expired, the network changed, the app was suspended for too long).
    var onLeaseLost: ((RelayLease, RelayEndReason) -> Void)? { get set }
}

/// Runs the relay for the app: starts the listener when something is published, stops it a little after the last session ended, and
/// ends the sessions when the phone changes network. The listener is never started at launch, so there is no open port and no
/// Local Network prompt until the viewer casts something that needs the relay.
@MainActor
final class RelayService: ObservableObject, RelayPublishing {
    typealias ServerFactory = (RelaySessionRegistry, RelayServer.Configuration, @escaping @Sendable (RelayLogEvent) -> Void) -> RelayServing
    typealias FetcherFactory = (RelayUpstream, UpstreamGuard) -> RelayRangeFetcher
    typealias RemuxMaker = RemuxEngineFactory.Maker

    @Published private(set) var leaseCount = 0
    /// The listener could not be started the last time it was tried.
    @Published private(set) var listenerFailed = false
    var onLeaseLost: ((RelayLease, RelayEndReason) -> Void)?

    private let settings: SettingsStore
    private let diagnostics: DiagnosticLog?
    private let lan: () -> LANInterface?
    private let serverFactory: ServerFactory
    private let fetcherFactory: FetcherFactory
    private let remuxMaker: RemuxMaker
    private let resolver: HostResolving
    private let idleStopDelay: TimeInterval
    private let watchInterval: TimeInterval
    private let registry = RelaySessionRegistry()

    private var server: RelayServing?
    private var boundAddress: String?
    private var lastPort: UInt16?
    private var leases: [RelaySessionID: RelayLease] = [:]
    private var idleTask: Task<Void, Never>?
    private var startTask: Task<UInt16, Error>?
    /// The Wi-Fi address the live leases' addresses were made for.
    private var leaseAddress: String?
    private var watchTask: Task<Void, Never>?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init(settings: SettingsStore,
         diagnostics: DiagnosticLog? = nil,
         lan: @escaping () -> LANInterface? = { LANAddressReader.current() },
         serverFactory: ServerFactory? = nil,
         fetcherFactory: FetcherFactory? = nil,
         remuxMaker: RemuxMaker? = nil,
         resolver: HostResolving = SystemHostResolver(),
         idleStopDelay: TimeInterval = 30,
         watchInterval: TimeInterval = 10) {
        self.settings = settings
        self.diagnostics = diagnostics
        self.lan = lan
        self.serverFactory = serverFactory ?? { registry, configuration, emit in RelayServer(registry: registry, configuration: configuration, log: emit) }
        self.fetcherFactory = fetcherFactory ?? { upstream, guardian in URLSessionRangeFetcher(upstream: upstream, guardian: guardian) }
        self.remuxMaker = remuxMaker ?? RemuxEngineFactory.standard
        self.resolver = resolver
        self.idleStopDelay = idleStopDelay
        self.watchInterval = watchInterval
        registry.observeRevocations { [weak self] id, reason in
            Task { @MainActor in self?.sessionEnded(id, reason) }
        }
    }

    // MARK: Availability

    /// Whether the relay can be used now: the viewer allows the local network and the phone has a Wi-Fi address.
    var availability: RelayAvailability {
        guard settings.value.privacy.allowLocalNetwork else { return .unavailable(.localNetworkDisabledInSettings) }
        guard let interface = lan() else { return .unavailable(.noLAN) }
        return .ready(interface)
    }

    // MARK: Publishing

    func publish(_ request: RelayPublishRequest) async throws -> RelayLease {
        guard case .ready(let interface) = availability else {
            if case .unavailable(let reason) = availability { throw CastError.relayUnavailable(RelayService.explain(reason)) }
            throw CastError.relayUnavailable(RelayService.explain(.noLAN))
        }
        idleTask?.cancel()
        idleTask = nil

        let upstreamURL = request.upstream.url
        let allowPrivate = settings.value.privacy.allowLocalNetwork && RelayService.isLocalSource(upstreamURL)
        let guardian = UpstreamGuard(allowPrivateOrigin: allowPrivate, selfAddresses: [interface.address], resolver: resolver)
        do {
            try await guardian.validateOrigin(upstreamURL)
        } catch {
            emit(.upstreamFailure(RelaySessionID(label: "------"), .blocked))
            scheduleIdleStopIfNeeded()
            throw CastError.relayUnavailable("L'indirizzo della sorgente non è consentito al ponte.")
        }

        let identity = SessionIdentity()
        let prepared: (source: RelaySource, sessionLeaf: String?, urlLeaf: String, plan: RemuxPlan?)
        if let audio = request.remux {
            prepared = try await prepareConverted(request, audio: audio, guardian: guardian)
        } else {
            prepared = try await prepareFile(request, guardian: guardian, identity: identity)
        }
        let source = prepared.source
        let leaf = prepared.urlLeaf

        do {
            _ = try await startServer(for: interface)
        } catch {
            source.close()
            listenerFailed = true
            scheduleIdleStopIfNeeded()
            throw CastError.relayUnavailable(RelayService.explain(.listenerFailed))
        }

        registry.ownAddress = interface.address
        let created: (id: RelaySessionID, token: String)
        do {
            created = try registry.create(source: source, leaf: prepared.sessionLeaf, owner: request.owner,
                                          peerRule: RelayService.peerRule(for: request.receiverAddress))
        } catch {
            source.close()
            scheduleIdleStopIfNeeded()
            throw CastError.relayUnavailable("Il ponte sta già servendo altre trasmissioni: fermane una e riprova.")
        }
        identity.id = created.id
        guard let url = server?.url(host: interface.address, token: created.token, leaf: leaf) else {
            registry.revoke(created.id, reason: .loadFailed)
            throw CastError.relayUnavailable(RelayService.explain(.listenerFailed))
        }
        let lease = RelayLease(id: created.id, url: url, remuxPlan: prepared.plan)
        if leases.isEmpty { leaseAddress = interface.address }
        leases[created.id] = lease
        leaseCount = leases.count
        emit(.sessionCreated(created.id, request.owner))
        startWatching()
        return lease
    }

    /// A file served as it is: the real source is read in windows and handed on.
    private func prepareFile(_ request: RelayPublishRequest, guardian: UpstreamGuard,
                             identity: SessionIdentity) async throws -> (source: RelaySource, sessionLeaf: String?, urlLeaf: String, plan: RemuxPlan?) {
        let leaf = "video." + (RelayMime.allowedExtensions.contains(request.fileExtension.lowercased()) ? request.fileExtension.lowercased() : "mp4")
        let source = HTTPRangeSource(leaf: leaf, contentType: request.contentType, fetcher: fetcherFactory(request.upstream, guardian),
                                     onUpstreamRejected: { [weak self] _ in
                                         Task { @MainActor in self?.upstreamRejected(identity.id) }
                                     })
        do {
            try await source.prepare()
        } catch {
            source.close()
            scheduleIdleStopIfNeeded()
            throw CastError.relayUnavailable(RelayService.probeMessage(for: error))
        }
        return (source, leaf, leaf, nil)
    }

    /// A Matroska file converted into HLS on the fly. The session accepts every piece name the converted file has.
    private func prepareConverted(_ request: RelayPublishRequest, audio: RemuxAudioChoice,
                                  guardian: UpstreamGuard) async throws -> (source: RelaySource, sessionLeaf: String?, urlLeaf: String, plan: RemuxPlan?) {
        let fetcher = fetcherFactory(request.upstream, guardian)
        var source: RemuxSource?
        do {
            let resource = try await fetcher.probe()
            guard let total = resource.length, total > 0 else { throw RelayError.upstreamNoRanges }
            guard let engine = remuxMaker(fetcher, total, audio) else { throw LocalRemuxError.unavailable }
            let made = RemuxSource(engine: engine)
            source = made
            let prepared = try await made.prepare()
            return (made, nil, RemuxSource.Leaf.masterName, prepared.plan)
        } catch {
            source?.close()
            fetcher.invalidate()
            scheduleIdleStopIfNeeded()
            if error is RemuxError || error is LocalRemuxError { throw CastError.conversionRefused(RemuxFailureText.explain(error)) }
            throw CastError.relayUnavailable(RelayService.probeMessage(for: error))
        }
    }

    func release(_ lease: RelayLease, reason: RelayEndReason) {
        guard leases.removeValue(forKey: lease.id) != nil else { return }
        leaseCount = leases.count
        registry.revoke(lease.id, reason: reason)
        scheduleIdleStopIfNeeded()
    }

    func requestsServed(_ lease: RelayLease) -> Int {
        return registry.requestsServed(lease.id)
    }

    /// Ends everything (the app is closing or the viewer turned the relay off).
    func shutdown() {
        registry.revokeAll(reason: .appClosing)
        stopServer()
    }

    // MARK: Server

    private func startServer(for interface: LANInterface) async throws -> UInt16 {
        // Two publishes can reach this point while the first listener is still starting: the second waits for it instead of making
        // another one on the same registry (which nothing would ever stop).
        while let pending = startTask {
            _ = try? await pending.value
        }
        if let running = server, boundAddress == interface.address, let port = running.port { return port }
        if server != nil { stopServer() }
        let task = Task { try await self.launchServer(for: interface) }
        startTask = task
        return try await task.value
    }

    private func launchServer(for interface: LANInterface) async throws -> UInt16 {
        defer { startTask = nil }
        let configuration = RelayServer.Configuration(bindAddress: interface.address, lan: interface)
        let created = serverFactory(registry, configuration, emitter())
        created.onFailure = { [weak self, weak created] in
            Task { @MainActor in
                if let self = self, let created = created { self.serverFailed(created) }
            }
        }
        let port: UInt16
        do {
            port = try await created.start(preferredPort: lastPort)
        } catch {
            // The old port may be taken: any port will do for a new session, only a running one must keep its port.
            if lastPort != nil && leases.isEmpty {
                lastPort = nil
                port = try await created.start(preferredPort: nil)
            } else {
                throw error
            }
        }
        server = created
        boundAddress = interface.address
        lastPort = port
        listenerFailed = false
        return port
    }

    private func stopServer() {
        server?.stop()
        server = nil
        boundAddress = nil
    }

    /// The listener stopped by itself (the system took the socket away while the app was suspended). Sessions survive if it can be
    /// started again on the same port with the same registry; if not they end.
    private func serverFailed(_ failed: RelayServing) {
        guard server === failed else { return }
        server = nil
        boundAddress = nil
        guard !leases.isEmpty else { return }
        Task { await resumeIfNeeded() }
    }

    func resumeIfNeeded() async {
        guard !leases.isEmpty, server == nil else { return }
        // The addresses the receivers were given belong to the Wi-Fi address they were made for: on another one nothing can be resumed.
        guard let interface = lan(), interface.address == (leaseAddress ?? interface.address) else {
            endAllLeases(.addressChanged)
            return
        }
        do {
            _ = try await startServer(for: interface)
            emit(.listener(.restarted(port: lastPort ?? 0)))
        } catch {
            listenerFailed = true
            endAllLeases(.addressChanged)
        }
    }

    // MARK: Network and scene

    /// Call when the phone's network may have changed. The sessions' addresses are tied to the Wi-Fi address they were made for.
    func networkChanged() {
        guard !leases.isEmpty, let bound = leaseAddress ?? boundAddress else { return }
        if lan()?.address != bound { endAllLeases(.addressChanged) }
    }

    func appPhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard !leases.isEmpty, backgroundTask == .invalid else { return }
            // The system wants the task ended before this handler returns, not on a later turn of the main actor.
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "aether.relay") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundGrace() }
            }
        case .active:
            endBackgroundGrace()
            listenerFailed = false
            networkChanged()
            Task { await resumeIfNeeded() }
        default:
            break
        }
    }

    private func endBackgroundGrace() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func startWatching() {
        guard watchTask == nil else { return }
        let interval = UInt64(max(0.01, watchInterval) * 1_000_000_000)
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard let self = self, !Task.isCancelled else { return }
                if self.leases.isEmpty {
                    self.watchTask = nil
                    return
                }
                self.networkChanged()
            }
        }
    }

    private func endAllLeases(_ reason: RelayEndReason) {
        registry.revokeAll(reason: reason)
        stopServer()
    }

    // MARK: Registry callbacks

    private func sessionEnded(_ id: RelaySessionID, _ reason: RelayEndReason) {
        emit(.sessionRevoked(id, reason))
        guard let lease = leases.removeValue(forKey: id) else { return }
        leaseCount = leases.count
        scheduleIdleStopIfNeeded()
        switch reason {
        case .replaced, .userStopped, .receiverEnded, .loadFailed, .directLinkDisabled:
            break
        default:
            onLeaseLost?(lease, reason)
        }
    }

    private func upstreamRejected(_ id: RelaySessionID?) {
        guard let id = id else { return }
        registry.revoke(id, reason: .upstreamRejected)
    }

    private func scheduleIdleStopIfNeeded() {
        guard leases.isEmpty else { return }
        leaseAddress = nil
        endBackgroundGrace()
        idleTask?.cancel()
        let delay = UInt64(max(0, idleStopDelay) * 1_000_000_000)
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self = self, !Task.isCancelled, self.leases.isEmpty else { return }
            self.stopServer()
            self.idleTask = nil
        }
    }

    // MARK: Helpers

    private func emitter() -> @Sendable (RelayLogEvent) -> Void {
        let diagnostics = self.diagnostics
        return { event in diagnostics?.logDetached(event.level, "ponte", event.message) }
    }

    private func emit(_ event: RelayLogEvent) {
        diagnostics?.logDetached(event.level, "ponte", event.message)
    }

    private final class SessionIdentity: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RelaySessionID?

        var id: RelaySessionID? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    /// A source on the viewer's own network: an address of a private range or a local name.
    static func isLocalSource(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let literal = IPAddress.parse(host) { return literal.addressClass == .privateNetwork }
        return !host.contains(".") || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home") || host.hasSuffix(".home.arpa")
    }

    /// Only the receiver's own address may fetch a session, when it is known and plainly an IPv4 address.
    static func peerRule(for receiverAddress: String?) -> RelayPeerRule {
        guard let address = receiverAddress, case .v4? = IPAddress.parse(address), !address.contains(":") else { return .any }
        return .expected([address])
    }

    static func explain(_ reason: RelayUnavailableReason) -> String {
        return "Il ponte sul telefono non è disponibile: \(reason.message)."
    }

    static func probeMessage(for error: Error) -> String {
        switch RelayError.mapping(error) {
        case .upstreamNoRanges:
            return "Questa sorgente non permette di leggere il video a pezzi, quindi il telefono non può inoltrarla al televisore."
        case .upstreamUnreachable:
            return "Il telefono non riesce a raggiungere la sorgente. Controlla la connessione a Internet."
        case .upstreamRejected(let status) where [401, 403, 404, 410].contains(status):
            return "Il link del servizio è scaduto. Riapri la sorgente per ottenerne uno nuovo."
        default:
            return "La sorgente ha risposto in modo inatteso e non può essere inoltrata."
        }
    }
}
