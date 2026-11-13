import SwiftUI
import AVFoundation
import AetherCore

/// AirPlay and the hand-off to a remote receiver. Part of `PlayerViewModel`, split by subject so that a change
/// to one part cannot disturb the others by accident (same behaviour as when it was one file).
extension PlayerViewModel {
    // MARK: AirPlay


    /// Reads the AirPlay route again and works out what the viewer should be told. With MPV the route is the audio session's: the
    /// engine never reports external playback, so it must not be wiped when the engine says "not active".
    func refreshAirPlayRoute() {
        let route = airPlayRouteProvider()
        if route != nil && engine.kind == .avPlayer { moveConversionToWiFi() }
        let blocked = externalPlaybackBlockedForKey
        if engine.kind == .avPlayer && !snapshot.isExternalPlaybackActive && !blocked {
            airPlayRoute = nil
        } else {
            airPlayRoute = route
        }
        let advice = AirPlayAdvice.evaluate(engine: engine.kind, routeName: airPlayRoute, externalPlaybackActive: snapshot.isExternalPlaybackActive,
                                            screenMirrored: screenMirroredProvider(), externalPlaybackBlockedForKey: blocked,
                                            relayServing: conversionLease != nil)
        guard advice != airPlayAdvice else { return }
        airPlayAdvice = advice
        if case .audioOnlyBecauseMPV(let name) = advice {
            env.diagnostics.logDetached(.info, "player", "AirPlay con MPV: solo audio")
            if !acknowledgedAirPlayRoutes.contains(name) { airPlayAlert = AirPlayAlert.mpvAudioOnly() }
        }
        if case .audioOnlyBecauseKeyProtected(let name) = advice, !acknowledgedAirPlayRoutes.contains(name) {
            acknowledgedAirPlayRoutes.insert(name)
            showStatus("AirPlay: questo link contiene la tua chiave TorBox e non viene dato al televisore, quindi va solo l'audio. Per il video usa un MP4 senza chiave o attiva l'invio del link diretto in Impostazioni ▸ Avanzate.", for: 9)
        }
    }

    /// AirPlay hands the address of the video to the receiver. A TorBox link carries the viewer's key, so while one plays the picture is
    /// kept off AirPlay (the sound still goes) unless the viewer chose in Settings to send such links, or the receiver is given the
    /// relay's keyless address of a converted file instead.
    var externalPlaybackBlockedForKey: Bool {
        guard engine.kind == .avPlayer, isPlayingThroughTorBox, conversionPlan == nil else { return false }
        return !env.settings.value.advanced.sendDirectLinkToTV
    }

    /// With MPV the picture cannot go over AirPlay; AVPlayer can take the file, converted on the phone.
    var canSwitchToAVPlayerForAirPlay: Bool {
        guard engine.kind == .mpv, !isLiveContent, remuxRouting.available else { return false }
        return remuxRouting.full || (currentContainer ?? "").lowercased() == "mkv" || PlaybackPlanner.isNativeToAVFoundation(container: currentContainer)
    }

    func switchToAVPlayerForAirPlay() {
        acknowledgeAirPlayAlert()
        guard canSwitchToAVPlayerForAirPlay else { return }
        // What AVPlayer cannot open is converted, whatever the engine setting says.
        forcedConversion = !PlaybackPlanner.isNativeToAVFoundation(container: currentContainer)
        switchEngine(to: .avPlayer, reason: forcedConversion ? "Passo ad AVPlayer per AirPlay: converto il file sul telefono…" : "Passo ad AVPlayer per AirPlay…")
    }

    /// The viewer read the alert: it does not come back for this device during this player session.
    func acknowledgeAirPlayAlert() {
        if case .audioOnlyBecauseMPV(let name) = airPlayAdvice { acknowledgedAirPlayRoutes.insert(name) }
        airPlayAlert = nil
    }

