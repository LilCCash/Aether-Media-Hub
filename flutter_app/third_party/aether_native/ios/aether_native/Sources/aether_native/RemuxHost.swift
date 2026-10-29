import Foundation
import AetherCore

enum RemuxHostError: Error {
    case unavailable
    case notOnTheNetwork
    case blocked
    case noLAN
}

/// Converts a Matroska file into HLS for AVPlayer, AirPlay and Google Cast: the pieces are made on demand and served by a small server.
/// On the Wi-Fi address when there is one (a television can fetch the pieces, and so can the phone's own player), else on 127.0.0.1.
/// One file at a time.
@MainActor
final class RemuxHost {
    struct Opened {
        let id: String
        let url: URL
        let lan: Bool
        let plan: RemuxPlan?
    }

    private let registry = RelaySessionRegistry()
    private var server: RelayServer?
    private var bound: String?
    private var lastPort: UInt16?
    private var current: (id: RelaySessionID, fetcher: RelayRangeFetcher)?
    private var restarting = false
    private var epoch = 0
    /// Progress lines for the app's log (no addresses, no keys).
    var log: (String) -> Void = { _ in }

    /// A file forwarded as it is (a source that needs request headers a television cannot send): `leaf` names it for the receiver.
    func forward(_ upstream: RelayUpstream, ext: String) async throws -> Opened {
        close()
        let mine = epoch
        let scheme = upstream.url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw RemuxHostError.notOnTheNetwork }
        guard let lan = LANAddressReader.current() else { throw RemuxHostError.noLAN }
        let guardian = UpstreamGuard(allowPrivateOrigin: true, selfAddresses: [lan.address], resolver: SystemHostResolver())
        do { try await guardian.validateOrigin(upstream.url) } catch { throw RemuxHostError.blocked }
        guard mine == epoch else { throw CancellationError() }
        let leaf = "video." + (RelayMime.allowedExtensions.contains(ext.lowercased()) ? ext.lowercased() : "mp4")
        let fetcher = URLSessionRangeFetcher(upstream: upstream, guardian: guardian)
        let source = HTTPRangeSource(leaf: leaf, contentType: RelayMime.forFileName(leaf) ?? "video/mp4", fetcher: fetcher)
        do {
            try await source.prepare()
            guard mine == epoch else { throw CancellationError() }
            _ = try await startServer(host: lan.address, lan: lan)
            guard mine == epoch else { throw CancellationError() }
            registry.ownAddress = lan.address
            let created = try registry.create(source: source, leaf: leaf, owner: .airPlay, peerRule: .any)
            guard let url = server?.url(host: lan.address, token: created.token, leaf: leaf) else {
                registry.revoke(created.id, reason: .loadFailed)
                throw RemuxHostError.unavailable
            }
            current = (created.id, fetcher)
            return Opened(id: "\(created.id)", url: url, lan: true, plan: nil)
        } catch {
            source.close()
            fetcher.invalidate()
            if mine == epoch { stopServerIfIdle() }
            throw error
        }
    }

    func open(_ upstream: RelayUpstream, audio: RemuxAudioChoice, preferLAN: Bool) async throws -> Opened {
        close()
        let mine = epoch
        let scheme = upstream.url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { throw RemuxHostError.notOnTheNetwork }
        guard FFmpegAvailability.isLinked else { throw RemuxHostError.unavailable }

        let lan: LANInterface? = preferLAN ? LANAddressReader.current() : nil
        let host = lan?.address ?? "127.0.0.1"
        let guardian = UpstreamGuard(allowPrivateOrigin: true, selfAddresses: lan.map { [$0.address] } ?? [], resolver: SystemHostResolver())
        do { try await guardian.validateOrigin(upstream.url) } catch { throw RemuxHostError.blocked }
        guard mine == epoch else { throw CancellationError() }

        let fetcher = URLSessionRangeFetcher(upstream: upstream, guardian: guardian)
        var source: RemuxSource?
        do {
            log("sorgente in lettura (\(lan == nil ? "127.0.0.1" : "Wi-Fi"))")
            let resource = try await fetcher.probe()
            guard mine == epoch else { throw CancellationError() }
            guard let total = resource.length, total > 0 else { throw RelayError.upstreamNoRanges }
            log("sorgente raggiunta, \(total / 1_048_576) MB")
            guard let engine = RemuxHost.makeEngine(fetcher, total, audio, { [weak self] text in
                Task { @MainActor in self?.log(text) }
            }) else { throw RemuxHostError.unavailable }
            let made = RemuxSource(engine: engine)
            source = made
            let prepared = try await made.prepare()
            guard mine == epoch else { throw CancellationError() }
            log("file analizzato: \(prepared.segments.count) pezzi, \(Int(prepared.duration)) s")
            if let initData = try? await engine.initSegment(), let first = try? await engine.mediaSegment(0) {
                await RemuxSelfCheck.run(initSegment: initData, fragment: first, log: log)
            }

            _ = try await startServer(host: host, lan: lan)
            log("server locale avviato")
            guard mine == epoch else { throw CancellationError() }
            registry.ownAddress = lan?.address
            let created = try registry.create(source: made, leaf: nil, owner: .airPlay, peerRule: .any)
            guard let url = server?.url(host: host, token: created.token, leaf: RemuxSource.Leaf.masterName) else {
                registry.revoke(created.id, reason: .loadFailed)
                throw RemuxHostError.unavailable
            }
            current = (created.id, fetcher)
            return Opened(id: "\(created.id)", url: url, lan: lan != nil, plan: prepared.plan)
        } catch {
            source?.close()
            fetcher.invalidate()
            if mine == epoch { stopServerIfIdle() }
            throw error
        }
    }

    private static func makeEngine(_ fetcher: RelayRangeFetcher, _ total: Int64, _ audio: RemuxAudioChoice,
                                   _ note: @escaping (String) -> Void) -> RemuxEngine? {
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
        return FFmpegRemuxEngine(fetcher: fetcher, totalBytes: total, audio: audio, note: note)
        #else
        return nil
        #endif
    }

    func close() {
        epoch += 1
        guard let session = current else { return }
        current = nil
        registry.revoke(session.id, reason: .userStopped)
        session.fetcher.invalidate()
        stopServerIfIdle()
    }

    private func startServer(host: String, lan: LANInterface?) async throws -> UInt16 {
        if let running = server, bound == host, let port = running.port { return port }
        server?.stop()
        server = nil
        let configuration = RelayServer.Configuration(bindAddress: host, lan: lan, allowLoopbackPeers: true)
        let created = RelayServer(registry: registry, configuration: configuration, log: { [weak self] event in
            let text = event.message
            Task { @MainActor in self?.log(text) }
        })
        created.onFailure = { [weak self, weak created] in
            Task { @MainActor in
                if let self = self, let created = created { self.serverFailed(created, host: host, lan: lan) }
            }
        }
        let port: UInt16
        do {
            port = try await created.start(preferredPort: lastPort)
        } catch {
            guard lastPort != nil, current == nil else { throw error }
            lastPort = nil
            port = try await created.start(preferredPort: nil)
        }
        server = created
        bound = host
        lastPort = port
        return port
    }

    /// The system takes a listening socket away from an app that was suspended (a locked phone): when the viewer comes back the
    /// pieces must be served again on the same address.
    private func serverFailed(_ failed: RelayServer, host: String, lan: LANInterface?) {
        guard server === failed else { return }
        server = nil
        bound = nil
        failed.stop()
        guard current != nil, !restarting else { return }
        restarting = true
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.restarting = false }
            _ = try? await self.startServer(host: host, lan: lan)
        }
    }

    private func stopServerIfIdle() {
        guard current == nil else { return }
        server?.stop()
        server = nil
        bound = nil
    }
}
