import Foundation
import AetherCore

// Google Cast through Google's official iOS sender SDK (binary, proprietary licence; see docs/03-LICENSES.md).
// The Default Media Receiver (CC1AD845) plays MP4/WebM/HLS/DASH URLs without any receiver app of our own.
// The SDK is initialised lazily: creating the Cast context starts Bonjour discovery and triggers the iOS
// "Local Network" permission prompt, which we do not want at launch.

#if canImport(GoogleCast)
import GoogleCast

@MainActor
final class GoogleCastBackend: NSObject, CastBackend {
    let target = CastTarget.googleCast
    var availability: CastAvailability { .available }
    private(set) var devices: [CastDevice] = []
    private(set) var isDiscovering = false
    var onDevicesChanged: (() -> Void)?
    var onStatus: ((CastRemoteStatus) -> Void)?
    var onSessionEnded: ((String?) -> Void)?

    private var contextReady = false
    private var knownDevices: [String: GCKDevice] = [:]
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var pendingDevice: CastDevice?
    private var pollTimer: Timer?
    private var loadWatchdog: Task<Void, Never>?
    private var loadedStartedPlaying = false
    private weak var observedClient: GCKRemoteMediaClient?

    private func ensureContext() {
        guard !contextReady else { return }
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.disableDiscoveryAutostart = true
        options.startDiscoveryAfterFirstTapOnCastButton = false
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        GCKCastContext.setSharedInstanceWith(options)
        let context = GCKCastContext.sharedInstance()
        context.discoveryManager.add(self)
        context.sessionManager.add(self)
        contextReady = true
    }

    // MARK: Discovery

    func startDiscovery() {
        ensureContext()
        GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
        isDiscovering = true
        refreshDevices()
    }

    func stopDiscovery() {
        guard contextReady else { return }
        GCKCastContext.sharedInstance().discoveryManager.stopDiscovery()
        isDiscovering = false
    }

    fileprivate func refreshDevices() {
        guard contextReady else { return }
        let manager = GCKCastContext.sharedInstance().discoveryManager
        var list: [CastDevice] = []
        var table: [String: GCKDevice] = [:]
        for index in 0..<manager.deviceCount {
            let device = manager.device(at: index)
            let id = device.deviceID
            table[id] = device
            let friendly = device.friendlyName ?? "Dispositivo Cast"
            let ip = device.networkAddress.ipAddress
            list.append(CastDevice(id: id, name: friendly, target: .googleCast, detail: device.modelName,
                                   address: ip.isEmpty ? nil : ip))
        }
        knownDevices = table
        devices = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onDevicesChanged?()
    }

    // MARK: Session

    func load(_ media: CastMedia, on device: CastDevice) async throws {
        ensureContext()
        guard let gckDevice = knownDevices[device.id] else {
            throw CastError.deviceUnreachable("Il dispositivo «\(device.name)» non è più visibile nella rete.")
        }
        let sessionManager = GCKCastContext.sharedInstance().sessionManager
        if let current = sessionManager.currentCastSession, current.device.deviceID == device.id {
            // Already connected to this receiver: just load.
        } else {
            if sessionManager.hasConnectedCastSession() {
                sessionManager.endSessionAndStopCasting(true)
            }
            try await connect(to: gckDevice, named: device)
        }
        guard let client = sessionManager.currentCastSession?.remoteMediaClient else {
            throw CastError.rejected("Sessione Cast avviata ma il controllo remoto non è disponibile.")
        }
        attach(to: client)

        let builder = GCKMediaInformationBuilder(contentURL: media.url)
        builder.streamType = media.isLive ? .live : .buffered
        builder.contentType = media.contentType
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
        if let subtitle = media.subtitle { metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle) }
        if let artwork = media.artworkURL { metadata.addImage(GCKImage(url: artwork, width: 480, height: 720)) }
        builder.metadata = metadata