    /// The system picker is about to open.
    func airPlayPickerWillPresent() {
        announcedWiFiNeed = false
        // A converted file has to be reachable from the receiver before one is chosen.
        if engine.kind == .avPlayer { moveConversionToWiFi() }
        guard engine.kind == .mpv else { return }
        statusMessage = "AirPlay con questo file: solo audio."
        scheduleStatusClear(after: 4)
    }

    // MARK: Hand-off to a remote receiver

    var currentPlaybackURL: URL? {
        switch request.source {
        case .download(let item): return env.downloads.localURL(for: item)
        case .stream(let stream): return StreamResolver.playbackURL(for: stream, streamingServer: env.streamPreferences().streamingServer)
        }
    }

    var currentStreamForCast: AddonStream? { currentStream }

    /// Subtitles a remote receiver would lose: the one the app draws itself, when one is on (the list of what could be chosen does
    /// not matter, only what is shown). Embedded tracks travel with the video.
    func externalSubtitleCount() -> Int {
        guard let selected = selectedOption else { return 0 }
        return selected.isEmbedded ? 0 : 1
    }

    /// Everything needed to start a remote session for the video that plays now.
    struct CastPreparation: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        var request: CastRequest
        var delivery: CastDelivery
        /// The real address of the source, for the compatibility check only. It may carry the account key: it is never stored or shown.
        var evaluationURL: URL
        var info: StreamInfo
        var headers: [String: String]
        /// The phone converts the file into HLS for the receiver.
        var remuxed = false
        /// What to send instead if the file cannot be converted (its codecs cannot be copied): the file as it is.
        var fallback: CastRequest?

