import SwiftUI
import AetherCore

/// Owns the casting backends and the single active remote session. The player UI only talks to this class.
/// AirPlay is deliberately not a backend: iOS exposes it through the system route picker and `AVPlayer`'s
/// external playback, which is more reliable than anything we could build.
@MainActor
final class CastCoordinator: ObservableObject {
    struct Session: Equatable {
        var device: CastDevice
        var title: String
        var status: CastRemoteStatus
        /// Where the local player was when the session started; used for diagnostics only.
        var startedAt: Double
        /// How the receiver was given the video.
        var delivery: CastDelivery = .direct

        static func == (lhs: Session, rhs: Session) -> Bool {
            lhs.device == rhs.device && lhs.title == rhs.title && lhs.status == rhs.status && lhs.delivery == rhs.delivery
        }
    }

    @Published private(set) var devices: [CastDevice] = []
    @Published private(set) var session: Session?
    @Published private(set) var lastError: String?
    @Published private(set) var isScanning = false
    @Published private(set) var scanNotes: [String] = []

    /// Called when a remote session ends, with the last known remote position, so the player can resume locally.
    var onRemoteSessionEnded: ((_ position: Double, _ reason: String?) -> Void)?

    private let settings: SettingsStore
    private let googleCast: CastBackend
    private let dlna: CastBackend
    private let relay: RelayPublishing?
    private var backends: [CastTarget: CastBackend]
    private var started = false
    private var stopScanTask: Task<Void, Never>?
    /// The relay session of the current remote session, if it goes through the relay.
    private var lease: RelayLease?

    /// The real backends are created lazily-cheap (no discovery until asked); tests inject fakes.
    init(settings: SettingsStore, googleCast: CastBackend? = nil, dlna: CastBackend? = nil, relay: RelayPublishing? = nil) {
        self.settings = settings
        self.relay = relay
        let google = googleCast ?? GoogleCastBackend()
        let upnp = dlna ?? DLNABackend()
        self.googleCast = google
        self.dlna = upnp
        backends = [.googleCast: google, .dlna: upnp]
        for backend in backends.values { wire(backend) }
        relay?.onLeaseLost = { [weak self] lost, reason in self?.leaseLost(lost, reason: reason) }
    }

    private func wire(_ backend: CastBackend) {
        backend.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        backend.onStatus = { [weak self] status in self?.remoteStatus(status, from: backend.target) }
        backend.onSessionEnded = { [weak self] reason in self?.remoteEnded(reason: reason, from: backend.target) }
    }

    /// Cheap on purpose: discovery (and with it the Local Network permission prompt) starts only when the user
    /// opens a casting screen.
    func start() {
        started = true
        applySettings(settings.value.casting)
    }

    func settingsDidChange(_ new: CastingSettings) {
        guard started else { return }
        applySettings(new)
    }

    private func applySettings(_ casting: CastingSettings) {
        if let upnp = dlna as? DLNABackend {
            upnp.manualHosts = casting.manualDLNAHosts
            upnp.ssdpEnabled = casting.ssdpDiscoveryEnabled
        }
        devicesChanged()
    }

    // MARK: Availability

    func availability(of target: CastTarget) -> CastAvailability {
        switch target {
        case .airPlay:
            return settings.value.casting.airPlayEnabled ? .available : .unavailable("Disattivato nelle impostazioni.")
        case .googleCast:
            guard settings.value.casting.googleCastEnabled else { return .unavailable("Disattivato nelle impostazioni.") }
            return googleCast.availability
        case .dlna:
            return settings.value.casting.dlnaEnabled ? dlna.availability : .unavailable("Disattivato nelle impostazioni.")
        }
    }

    var statusSummary: String {
        if let session = session { return "Su \(session.device.name)" }
        let enabled = [CastTarget.airPlay, .googleCast, .dlna].filter { availability(of: $0) == .available }
        return enabled.isEmpty ? "Disattivato" : enabled.map { $0.title }.joined(separator: ", ")
    }

    var dlnaScanNote: String? { (dlna as? DLNABackend)?.lastScanNote }

    // MARK: Discovery

