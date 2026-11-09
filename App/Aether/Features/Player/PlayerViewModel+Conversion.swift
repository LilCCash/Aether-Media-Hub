import SwiftUI
import AVFoundation
import AetherCore

/// Conversion of files the system player cannot read (remux, full and live conversion) and AirPlay of a converted file. Part of `PlayerViewModel`, split by subject so that a change
/// to one part cannot disturb the others by accident (same behaviour as when it was one file).
extension PlayerViewModel {
    // MARK: Conversion (Matroska → HLS for AVPlayer)

    var remuxRouting: RemuxRouting {
        return RemuxEngineFactory.routing(matroskaForAVPlayer: playback.convertMatroskaForAVPlayer, full: playback.conversionMode == .full,
                                          live: PlayerViewModel.liveConversionApplies(playback, meta: meta, source: request.source))
    }

    /// The live channel is converted for AVPlayer: the setting is on and its source (the addon, or the M3U playlists) is in the list.
    static func liveConversionApplies(_ settings: PlaybackSettings, meta: MetaItem, source: PlayerRequest.Source) -> Bool {
        guard meta.type == "tv", settings.liveConversion else { return false }
        guard case .stream(let stream) = source else { return false }
        let fromPlaylist = stream.addonID == nil && meta.id.hasPrefix("live:")
        return ConversionSources.includes(settings.liveConversionSources, addonID: stream.addonID, isPlaylist: fromPlaylist)
    }

    /// AVPlayer cannot open Matroska: the file is converted on the fly when the planner says so for this container and engine.
    var shouldConvertCurrentSource: Bool {
        guard engine.kind == .avPlayer else { return false }
        let plan = PlaybackPlanner.plan(container: currentContainer, facts: nil, device: device,
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable, choice: engineChoice,
                                        forceSDR: playback.video.hdrMode == .sdr, remux: remuxRouting, isLive: isLiveContent)
        return plan.usesRemux || (forcedConversion && remuxRouting.available && (!isLiveContent || remuxRouting.live))
    }

    /// The viewer wants AVPlayer for this file even when it has to be re-encoded (full conversion on, and AVPlayer chosen or asked for
    /// with Automatic).
    var prefersFullConversion: Bool {
        let routing = remuxRouting
        guard routing.full, routing.available, !isLiveContent else { return false }
        return engineChoice == .avPlayer || (engineChoice == .automatic && playback.convertMatroskaForAVPlayer)
    }

    /// AVPlayer cannot decode what it opened: with the full conversion the same file is converted and opened again, once.
    func convertAfterRefusal(reason: String) -> Bool {
        let wanted = prefersFullConversion || (isLiveContent && remuxRouting.live && remuxRouting.available && engineChoice != .mpv)
        guard wanted, engine.kind == .avPlayer, conversion == nil, liveConversion == nil, !forcedConversion, !tornDown else { return false }
        forcedConversion = true
        let position = max(snapshot.position, lastRetryPosition)
        env.diagnostics.logDetached(.info, "player", "AVPlayer non decodifica il file: lo converto (conversione completa)")
        failure = nil
        mediaInfo = nil
        carriedStatus = reason
        Task { await beginPlayback(startOverride: position > 5 ? position : nil) }
        return true
    }

    var isConverting: Bool { return conversionPlan != nil }

    /// Languages to prefer for the audio track of a converted file: what the viewer picked by hand for this title, then the settings.
    func wantedAudioLanguages() -> [String] {
        return TrackPreferences.audioLanguages(remembered: trackMemory.audioLanguageToApply(forMeta: meta.id),
                                               primary: SettingsStore.resolvedLanguage(playback.preferredAudioLanguage),
                                               secondary: SettingsStore.resolvedLanguage(playback.secondaryAudioLanguage))
    }

    /// The address AVPlayer plays for the converted file, or nil when this start is over: another engine took the file, the failure
    /// panel is showing, or the player moved on.
    func openConversion(of url: URL, headers: [String: String], generation: Int) async -> URL? {
        closeConversion()
        statusMessage = remuxRouting.full ? "Preparo il file per AVPlayer…" : "Preparo il file MKV per AVPlayer…"
        let upstream = RelayUpstream(url: url, headers: headers)
        let choice = conversionAudio ?? .automatic(languages: wantedAudioLanguages())
        do {
            let session = try await env.localRemux.open(upstream, audio: choice)
            guard !tornDown, generation == loadGeneration else {
                env.localRemux.close(session)
                return nil
            }
            conversion = session
            conversionUpstream = upstream
            conversionPlan = session.plan
            audioTracks = currentAudioTracks()
            statusMessage = nil
            prepareWiFiAhead()
            return session.url
        } catch {
            guard !tornDown, generation == loadGeneration else { return nil }
            statusMessage = nil
            giveUpConversion(because: RemuxFailureText.explainLocal(error))
            return nil
        }
    }