        var description: String { return "CastPreparation" }
        var debugDescription: String { return "CastPreparation" }
        var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
    }

    enum CastPreparationOutcome {
        case ready(CastPreparation)
        case refused(title: String, message: String)
    }

    /// Decides how the current video reaches a Google Cast or DLNA receiver and builds the request, or says why it cannot be sent.
    /// A video resolved through TorBox is sent from the link TorBox produced (never from the torrent's own address), and because that
    /// link carries the viewer's key it goes through the relay unless the viewer chose, in Settings, to send the link itself.
    func castPreparation(for target: CastTarget, sendDirectLinkToTV: Bool, relay: RelayAvailability) -> CastPreparationOutcome {
        guard case .stream(let stream) = request.source else {
            return .refused(title: CastRefusal.localFile.title, message: CastRefusal.localFile.message)
        }
        let streamingServer = env.streamPreferences().streamingServer
        let debrid = currentDebridStream()
        let playing = debrid ?? stream
        let server = debrid == nil ? streamingServer : nil
        guard let url = StreamResolver.playbackURL(for: playing, streamingServer: server) else {
            return .refused(title: "Non trasmettibile",
                            message: "Questa sorgente non ha un indirizzo che il televisore possa leggere (per esempio è un torrent non ancora risolto). Avvia prima la riproduzione sul telefono.")
        }
        let headers = playing.behaviorHints.proxyRequestHeaders
        let traits = CastSourceTraits(isLocalFile: false, carriesAccountKey: debrid != nil, hasRequestHeaders: !headers.isEmpty)
        let delivery: CastDelivery
        switch CastDeliveryPlanner.decide(traits, target: target, sendDirectLinkToTV: sendDirectLinkToTV, relay: relay) {
        case .refuse(let refusal):
            return .refused(title: refusal.title, message: refusal.message)
        case .deliver(let decided):
            delivery = decided
        }
        let info = StreamAnalyzer.analyze(playing, streamingServer: server)
        let container = info.container ?? ""
        let artwork = (currentVideo?.thumbnail ?? meta.poster ?? meta.background).flatMap { URL.lenient($0) }
        let source: CastSource
        switch delivery {
        case .direct: source = .direct(url)
        case .directWithKey: source = .directWithKey(url)
        case .relay: source = .relay(RelayUpstream(url: url, headers: headers))
        }
        let request = CastRequest(title: meta.name, subtitle: episodeSubtitle(), artworkURL: artwork,
                                  contentType: CastMedia.contentType(forContainer: info.container), isLive: snapshot.isLive,
                                  startPosition: max(snapshot.position, 0), source: source,
                                  subtitleLanguage: selectedOption?.isEmbedded == true ? (selectedOption?.languageCode ?? selectedOption?.language) : nil,
                                  subtitleTitle: selectedOption?.isEmbedded == true ? selectedOption?.title : nil,
                                  fileExtension: (container == "m3u8" || container == "mpd") ? container
                                    : (RelayMime.allowedExtensions.contains(container) ? container : "mp4"))

        // A Matroska file is converted on the phone into HLS for Cast and DLNA: audio follows the chosen language and embedded text
        // subtitles are exposed as HLS renditions. A plain-HTTP public source carrying secrets is never relayed.
        let plainHTTPWithSecrets = url.scheme?.lowercased() == "http" && CastCompatibility.hostKind(of: url) == .publicInternet
            && (debrid != nil || !headers.isEmpty)
        if (target == .googleCast || target == .dlna), container == "mkv", RemuxEngineFactory.isAvailable,
           delivery != .directWithKey, !plainHTTPWithSecrets,
           (target == .dlna || env.settings.value.casting.convertMatroskaForGoogleCast), case .ready = relay {
            var converted = request
            converted.source = .relayRemux(RelayUpstream(url: url, headers: headers), conversionAudio ?? .automatic(languages: wantedAudioLanguages()))
            converted.contentType = "application/x-mpegURL"
            converted.fileExtension = "m3u8"
            return .ready(CastPreparation(request: converted, delivery: .relay, evaluationURL: url, info: info, headers: headers,
                                          remuxed: true, fallback: request))
        }
        return .ready(CastPreparation(request: request, delivery: delivery, evaluationURL: url, info: info, headers: headers))
    }

    var currentStreamInfo: StreamInfo? {
        guard let stream = currentStream else { return nil }
        var info = StreamAnalyzer.analyze(stream, streamingServer: env.streamPreferences().streamingServer,
                                          capabilities: PlaybackEngineFactory.capabilities)
        if let direct = currentDebridStream() {
            // A torrent says nothing about its file: container and size are those of the file TorBox returned.
            let resolved = StreamAnalyzer.analyze(direct, streamingServer: nil)
            info.container = resolved.container
            if let size = direct.behaviorHints.videoSize, size > 0 { info.sizeBytes = size }
        }
        return info
    }

    var addonSourceName: String? { currentStream?.addonName }

    /// Local playback pauses while a TV plays; its position keeps being saved from the remote's clock.
    func castDidStart() {
        engine.pause()
        recordProgress(force: true)
    }


    func remoteProgress(position: Double, duration: Double?) {
        guard position > 0, abs(position - lastRemoteRecord) >= 5 else { return }
        let total = duration ?? snapshot.duration
        guard total > 0 else { return }
        lastRemoteRecord = position
        let store = env.libraryStore
        let meta = self.meta
        let video = currentVideo
        Task { _ = await store.recordProgress(meta: meta, video: video, position: position, duration: total) }
    }

    /// The remote session finished or was stopped. Near the end it counts as watched; otherwise, if the user wants it,
    /// playback continues on the phone from where the TV stopped.
    func castDidEnd(position: Double, resumeLocally: Bool) {
        let total = snapshot.duration
        if total > 0, position >= total * 0.97 {
            recordFinalCompletion()
            handleEnded()
            return
        }
        if position > 1 { engine.seek(to: position, precise: true) }
        if resumeLocally { engine.play() }
    }

    func clearStatusSoon() { scheduleStatusClear() }

    /// A line over the picture for a few seconds.
    func showStatus(_ text: String, for seconds: Double = 6) {
        statusMessage = text
        scheduleStatusClear(after: seconds)
    }

    /// A newer message replaces the older one's timer, so a long message is not cut short by an earlier schedule.
    func scheduleStatusClear(after seconds: Double = 3.5) {
        statusClear?.cancel()
        statusClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}
