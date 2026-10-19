import Foundation
import AetherCore

/// DLNA / UPnP AV "MediaRenderer" control (SOAP over HTTP). This is a different protocol from Google Cast: it is how
/// many smart TVs and Android TV apps with a DLNA receiver accept a URL. Devices come from SSDP (when the multicast
/// entitlement is present) or are added by address.
@MainActor
final class DLNABackend: CastBackend {
    let target = CastTarget.dlna
    var availability: CastAvailability { .available }
    private(set) var devices: [CastDevice] = []
    private(set) var isDiscovering = false
    var onDevicesChanged: (() -> Void)?
    var onStatus: ((CastRemoteStatus) -> Void)?
    var onSessionEnded: ((String?) -> Void)?

    /// Manual entries (`host:port` or a full description URL) and whether to try SSDP.
    var manualHosts: [String] = []
    var ssdpEnabled = false
    /// Human-readable outcome of the last scan (e.g. why SSDP found nothing).
    private(set) var lastScanNote: String?

    private let client: UPnPClient
    private var known: [String: UPnPDevice] = [:]
    private var scanTask: Task<Void, Never>?
    private var active: UPnPDevice?
    private var pollTask: Task<Void, Never>?

    private static let descriptionPaths = ["/description.xml", "/dmr", "/rootDesc.xml", "/DeviceDescription.xml", "/MediaRenderer/desc.xml", "/dd.xml"]

    init() {
        // DLNA is plain HTTP inside the LAN. Public hosts are rejected separately in `accept(_:)`.
        let policy = NetworkPolicy(allowLocalNetwork: true, allowLoopback: false,
                                   requireHTTPSForPublicHosts: false, checkDNS: false)
        client = UPnPClient(http: URLSessionHTTPClient(policyProvider: { policy }))
    }

    // MARK: Discovery

    func startDiscovery() {
        scanTask?.cancel()
        isDiscovering = true
        lastScanNote = nil
        scanTask = Task { [weak self] in
            await self?.scan()
            self?.isDiscovering = false
            self?.onDevicesChanged?()
        }
    }

    func stopDiscovery() {
        scanTask?.cancel()
        isDiscovering = false
    }

    private func scan() async {
        var locations: [URL] = []
        var notes: [String] = []

        if ssdpEnabled {
            let outcome = await SSDPScanner.scan()
            if let failure = outcome.failure { notes.append(failure) }
            locations.append(contentsOf: outcome.responses.map { $0.location })
            if outcome.failure == nil && outcome.responses.isEmpty {
                notes.append("SSDP: nessun renderer ha risposto.")
            }
        }

        for host in manualHosts {
            if Task.isCancelled { return }
            if let location = await resolveManual(host) {
                locations.append(location.0)
                known[location.1.id] = location.1
            } else {
                notes.append("«\(host)»: nessun renderer UPnP trovato a questo indirizzo.")
            }
        }

        let unique = Array(Set(locations))
        await withTaskGroup(of: UPnPDevice?.self) { group in
            for location in unique where known.values.contains(where: { $0.location == location }) == false {
                group.addTask { [client] in try? await client.fetchDevice(location: location) }
            }
            for await device in group {
                if let device = device, accept(device) { known[device.id] = device }
            }
        }
        lastScanNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
        publish()
    }