    /// The address AVPlayer plays for the converted live channel, or nil when this start is over (see `openConversion`).
    func openLiveConversion(of url: URL, headers: [String: String], generation: Int) async -> URL? {
        closeConversion()
        statusMessage = "Preparo la diretta per AVPlayer…"
        do {
            let opened = try await env.localRemux.openLive(RelayUpstream(url: url, headers: headers), full: remuxRouting.full)
            guard !tornDown, generation == loadGeneration else {
                opened.engine.close()
                env.localRemux.close()
                return nil
            }
            liveConversion = opened.engine
            statusMessage = nil
            env.diagnostics.logDetached(.info, "player", "Diretta convertita per AVPlayer: \(opened.engine.summary)")
            return opened.url
        } catch {
            guard !tornDown, generation == loadGeneration else { return nil }
            statusMessage = nil
            if error is CancellationError { return nil }
            let reason = (error as? LiveRemuxError)?.message ?? RemuxFailureText.explainLocal(error)
            giveUpConversion(because: reason)
            return nil
        }
    }

    /// The file cannot be converted: with the Automatic engine MPV takes it, otherwise the failure panel says why.
    func giveUpConversion(because reason: String) {
        env.diagnostics.logDetached(.warning, "player", "Conversione del file non riuscita: \(reason)")
        if engineChoice == .automatic, canUse(.mpv) {
            switchEngine(to: .mpv, reason: "\(RemuxFailureText.problem(reason)) Uso MPV.")
        } else {
            let advised = reason.contains("motore Automatico")
            let hint = engineChoice == .avPlayer && !advised ? " Scegli «Automatico» o «MPV» in Impostazioni → Riproduzione." : ""
            failureExplanation = reason + hint
            handleFailure(PlaybackFailure(kind: .formatUnsupported, detail: reason + hint))
        }
    }

    func closeConversion() {
        if let session = conversion {
            env.localRemux.close(session)
            conversion = nil
        }
        if let live = liveConversion {
            liveConversion = nil
            if let lease = liveLease {
                env.relay.release(lease, reason: .userStopped)
                liveLease = nil
            }
            env.localRemux.close()
            live.close()
        }
        if let lease = conversionLease {
            env.relay.release(lease, reason: .userStopped)
            conversionLease = nil
        }
        // A Wi-Fi address made ahead of time and never used ends with the file it was made for.
        if let pending = wifiLeaseTask {
            wifiLeaseTask = nil
            let relay = env.relay
            Task { @MainActor in
                if let lease = try? await pending.task.value { relay.release(lease, reason: .userStopped) }
            }
        }
        conversionUpstream = nil
        conversionPlan = nil
    }

    // MARK: AirPlay for a converted file

    /// The relay lease (the Wi-Fi address) of the converted file now playing. Whoever needs it first, the preparation ahead of time or
    /// the move to that address, starts it, and the other waits for the same one: a second publish would replace the first session
    /// (they belong to the same owner), which is the one the player or the receiver may already be reading.
    func sharedWiFiLease(for upstream: RelayUpstream, generation: Int) -> Task<RelayLease, Error> {
        if let existing = wifiLeaseTask, existing.generation == generation { return existing.task }
        let choice = conversionAudio ?? .track(index: conversionPlan?.audio.first?.index ?? -1)
        let relay = env.relay
        let task = Task { @MainActor () -> RelayLease in
            return try await relay.publish(RelayPublishRequest(upstream: upstream, contentType: "application/x-mpegURL",
                                                               fileExtension: "m3u8", owner: .airPlay, receiverAddress: nil,
                                                               remux: choice))
        }
        wifiLeaseTask = (generation, task)
        return task
    }

    /// While an AirPlay receiver is in range, the Wi-Fi address of the converted file is made ready: choosing the receiver then finds
    /// it at once, instead of the receiver being handed an address of this phone it cannot reach while the conversion is prepared.
    func prepareWiFiAhead() {
        guard routesNearby, conversion != nil, conversionLease == nil, engine.kind == .avPlayer, !tornDown,
              let upstream = conversionUpstream, case .ready = env.relay.availability else { return }
        let generation = loadGeneration
        guard wifiLeaseTask?.generation != generation else { return }
        let task = sharedWiFiLease(for: upstream, generation: generation)
        env.diagnostics.logDetached(.info, "player", "AirPlay nelle vicinanze: preparo in anticipo l'indirizzo sul Wi-Fi")
        Task { [weak self] in
            do {
                _ = try await task.value
            } catch {
                guard let self = self, self.wifiLeaseTask?.generation == generation else { return }
                self.wifiLeaseTask = nil
                self.env.diagnostics.logDetached(.warning, "player", "Preparazione in anticipo dell'indirizzo sul Wi-Fi non riuscita")
            }
        }
    }