        let data = GCKMediaLoadRequestDataBuilder()
        data.mediaInformation = builder.build()
        data.autoplay = true
        if media.startPosition > 1 { data.startTime = media.startPosition }
        loadedStartedPlaying = false
        client.loadMedia(with: data.build())
        onStatus?(CastRemoteStatus(state: .loading, position: media.startPosition, duration: nil))
        startPolling()
        armWatchdog()
    }

    private func connect(to device: GCKDevice, named info: CastDevice) async throws {
        pendingDevice = info
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingConnect = continuation
            let started = GCKCastContext.sharedInstance().sessionManager.startSession(with: device)
            if !started {
                pendingConnect = nil
                continuation.resume(throwing: CastError.deviceUnreachable("Impossibile avviare la sessione con «\(info.name)»."))
                return
            }
            // The SDK reports success/failure through the listener; a hard timeout avoids hanging forever.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self = self, let pending = self.pendingConnect else { return }
                self.pendingConnect = nil
                pending.resume(throwing: CastError.deviceUnreachable("«\(info.name)» non risponde. Controlla che sia acceso e nella stessa rete Wi-Fi."))
            }
        }
    }

    private func attach(to client: GCKRemoteMediaClient) {
        if observedClient !== client {
            observedClient?.remove(self)
            client.add(self)
            observedClient = client
        }
    }

    private func armWatchdog() {
        loadWatchdog?.cancel()
        loadWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self = self, !Task.isCancelled, !self.loadedStartedPlaying else { return }
            self.onStatus?(CastRemoteStatus(state: .failed(CastError.timedOut.errorDescription ?? ""), position: 0, duration: nil))
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishStatus() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        loadWatchdog?.cancel()
    }

    fileprivate func publishStatus() {
        guard let client = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient,
              let status = client.mediaStatus else { return }
        let position = client.approximateStreamPosition()
        let duration = status.mediaInformation.map { $0.streamDuration }.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let state: CastPlayState
        switch status.playerState {
        case .playing: state = .playing; loadedStartedPlaying = true
        case .paused: state = .paused; loadedStartedPlaying = true
        case .buffering: state = .buffering
        case .loading: state = .loading
        case .idle:
            switch status.idleReason {
            case .finished: state = .ended
            case .error: state = .failed("Il televisore ha rifiutato il contenuto (formato non supportato o indirizzo non raggiungibile).")
            case .cancelled, .interrupted: state = .paused
            default: state = .loading
            }
        default: state = .loading
        }
        onStatus?(CastRemoteStatus(state: state, position: position, duration: duration))
    }

    // MARK: Transport

    private var client: GCKRemoteMediaClient? {
        guard contextReady else { return nil }
        return GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }

    func play() async { client?.play() }
    func pause() async { client?.pause() }

    func seek(to seconds: Double) async {
        let options = GCKMediaSeekOptions()
        options.interval = max(0, seconds)
        client?.seek(with: options)
    }

    func endSession() async {
        stopPolling()
        guard contextReady else { return }
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
    }
}

extension GoogleCastBackend: GCKDiscoveryManagerListener {
    nonisolated func didUpdateDeviceList() {
        Task { @MainActor in self.refreshDevices() }
    }

    nonisolated func didInsert(_ device: GCKDevice, at index: UInt) {
        Task { @MainActor in self.refreshDevices() }
    }

    nonisolated func didRemove(_ device: GCKDevice, at index: UInt) {
        Task { @MainActor in self.refreshDevices() }
    }
}

extension GoogleCastBackend: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        Task { @MainActor in
            self.pendingConnect?.resume()
            self.pendingConnect = nil
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKCastSession, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            self.pendingConnect?.resume(throwing: CastError.deviceUnreachable("Connessione al televisore non riuscita: \(message)"))
            self.pendingConnect = nil
        }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.stopPolling()
            self.observedClient?.remove(self)
            self.observedClient = nil
            self.onSessionEnded?(message)
        }
    }
}

extension GoogleCastBackend: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        Task { @MainActor in self.publishStatus() }
    }
}

#else

/// Compiled when the Google Cast SDK is not linked (for instance a build without package access).
@MainActor
final class GoogleCastBackend: CastBackend {
    let target = CastTarget.googleCast
    var availability: CastAvailability { .unavailable("Questa build non include il Google Cast SDK.") }
    let devices: [CastDevice] = []
    let isDiscovering = false
    var onDevicesChanged: (() -> Void)?
    var onStatus: ((CastRemoteStatus) -> Void)?
    var onSessionEnded: ((String?) -> Void)?
    func startDiscovery() {}
    func stopDiscovery() {}
    func load(_ media: CastMedia, on device: CastDevice) async throws {
        throw CastError.unavailable("Questa build non include il Google Cast SDK.")
    }
    func play() async {}
    func pause() async {}
    func seek(to seconds: Double) async {}
    func endSession() async {}
}
#endif