    /// Tries `host:port` against the usual description paths; a full URL is used as is.
    private func resolveManual(_ entry: String) async -> (URL, UPnPDevice)? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [URL] = []
        if trimmed.contains("://") {
            if let url = URL(string: trimmed) { candidates = [url] }
        } else {
            candidates = DLNABackend.descriptionPaths.compactMap { URL(string: "http://\(trimmed)\($0)") }
        }
        for url in candidates {
            if Task.isCancelled { return nil }
            if let device = try? await client.fetchDevice(location: url), accept(device) {
                return (url, device)
            }
        }
        return nil
    }

    /// A renderer's control URLs must stay on the LAN and on the host that described them: a hostile description
    /// must not be able to point the app at a public server or at another machine.
    private func accept(_ device: UPnPDevice) -> Bool {
        guard CastCompatibility.hostKind(of: device.location) == .localNetwork,
              let service = device.avTransport,
              CastCompatibility.hostKind(of: service.controlURL) == .localNetwork,
              service.controlURL.host == device.location.host else { return false }
        if let rendering = device.renderingControl, rendering.controlURL.host != device.location.host { return false }
        return true
    }

    private func publish() {
        devices = known.values
            .map { CastDevice(id: $0.id, name: $0.friendlyName, target: .dlna,
                              detail: [$0.manufacturer, $0.modelName, $0.location.host].compactMap { $0 }.joined(separator: " · ")) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onDevicesChanged?()
    }

    // MARK: Session

    func load(_ media: CastMedia, on device: CastDevice) async throws {
        guard let renderer = known[device.id] else {
            throw CastError.deviceUnreachable("Il renderer «\(device.name)» non è più nell'elenco: aggiorna la ricerca.")
        }
        pollTask?.cancel()
        onStatus?(CastRemoteStatus(state: .connecting, position: media.startPosition, duration: nil))
        do {
            try await client.load(device: renderer, url: media.url, title: media.title, artworkURL: media.artworkURL?.absoluteString)
            try await client.play(device: renderer)
        } catch let error as UPnPError {
            throw CastError.rejected(error.message)
        } catch let error as AddonError {
            throw CastError.deviceUnreachable("Impossibile comunicare con «\(device.name)»: \(error.message)")
        }
        active = renderer
        onStatus?(CastRemoteStatus(state: .loading, position: media.startPosition, duration: nil))
        startPolling(renderer: renderer, startPosition: media.startPosition)
    }

    private func startPolling(renderer: UPnPDevice, startPosition: Double) {
        pollTask?.cancel()
        pollTask = Task { [weak self, client] in
            var didStartPlaying = false
            var pendingSeek: Double? = startPosition > 1 ? startPosition : nil
            let began = Date()
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                do {
                    let state = try await client.transportState(device: renderer)
                    let position = try? await client.position(device: renderer)
                    failures = 0
                    let mapped: CastPlayState
                    switch state {
                    case .playing:
                        didStartPlaying = true
                        mapped = .playing
                        // Most renderers only accept a seek once they are playing.
                        if let target = pendingSeek {
                            pendingSeek = nil
                            try? await client.seek(device: renderer, to: target)
                        }
                    case .paused: didStartPlaying = true; mapped = .paused
                    case .transitioning: mapped = .buffering
                    case .stopped, .noMedia:
                        mapped = didStartPlaying ? .ended : .loading
                    case .unknown: mapped = .loading
                    }
                    self?.onStatus?(CastRemoteStatus(state: mapped, position: position?.position ?? 0, duration: position?.duration))
                    if !didStartPlaying && Date().timeIntervalSince(began) > 40 {
                        self?.onStatus?(CastRemoteStatus(state: .failed("Il televisore ha accettato il comando ma non ha avviato il video: formato o indirizzo non supportati dal renderer."), position: 0, duration: nil))
                        return
                    }
                    if mapped == .ended { return }
                } catch {
                    failures += 1
                    if failures >= 4 {
                        self?.onSessionEnded?("Il televisore non risponde più.")
                        return
                    }
                }
            }
        }
    }

    func play() async {
        guard let device = active else { return }
        try? await client.play(device: device)
    }

    func pause() async {
        guard let device = active else { return }
        try? await client.pause(device: device)
    }

    func seek(to seconds: Double) async {
        guard let device = active else { return }
        try? await client.seek(device: device, to: seconds)
    }

    func endSession() async {
        pollTask?.cancel()
        if let device = active { try? await client.stop(device: device) }
        active = nil
    }
}