    func startRouteDetection() {
        let detector = AVRouteDetector()
        detector.isRouteDetectionEnabled = true
        routeDetector = detector
        routesNearby = detector.multipleRoutesDetected
        // The notification is named by its constant's value, which is what the system posts.
        routeDetectorObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("AVRouteDetectorMultipleRoutesDetectedDidChangeNotification"), object: detector, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.routesDetectionChanged() }
        }
    }

    func routesDetectionChanged() {
        guard let detector = routeDetector, !tornDown else { return }
        routesNearby = detector.multipleRoutesDetected
        if routesNearby { prepareWiFiAhead() }
    }

    func stopRouteDetection() {
        if let observer = routeDetectorObserver { NotificationCenter.default.removeObserver(observer) }
        routeDetectorObserver = nil
        routeDetector?.isRouteDetectionEnabled = false
        routeDetector = nil
    }

    /// A converted file still served on 127.0.0.1 cannot be fetched by an AirPlay receiver: until the Wi-Fi address is in use the picture
    /// stays off AirPlay (the sound still goes), instead of a black screen that ends with the video back on the phone.
    var externalVideoWaitsForWiFi: Bool {
        return engine.kind == .avPlayer && ((conversion != nil && conversionLease == nil) || (liveConversion != nil && liveLease == nil)
            || (playingArchive && archiveLease == nil))
    }

    /// A video read from inside an archive is served on 127.0.0.1: for AirPlay the relay serves the same reading on the Wi-Fi address
    /// and the player continues from there, at the same position.
    func moveArchiveToWiFi() {
        guard playingArchive, archiveLease == nil, !archiveMovingToWiFi, engine.kind == .avPlayer, !tornDown,
              let leaf = env.localRemux.archiveLeaf, let source = env.localRemux.archiveRelaySource() else { return }
        guard case .ready = env.relay.availability else {
            if !announcedWiFiNeed {
                announcedWiFiNeed = true
                statusMessage = "Per mandare in AirPlay il video letto dall'archivio servono il Wi-Fi e «Consenti rete locale» (Impostazioni ▸ Account e dati ▸ Privacy): per ora su AirPlay va solo l'audio."
                scheduleStatusClear(after: 9)
            }
            return
        }
        archiveMovingToWiFi = true
        let generation = loadGeneration
        statusMessage = "Preparo il video per AirPlay…"
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.archiveMovingToWiFi = false }
            do {
                let lease = try await self.env.relay.publish(source: source, leaf: leaf, owner: .airPlay)
                guard !self.tornDown, generation == self.loadGeneration, self.playingArchive else {
                    self.env.relay.release(lease, reason: .userStopped)
                    return
                }
                var position = self.engine.currentTime()
                if position < 1, self.snapshot.position < 1, self.loadStartPosition > 1 { position = self.loadStartPosition }
                let wasPlaying = self.snapshot.isPlaying
                self.archiveLease = lease
                self.engine.setExternalPlaybackAllowed(!self.externalPlaybackBlockedForKey)
                self.engine.load(url: lease.url, headers: [:], startAt: position > 1 ? position : nil, autoplay: wasPlaying)
                self.statusMessage = nil
                self.env.diagnostics.logDetached(.info, "player", "AirPlay: il video dell'archivio è ora sull'indirizzo Wi-Fi (riparte da \(Int(position)) s)")
            } catch {
                guard !self.tornDown else { return }
                self.statusMessage = RemuxFailureText.explain(error)
                self.scheduleStatusClear(after: 6)
            }
        }
    }

    /// The converted live channel is served on 127.0.0.1: for AirPlay the relay serves the same channel on the Wi-Fi address (no
    /// second connection to the channel) and the player follows it there.
    func moveLiveToWiFi() {
        guard let live = liveConversion, liveLease == nil, !liveMovingToWiFi, engine.kind == .avPlayer, !tornDown else { return }
        guard case .ready = env.relay.availability else {
            if !announcedWiFiNeed {
                announcedWiFiNeed = true
                statusMessage = "Per mandare il video di questa diretta in AirPlay servono il Wi-Fi e «Consenti rete locale» (Impostazioni ▸ Account e dati ▸ Privacy): per ora su AirPlay va solo l'audio."
                scheduleStatusClear(after: 9)
            }
            return
        }
        liveMovingToWiFi = true
        let generation = loadGeneration
        statusMessage = "Preparo la diretta per AirPlay…"
        Task { [weak self] in
            guard let self = self else { return }
            defer { self.liveMovingToWiFi = false }
            do {
                let lease = try await self.env.relay.publish(source: LiveRemuxSource(engine: live, closesEngine: false), leaf: "index.m3u8", owner: .airPlay)
                guard !self.tornDown, generation == self.loadGeneration, self.liveConversion === live else {
                    self.env.relay.release(lease, reason: .userStopped)
                    return
                }
                self.liveLease = lease
                self.engine.setExternalPlaybackAllowed(!self.externalPlaybackBlockedForKey)
                self.engine.load(url: lease.url, headers: [:], startAt: nil, autoplay: true)
                self.statusMessage = nil
                self.env.diagnostics.logDetached(.info, "player", "AirPlay: la diretta convertita è ora sull'indirizzo Wi-Fi")
            } catch {
                guard !self.tornDown else { return }
                self.statusMessage = RemuxFailureText.explain(error)
                self.scheduleStatusClear(after: 6)
            }
        }
    }

    /// The converted file is served on 127.0.0.1, which an AirPlay receiver cannot reach: the relay serves it on the Wi-Fi address and
    /// the player continues from there, at the same position.
    func moveConversionToWiFi() {
        if liveConversion != nil { moveLiveToWiFi(); return }
        if playingArchive { moveArchiveToWiFi(); return }
        guard conversion != nil, conversionLease == nil, engine.kind == .avPlayer, !tornDown, let upstream = conversionUpstream else { return }
        guard movingToWiFiGeneration != loadGeneration else { return }
        guard case .ready = env.relay.availability else {
            if !announcedWiFiNeed {
                announcedWiFiNeed = true
                env.diagnostics.logDetached(.info, "player", "AirPlay: il ponte non è disponibile (rete locale spenta o niente Wi-Fi): solo audio")
                statusMessage = "Per mandare il video di questo MKV in AirPlay servono il Wi-Fi e «Consenti rete locale» (Impostazioni ▸ Account e dati ▸ Privacy): per ora su AirPlay va solo l'audio."
                scheduleStatusClear(after: 9)
            }
            return
        }
        let generation = loadGeneration
        movingToWiFiGeneration = generation
        let task = sharedWiFiLease(for: upstream, generation: generation)
        env.diagnostics.logDetached(.info, "player", "AirPlay: sposto il file convertito sull'indirizzo Wi-Fi")
        statusMessage = "Preparo il video per AirPlay…"
        Task { [weak self] in
            guard let self = self else { return }
            defer { if self.movingToWiFiGeneration == generation { self.movingToWiFiGeneration = nil } }
            do {
                let lease = try await task.value
                // Whatever ended this start (a new source, the player closing) also releases the lease: closeConversion waits for the task.
                guard !self.tornDown, generation == self.loadGeneration, self.conversion != nil, self.conversionLease == nil else { return }
                // Taken now, not before the wait: the video went on playing while the conversion was prepared. Right after the file is
                // ready the engine has not applied its start position yet and says 0.
                var position = self.engine.currentTime()
                if position < 1, self.snapshot.position < 1, self.loadStartPosition > 1 { position = self.loadStartPosition }
                let wasPlaying = self.snapshot.isPlaying
                self.conversionLease = lease
                if let plan = lease.remuxPlan { self.conversionPlan = plan }
                self.engine.setExternalPlaybackAllowed(!self.externalPlaybackBlockedForKey)
                self.engine.load(url: lease.url, headers: [:], startAt: position > 1 ? position : nil, autoplay: wasPlaying)
                if let old = self.conversion {
                    self.env.localRemux.close(old)
                    self.conversion = nil
                }
                self.statusMessage = nil
                self.env.diagnostics.logDetached(.info, "player", "AirPlay: il file convertito è ora sull'indirizzo Wi-Fi (riparte da \(Int(position)) s)")
            } catch {
                if self.wifiLeaseTask?.generation == generation { self.wifiLeaseTask = nil }
                guard !self.tornDown else { return }
                self.env.diagnostics.logDetached(.warning, "player", "AirPlay: spostamento sul Wi-Fi non riuscito")
                self.statusMessage = RemuxFailureText.explain(error)
                self.scheduleStatusClear(after: 6)
            }
        }
    }

    /// The audio tracks to list: those of the converted file (one plays at a time), else the engine's own.
    func currentAudioTracks() -> [EngineTrack] {
        guard let plan = conversionPlan else { return engine.audioTracks() }
        let selected = plan.audio.first?.index
        return plan.audioChoices.map { track in
            EngineTrack(id: String(track.index), title: track.summary, language: track.language, isSelected: track.index == selected)
        }
    }
}
