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

        static func == (lhs: Session, rhs: Session) -> Bool {
            lhs.device == rhs.device && lhs.title == rhs.title && lhs.status == rhs.status
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
    private var backends: [CastTarget: CastBackend]
    private var started = false
    private var stopScanTask: Task<Void, Never>?

    /// The real backends are created lazily-cheap (no discovery until asked); tests inject fakes.
    init(settings: SettingsStore, googleCast: CastBackend? = nil, dlna: CastBackend? = nil) {
        self.settings = settings
        let google = googleCast ?? GoogleCastBackend()
        let upnp = dlna ?? DLNABackend()
        self.googleCast = google
        self.dlna = upnp
        backends = [.googleCast: google, .dlna: upnp]
        for backend in backends.values { wire(backend) }
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
        guard let backend = backends[device.target] else { throw CastError.unavailable("Protocollo non disponibile.") }
        if case .unavailable(let reason) = availability(of: device.target) { throw CastError.unavailable(reason) }
        lastError = nil
        if let current = session, current.device.target != device.target {
            await backends[current.device.target]?.endSession()
        }
        session = Session(device: device, title: media.title,
                          status: CastRemoteStatus(state: .connecting, position: media.startPosition, duration: nil),
                          startedAt: localPosition)
        do {
            try await backend.load(media, on: device)
        } catch {
            session = nil
            lastError = error.localizedDescription
            throw error
        }
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
            lastError = message
        }
        current.status = status
        session = current
        if status.state == .ended {
            let position = status.position
            session = nil
            Task { await backends[target]?.endSession() }
            onRemoteSessionEnded?(position, nil)
        }
    }

    private func remoteEnded(reason: String?, from target: CastTarget) {
        guard let current = session, current.device.target == target else { return }
        session = nil
        if let reason = reason { lastError = reason }
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