    func beginDiscovery() {
        stopScanTask?.cancel()
        scanNotes = []
        let casting = settings.value.casting
        isScanning = true
        if casting.googleCastEnabled { googleCast.startDiscovery() }
        if casting.dlnaEnabled { dlna.startDiscovery() }
        // Discovery is a battery cost: stop it after a while unless the screen asks again.
        stopScanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            if !Task.isCancelled { self?.endDiscovery() }
        }
    }

    func endDiscovery() {
        stopScanTask?.cancel()
        googleCast.stopDiscovery()
        dlna.stopDiscovery()
        isScanning = false
    }

    private func devicesChanged() {
        let casting = settings.value.casting
        var list: [CastDevice] = []
        if casting.googleCastEnabled { list += googleCast.devices }
        if casting.dlnaEnabled { list += dlna.devices }
        devices = list
        isScanning = googleCast.isDiscovering || dlna.isDiscovering
        scanNotes = [dlnaScanNote].compactMap { $0 }
    }

    // MARK: Session

    /// Sends `media` to `device`. Throws a user-presentable error; the caller keeps playing locally on failure.
    func cast(_ media: CastMedia, to device: CastDevice, localPosition: Double) async throws {
        let request = CastRequest(title: media.title, subtitle: media.subtitle, artworkURL: media.artworkURL, contentType: media.contentType,
                                  isLive: media.isLive, startPosition: media.startPosition, source: .direct(media.url))
        try await cast(request, to: device, localPosition: localPosition)
    }

    /// Sends a video to `device`, through the relay when the request says so. When the relay is needed and cannot be used, nothing is
    /// sent: the receiver is never given the real address as a fallback.
    func cast(_ request: CastRequest, to device: CastDevice, localPosition: Double) async throws {
        guard let backend = backends[device.target] else { throw CastError.unavailable("Protocollo non disponibile.") }
        if case .unavailable(let reason) = availability(of: device.target) { throw CastError.unavailable(reason) }
        lastError = nil
        let delivery = request.delivery
        if delivery == .directWithKey && !settings.value.advanced.sendDirectLinkToTV { throw CastError.directLinkNotAllowed }

        if let current = session, current.device.target != device.target {
            await backends[current.device.target]?.endSession()
        }
        // A session of this receiver's protocol is replaced by the new one; its relay session goes first.
        releaseLease(reason: .replaced)

        let url: URL
        var published: RelayLease?
        switch request.source {
        case .direct(let direct), .directWithKey(let direct):
            url = direct
        case .relay(let upstream):
            guard let relay = relay else { throw fail(CastError.relayUnavailable(RelayService.explain(.listenerFailed))) }
            do {
                let lease = try await relay.publish(RelayPublishRequest(upstream: upstream, contentType: request.contentType,
                                                                        fileExtension: request.fileExtension, owner: .cast(device.target),
                                                                        receiverAddress: device.address))
                published = lease
                url = lease.url
            } catch {
                throw fail(error)
            }
        }
        lease = published
        session = Session(device: device, title: request.title,
                          status: CastRemoteStatus(state: .connecting, position: request.startPosition, duration: nil),
                          startedAt: localPosition, delivery: delivery)
        do {
            try await backend.load(request.media(url: url), on: device)
        } catch {
            let explained = explanation(for: error.localizedDescription, lease: published)
            releaseLease(reason: .loadFailed)
            session = nil
            lastError = explained
            if explained == error.localizedDescription { throw error }
            throw CastError.rejected(explained)
        }
    }

    /// Records an error for the screens and returns it for throwing.
    private func fail(_ error: Error) -> Error {
        lastError = error.localizedDescription
        return error
    }

    /// When the receiver failed and never asked the relay for a single byte, it most likely cannot reach the phone.
    private func explanation(for message: String, lease: RelayLease?) -> String {
        guard let lease = lease, let relay = relay, relay.requestsServed(lease) == 0 else { return message }
        return "Il televisore non è riuscito a collegarsi al telefono. Controlla che in Impostazioni di iOS ▸ Aether il permesso «Rete locale» sia attivo, che telefono e televisore siano sulla stessa rete Wi-Fi (alcuni router isolano i dispositivi) e che nessuna VPN sia attiva."
    }

    private func releaseLease(reason: RelayEndReason) {
        guard let current = lease else { return }
        lease = nil
        relay?.release(current, reason: reason)
    }

    /// The relay ended a session by itself: the receiver has nothing to read any more.
    private func leaseLost(_ lost: RelayLease, reason: RelayEndReason) {
        guard lease == lost else { return }
        lease = nil
        let position = session?.status.position ?? 0
        let target = session?.device.target
        session = nil
        lastError = reason == .upstreamRejected
            ? "Il link del servizio è scaduto. Riapri la sorgente per ottenerne uno nuovo."
            : "Il ponte si è interrotto (il telefono ha cambiato rete o Aether è stato sospeso). Riprova la trasmissione."
        if let target = target { Task { await backends[target]?.endSession() } }
        onRemoteSessionEnded?(position, lastError)
    }

    /// The Advanced settings changed. Turning the direct link off ends a session that was started with it.
    func advancedDidChange(_ new: AdvancedSettings) {
        guard !new.sendDirectLinkToTV, let current = session, current.delivery == .directWithKey else { return }
        let position = current.status.position
        session = nil
        lastError = "Trasmissione interrotta: il link diretto è stato disattivato."
        Task { await backends[current.device.target]?.endSession() }
        onRemoteSessionEnded?(position, lastError)
    }

    func play() { Task { await activeBackend()?.play() } }
    func pause() { Task { await activeBackend()?.pause() } }

    func seek(to seconds: Double) {
        session?.status.position = seconds
        Task { await activeBackend()?.seek(to: seconds) }
    }

    func seek(by delta: Double) {
        guard let session = session else { return }
        seek(to: max(0, session.status.position + delta))
    }

    func stop() {
        guard let current = session else { return }
        let position = current.status.position
        session = nil
        releaseLease(reason: .userStopped)
        Task { await backends[current.device.target]?.endSession() }
        onRemoteSessionEnded?(position, nil)
    }

    private func activeBackend() -> CastBackend? {
        guard let session = session else { return nil }
        return backends[session.device.target]
    }

    private func remoteStatus(_ status: CastRemoteStatus, from target: CastTarget) {
        guard var current = session, current.device.target == target else { return }
        if case .failed(let message) = status.state {
            lastError = explanation(for: message, lease: lease)
        }
        current.status = status
        session = current
        if status.state == .ended {
            let position = status.position
            session = nil
            releaseLease(reason: .receiverEnded)
            Task { await backends[target]?.endSession() }
            onRemoteSessionEnded?(position, nil)
        }
    }

    private func remoteEnded(reason: String?, from target: CastTarget) {
        guard let current = session, current.device.target == target else { return }
        session = nil
        if let reason = reason { lastError = explanation(for: reason, lease: lease) }
        releaseLease(reason: .receiverEnded)
        onRemoteSessionEnded?(current.status.position, reason)
    }
}

// MARK: - Media description helpers

extension CastMedia {
    static func contentType(forContainer container: String?) -> String {
        switch container ?? "" {
        case "m3u8": return "application/x-mpegURL"
        case "mpd": return "application/dash+xml"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "ts": return "video/mp2t"
        default: return "video/mp4"
        }
    }
}
