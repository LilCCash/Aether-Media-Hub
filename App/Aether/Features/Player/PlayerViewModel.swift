import SwiftUI
import AVFoundation
import AetherCore

/// A subtitle to translate on the device with Apple's Translation framework (iOS 18): the cues in groups, from and into a language.
struct SubtitleTranslationJob: Identifiable {
    let id = UUID()
    let optionID: String
    let source: Locale.Language?
    let target: Locale.Language
    let batches: [[(index: Int, text: String)]]
}

struct SubtitleOption: Identifiable, Hashable {
    enum Kind: Hashable {
        case embedded(String)
        case addon(AddonSubtitle)
        case local(URL)
    }

    let id: String
    let title: String
    let detail: String?
    /// Language as announced by the engine or the addon, in any spelling.
    let language: String?
    let kind: Kind
    /// Stable language code (`LanguageCodes.normalise`) when the language is known: what a choice made by hand remembers.
    let languageCode: String?
    /// Charset announced in the URL of an addon subtitle (`?senc=cp1250`).
    let encodingHint: String?

    init(id: String, title: String, detail: String?, language: String?, kind: Kind,
         languageCode: String? = nil, encodingHint: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.language = language
        self.kind = kind
        self.languageCode = languageCode
        self.encodingHint = encodingHint
    }
}

/// Orchestrates one playback session: engine, resume/progress, subtitles, audio, next episode, sleep timer,
/// source fallback and system integration. The SwiftUI view only renders its published state.
@MainActor
final class PlayerViewModel: ObservableObject {
    // MARK: Published state
    @Published var snapshot = EngineSnapshot()
    @Published var failure: PlaybackFailure?
    @Published var statusMessage: String?
    /// Why an MKV could not be converted for AVPlayer, in words for the viewer, when the failure panel is up because of it.
    @Published var failureExplanation: String?
    /// The reason for an engine change, shown over the picture once the new load has started (a load clears the status line).
    var carriedStatus: String?
    /// True from the start of a load until the engine has been given the file (TorBox may take seconds to answer first).
    @Published var isOpeningSource = true
    /// The intro and recap of the episode now playing, when IntroDB knows them (see `activeSkipSegment`).
    @Published var skipSegments = EpisodeSkipSegments.none
    @Published var sourceName: String
    @Published var currentVideo: Video?
    /// The address and headers handed to the engine, kept to cut the little pictures of the progress bar (not published: the screen does not follow them).
    var previewURL: URL?
    var previewHeaders: [String: String] = [:]
    @Published var meta: MetaItem
    @Published var audioTracks: [EngineTrack] = []
    @Published var subtitleOptions: [SubtitleOption] = []
    @Published var selectedSubtitleID: String?
    @Published var activeCues: [SubtitleCue] = []
    /// The colour of the poster, for the controls (when the viewer left «Colori dalla locandina» on).
    @Published var posterAccent: Color?
    @Published var subtitleError: String?
    /// Addon subtitles grouped by language and ranked for this viewer (`SubtitleCatalog`).
    @Published var subtitleGroups: [SubtitleLanguageGroup] = []
    /// `.loading` until the addons have answered for the first time.
    @Published var subtitleListPhase: SubtitleListPhase = .loading
    /// At least one installed, enabled addon can serve subtitles for this title.
    @Published var hasSubtitleProvider = false
    @Published var subtitleDelay: Double
    @Published var sleepRemaining: TimeInterval?
    @Published var nextEpisode: Video?
    @Published var nextCountdown: Int?
    @Published var isResolvingNext = false
    /// The episode the viewer is choosing a source for (the list of sources opens over the player).
    @Published var sourcePickerEpisode: Video?
    /// The videos of the torrent being played when it holds more than one (a season pack).
    @Published var packFiles: [DebridPackFile] = []
    @Published var alternatives: [RankedStream]
    @Published var engine: PlaybackEngine
    @Published var mediaInfo: MediaFormatInfo?
    @Published var playbackPlan: PlaybackPlan?
    @Published var airPlayRoute: String?
    /// What the viewer should know about AirPlay right now (with MPV the sound goes to the device and the picture stays on the phone).
    @Published var airPlayAdvice: AirPlayAdvice = .none
    @Published var airPlayAlert: AirPlayAlert?
    /// What the on-the-fly conversion copies, while a Matroska file plays through it (nil otherwise).
    @Published var conversionPlan: RemuxPlan?
    @Published var didFinish = false
    @Published var isFill = false
    @Published var playbackRate: Float = 1

    // MARK: Collaborators
    let env: AppEnvironment
    var request: PlayerRequest
    let device: DeviceVideoCapabilities
    var engineSwitches = 0
    /// Full conversion: AVPlayer said it cannot decode this file (an MP4 in 10-bit H.264, say), so it is converted from now on.
    var forcedConversion = false
    /// The engine was changed on purpose (a fallback) for the file now playing: a restart must keep it.
    var engineChosenByFallback = false
    /// Why the engine in use was switched to (shown in the information sheet).
    @Published var engineSwitchReason: String?
    // The Matroska file plays as HLS made by the phone: first on 127.0.0.1 (`conversion`), and on the relay's Wi-Fi address
    // (`conversionLease`) once an AirPlay receiver has to fetch it.
    var conversion: LocalRemuxService.Session?
    /// The live channel converted on the phone, and its address on the Wi-Fi once an AirPlay receiver needs it.
    var liveConversion: LiveRemuxEngine?
    var liveLease: RelayLease?
    /// A video read from inside an archive (served on 127.0.0.1), and its Wi-Fi address once an AirPlay receiver needs it.
    var playingArchive = false
    var archiveLease: RelayLease?
    var archiveMovingToWiFi = false
    var liveMovingToWiFi = false
    var conversionLease: RelayLease?
    var conversionUpstream: RelayUpstream?
    /// The audio track the viewer picked for this video; nil follows the language settings.
    var conversionAudio: RemuxAudioChoice?
    var announcedWiFiNeed = false
    /// The load generation whose move to the Wi-Fi address is in progress: a second move for the same load would replace the
    /// relay session the first one had just handed to the player.
    var movingToWiFiGeneration: Int?
    /// AirPlay receivers are in range (the system says more than one route is available).
    var routeDetector: AVRouteDetector?
    var routeDetectorObserver: NSObjectProtocol?
    var routesNearby = false
    /// The Wi-Fi lease being made (or made) for the converted file of this load generation, see `sharedWiFiLease`.
    var wifiLeaseTask: (generation: Int, task: Task<RelayLease, Error>)?
    /// Where the load now under way was asked to start; until the player has passed it, "now" is not what `currentTime()` says.
    var loadStartPosition: Double = 0
    let nowPlaying = NowPlayingService()
    let audioSession = AudioSessionController()
    var pictureInPictureGrace: Task<Void, Never>?
    /// Playing when the app left the screen, and a phone call or similar in progress: used to resume after the grace.
    var wasPlayingWhenBackgrounded = false
    var isInterrupted = false
    var statusClear: Task<Void, Never>?

    // MARK: Internals
    var currentStream: AddonStream?
    /// The source that is playing has already been counted for the learning of reliability (once per source).
    var reliabilityCounted = false
    var lastRecordedPosition: Double = -100
    var lastRetryPosition: Double = 0
    var timeline: SubtitleTimeline?
    var cueCache: [String: SubtitleTimeline] = [:]
    var subtitleTask: Task<Void, Never>?
    var cueTimer: Timer?
    var sleepTask: Task<Void, Never>?
    var countdownTask: Task<Void, Never>?
    var nextStreamsTask: Task<(streams: [AddonStream], errors: [String: AddonError]), Never>?
    var tornDown = false
    var preferredAudioApplied = false
    var preferredSubtitleApplied = false
    // Subtitles: lists, selection and the one-time decisions of the current video.
    var embeddedOptions: [SubtitleOption] = []
    var localOptions: [SubtitleOption] = []
    var subtitleCandidates: [SubtitleCandidate] = []
    /// Subtitles announced by the stream itself.
    var streamSubtitles: [AddonSubtitle] = []
    /// Answers of the addons asked without a local hash / with the hash computed on this device.
    var plainSubtitles: [AddonSubtitle] = []
    var hashedSubtitles: [AddonSubtitle] = []
    /// From the full OpenSubtitles.org catalogue, in the viewer's languages (the v3 addon only has a part of it).
    var catalogSubtitles: [AddonSubtitle] = []
    var catalogLoading = false
    var subtitleAddonsFinished = false
    var selectedOption: SubtitleOption?
    var failedSubtitle: SubtitleOption?
    var subtitleGeneration = 0
    var subtitleHashTask: Task<Void, Never>?
    var localHashes: [String: SubtitleHashResult] = [:]
    var attemptedHashStreams = Set<String>()
    var subtitleTracksKnown = false
    var engineSubtitlesSilenced = false
    var engineSubtitleSyncPending = false
    var pendingEmbeddedLanguage: String?
    /// Audio and subtitle choices made by hand in this session (applied to the next episode of the same series).
    var trackMemory = SessionTrackMemory()
    var retriedAfterNetworkLoss = false
    var wasPlayingBeforeInterruption = false
    var fullMetaLoaded = false
    // TorBox: a torrent source is turned into a direct link before `engine.load`. That link carries a token, so it lives only here
    // (never in `request`, `currentStream`, the library, a download or a Cast hand-off) and is never logged.
    var debridStream: AddonStream?
    var debridStreamKey: String?
    var debridTask: Task<AddonStream, Error>?
    /// Bumped by every start; a start that was overtaken (or outlived `teardown()`) must not load its source into an engine.
    var loadGeneration = 0
    /// True from the moment the next episode is chosen until its source is loaded: the engine still holds the previous
    /// episode then, and its position must not be saved under the new one.
    var progressSuspended = false
    var debridGeneration = 0
    var debridProgressSequence = 0
    var skipSegmentsTask: Task<Void, Never>?
    var nextLinkTask: Task<Void, Never>?
    @Published var translationJob: SubtitleTranslationJob?
    @Published var translationStatus: String?
    @Published var translatedOptionID: String?

    var playback: PlaybackSettings { env.settings.value.playback }
    /// The live channels (type «tv») have their own player choice and are never converted.
    var isLiveContent: Bool { return meta.type == "tv" }
    var openStartedAt = Date()
    var firstFrameLogged = false
    /// The opening of the current source, measured for Instruments (Telemetry).
    var openInterval: Telemetry.Interval?
    var engineChoice: PlayerEngineChoice { return isLiveContent ? playback.liveEngine : playback.engine }

    init(request: PlayerRequest, env: AppEnvironment) {
        self.request = request
        self.env = env
        self.meta = request.meta
        self.currentVideo = request.video
        self.alternatives = request.alternatives
        let settings = env.settings.value.playback
        let device = DeviceCapabilitiesReader.current()
        self.device = device
        let plan = PlaybackPlanner.plan(container: PlayerViewModel.container(of: request, env: env), facts: nil, device: device,
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable,
                                        choice: request.meta.type == "tv" ? settings.liveEngine : settings.engine,
                                        forceSDR: settings.video.hdrMode == .sdr,
                                        remux: RemuxEngineFactory.routing(matroskaForAVPlayer: settings.convertMatroskaForAVPlayer,
                                                                          full: settings.conversionMode == .full,
                                                                          live: PlayerViewModel.liveConversionApplies(settings, meta: request.meta,
                                                                                                                      source: request.source)),
                                        isLive: request.meta.type == "tv")
        self.playbackPlan = plan
        self.engine = PlaybackEngineFactory.make(plan.engine ?? .avPlayer, settings: settings, device: device)
        self.subtitleDelay = env.settings.value.playback.subtitleDelaySeconds
        switch request.source {
        case .stream(let stream):
            self.currentStream = stream
            self.sourceName = stream.name ?? stream.addonName ?? "Sorgente"
        case .download:
            self.sourceName = "Download"
        }
    }

    // Stored state of the AirPlay part (PlayerViewModel+AirPlay.swift): an extension cannot hold it.
    /// Where the sound goes, read from the audio session. Replaceable for tests.
    var airPlayRouteProvider: () -> String? = { AudioSessionController.airPlayRouteName() }
    /// The screen is being mirrored or recorded (then the picture reaches the TV whatever the engine).
    var screenMirroredProvider: () -> Bool = {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.screen.isCaptured ?? false
    }
    var acknowledgedAirPlayRoutes: Set<String> = []
    var lastRemoteRecord: Double = -100

    // MARK: Poster colour

    /// The colour of the poster for the controls; nothing happens when the switch is off.
    func loadPosterAccent() {
        guard env.settings.value.advanced.extras.posterTint else { return }
        let address = meta.poster ?? meta.background
        Task { [weak self] in
            guard let self = self else { return }
            if let palette = await PosterTint.palette(for: address, loader: self.env.images), !self.tornDown {
                self.posterAccent = PosterTint.color(palette.accent)
            }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !tornDown else { return }
        bindEngine()
        loadPosterAccent()
        env.watchTogether.attach(self)

        audioSession.onInterruptionBegan = { [weak self] in
            guard let self = self else { return }
            self.wasPlayingBeforeInterruption = self.snapshot.isPlaying
            self.isInterrupted = true
            self.engine.pause()
        }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in
            guard let self = self else { return }
            self.isInterrupted = false
            if shouldResume && self.wasPlayingBeforeInterruption { self.engine.play() }
        }
        audioSession.onRouteLost = { [weak self] in self?.engine.pause() }
        audioSession.onRouteChanged = { [weak self] _ in self?.refreshAirPlayRoute() }
        audioSession.activate()
        startRouteDetection()
        UIApplication.shared.isIdleTimerDisabled = true

        configureRemoteCommands()
        nowPlaying.setMetadata(title: meta.name, subtitle: episodeSubtitle(), artworkURL: (meta.background ?? meta.poster).flatMap { URL.lenient($0) }, loader: env.images)
        if playback.defaultSleepTimerMinutes > 0 { setSleepTimer(minutes: playback.defaultSleepTimerMinutes) }

        Task {
            await beginPlayback(startOverride: nil)
            await loadFullMetaIfNeeded()
        }
        // The video id is known already: asking the subtitle addons does not wait for the full metadata.
        Task { await loadSubtitleOptions() }
        loadSkipSegments()
        startCueTimer()
    }

    /// Connects the current engine to this model. Called again whenever the engine is replaced.
    func bindEngine() {
        engine.onSnapshot = { [weak self] snapshot in self?.handle(snapshot) }
        engine.onEnded = { [weak self] in self?.handleEnded() }
        engine.onFailure = { [weak self] failure in self?.handleFailure(failure) }
        engine.onTracksChanged = { [weak self] in self?.refreshTracks() }
        engine.onMediaInfo = { [weak self] info in self?.handleMediaInfo(info) }
        engine.setAutoPictureInPicture(playback.autoPictureInPicture)
        engine.setRate(playbackRate)
        engine.setFillScreen(isFill)
        engine.setEmbeddedSubtitleDelay(subtitleDelay)
    }

    /// The container of what is about to play, from the stream's own URL / hints or the downloaded file.
    static func container(of request: PlayerRequest, env: AppEnvironment) -> String? {
        switch request.source {
        case .stream(let stream):
            return StreamAnalyzer.analyze(stream, streamingServer: env.streamPreferences().streamingServer).container
        case .download(let item):
            guard let local = env.downloads.localURL(for: item) else { return nil }
            // The content decides, not the name: Matroska saved as ".mp4" is not something AVPlayer can open.
            if let real = ContainerSniffer.container(ofFileAt: local) { return real }
            let ext = local.pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        }
    }

    /// For a torrent resolved through TorBox the container is the one of the file TorBox returned.
    var currentContainer: String? {
        if let direct = currentDebridStream() {
            return StreamAnalyzer.analyze(direct, streamingServer: nil).container
        }
        return PlayerViewModel.container(of: request, env: env)
    }

    func teardown() {
        scrobbleTrakt(.stop)
        guard !tornDown else { return }
        tornDown = true
        // Closing the player ends a TorBox wait too; an item already added to the user's account stays there.
        debridGeneration += 1
        debridTask?.cancel()
        debridTask = nil
        debridStream = nil
        debridStreamKey = nil
        skipSegmentsTask?.cancel()
        skipSegmentsTask = nil
        nextLinkTask?.cancel()
        nextLinkTask = nil
        env.watchTogether.detach(self)
        closeConversion()
        // A video read from inside an archive ends with the player.
        if let lease = archiveLease {
            env.relay.release(lease, reason: .userStopped)
            archiveLease = nil
        }
        env.localRemux.closeArchive()
        playingArchive = false
        stopRouteDetection()
        pictureInPictureGrace?.cancel()
        pictureInPictureGrace = nil
        statusClear?.cancel()
        statusClear = nil
        // Record the final position and write it to disk in one ordered step: a separate flush could run first.
        if !recordProgress(force: true, flushAfter: true) {
            Task { await env.libraryStore.flush() }
        }
        subtitleTask?.cancel()
        subtitleHashTask?.cancel()
        subtitleGeneration += 1
        trackMemory.reset()
        sleepTask?.cancel()
        countdownTask?.cancel()
        nextStreamsTask?.cancel()
        cueTimer?.invalidate()
        engine.teardown()
        nowPlaying.clear()
        audioSession.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Loading

    func beginPlayback(startOverride: Double?) async {
        loadGeneration += 1
        let generation = loadGeneration
        openStartedAt = Date()
        openInterval?.end()
        openInterval = Telemetry.begin("Apertura sorgente")
        firstFrameLogged = false
        isOpeningSource = true
        failure = nil
        failureExplanation = nil
        if let carried = carriedStatus {
            carriedStatus = nil
            showStatus(carried, for: 8)
        } else {
            statusMessage = nil
        }
        retriedAfterNetworkLoss = false
        // A newer start supersedes a TorBox wait that is still in flight.
        debridGeneration += 1
        debridTask?.cancel()
        debridTask = nil
        if let plan = playbackPlan, !plan.canPlay, let message = plan.blockingMessage {
            handleFailure(PlaybackFailure(kind: .formatUnsupported, detail: message))
            return
        }
        let url: URL
        var headers: [String: String] = [:]
        switch request.source {
        case .download(let item):
            guard let local = env.downloads.localURL(for: item) else {
                handleFailure(PlaybackFailure(kind: .notFound, detail: "File scaricato mancante"))
                return
            }
            url = local
            // Another downloaded episode can be of another container than the one the engine was chosen for.
            guard adoptEngine(forContainer: currentContainer) else { return }
        case .stream(let stream):
            var source = stream
            if DebridStreamLogic.isTorrent(stream) && env.debrid.isConfigured {
                // A torrent has no address of its own: TorBox turns it into a direct link first (progress and errors show here).
                guard let direct = await resolveTorrentWithTorBox(stream) else { return }
                guard !tornDown, generation == loadGeneration else { return }
                source = direct
                guard adoptEngine(forResolved: direct) else { return }
            } else {
                // Another source or episode can be of another container than the one the engine was chosen for.
                guard adoptEngine(forResolved: stream) else { return }
            }
            guard let resolved = StreamResolver.playbackURL(for: source, streamingServer: env.streamPreferences().streamingServer) else {
                handleFailure(PlaybackFailure(kind: .formatUnsupported, detail: "Sorgente non riproducibile"))
                return
            }
            let blocked = await env.validateMediaURL(resolved)
            guard !tornDown, generation == loadGeneration else { return }
            if let blocked = blocked {
                handleFailure(PlaybackFailure(kind: .unknown, detail: blocked.message))
                return
            }
            url = resolved
            headers = source.behaviorHints.proxyRequestHeaders
        }

        var start = startOverride
        if start == nil, playback.autoResume {
            let key = currentVideo?.id ?? meta.id
            if let saved = await env.libraryStore.resumePosition(metaID: meta.id, videoID: key) {
                start = max(0, saved - Double(playback.resumeRewindSeconds))
            }
        }
        guard !tornDown, generation == loadGeneration else { return }
        progressSuspended = false
        lastRetryPosition = start ?? 0
        engine.setRate(playbackRate)
        var loadURL = url
        var loadHeaders = headers
        if shouldConvertCurrentSource && isLiveContent {
            guard let converted = await openLiveConversion(of: url, headers: headers, generation: generation) else { return }
            guard !tornDown, generation == loadGeneration else { return }
            loadURL = converted
            loadHeaders = [:]
            start = nil
        } else if shouldConvertCurrentSource {
            // nil: the file went to another engine, or the failure panel says why it cannot be converted.
            guard let converted = await openConversion(of: url, headers: headers, generation: generation) else { return }
            guard !tornDown, generation == loadGeneration else { return }
            loadURL = converted
            loadHeaders = [:]
        } else {
            closeConversion()
        }
        if let lease = archiveLease {
            env.relay.release(lease, reason: .userStopped)
            archiveLease = nil
        }
        playingArchive = conversion == nil && liveConversion == nil && env.localRemux.serves(loadURL) && env.localRemux.archiveLeaf != nil
        engine.setExternalPlaybackAllowed(!externalPlaybackBlockedForKey && !externalVideoWaitsForWiFi)
        (engine as? LiveStreamHinting)?.setLiveStream(isLiveContent)
        env.diagnostics.logDetached(.info, "player", String(format: "Apertura: la sorgente è pronta dopo %.1f s, avvio il motore %@", Date().timeIntervalSince(openStartedAt), engine.displayName))
        loadStartPosition = start ?? 0
        // The little pictures of the progress bar are cut from the original source, not from the local conversion.
        previewURL = url
        previewHeaders = headers
        engine.load(url: loadURL, headers: loadHeaders, startAt: start, autoplay: true)
        isOpeningSource = false
        if start != nil && (start ?? 0) > 1 { statusMessage = "Riprendo da \(Format.duration(start ?? 0))" }
        scheduleStatusClear()
    }

    // MARK: TorBox (torrent sources)

    /// What identifies one resolution: the torrent and the video it is played for.
    func debridKey(for stream: AddonStream) -> String {
        return AddonStream.sourceKey(stream.source) + "|" + DebridStreamLogic.stremioID(meta: meta, video: currentVideo)
    }

    /// The direct link TorBox produced for the source that plays now, if there is one.
    func currentDebridStream() -> AddonStream? {
        guard let direct = debridStream, let key = debridStreamKey else { return nil }
        guard case .stream(let stream) = request.source else { return nil }
        return debridKey(for: stream) == key ? direct : nil
    }

    /// True while the source that plays is a torrent turned into a link by TorBox (its address carries a token and is not
    /// handed to Cast or DLNA receivers).
    var isPlayingThroughTorBox: Bool { return currentDebridStream() != nil }

    func forgetDebridLink() {
        debridStream = nil
        debridStreamKey = nil
    }

    /// Turns a torrent into a direct-link stream through TorBox. The player only plays what TorBox already has in its cache:
    /// starting a download needs the user's confirmation, which the stream picker asks for. nil when it did not work (the failure
    /// panel is showing) or when the player moved on or closed in the meantime.
    func resolveTorrentWithTorBox(_ stream: AddonStream) async -> AddonStream? {
        let key = debridKey(for: stream)
        if let direct = debridStream, debridStreamKey == key { return direct }
        forgetDebridLink()
        debridGeneration += 1
        let generation = debridGeneration
        debridProgressSequence = 0
        statusMessage = "Controllo TorBox…"
        let stremioID = DebridStreamLogic.stremioID(meta: meta, video: currentVideo)
        let debrid = env.debrid
        let relay = DebridProgressRelay()
        let sink: @Sendable (DebridProgress) -> Void = { (progress: DebridProgress) -> Void in
            let sequence = relay.next()
            Task { @MainActor in
                self.debridProgressArrived(progress, sequence: sequence, generation: generation)
            }
        }
        let task = Task { () -> AddonStream in
            return try await debrid.playableStream(for: stream, stremioID: stremioID, onProgress: sink)
        }
        debridTask = task
        let outcome = await task.result
        guard generation == debridGeneration, !tornDown else { return nil }
        debridTask = nil
        statusMessage = nil
        switch outcome {
        case .success(let direct):
            guard case .stream(let current) = request.source, current.id == stream.id else { return nil }
            debridStream = direct
            debridStreamKey = key
            return direct
        case .failure(let error):
            if error is CancellationError { return nil }
            handleFailure(DebridPlayback.failure(forAny: error))
            return nil
        }
    }

    func debridProgressArrived(_ progress: DebridProgress, sequence: Int, generation: Int) {
        guard generation == debridGeneration, sequence > debridProgressSequence, failure == nil, !tornDown else { return }
        debridProgressSequence = sequence
        statusMessage = DebridFormat.statusLine(for: progress)
    }

    /// The file TorBox returned decides the container, and so the engine (a Matroska file needs MPV). False when no engine can
    /// play it; the failure panel then says why.
    func adoptEngine(forResolved direct: AddonStream) -> Bool {
        return adoptEngine(forContainer: StreamAnalyzer.analyze(direct, streamingServer: nil).container)
    }

    func adoptEngine(forContainer container: String?) -> Bool {
        // A restart after an engine fallback keeps the engine the fallback chose: planning again from the file name alone
        // would put the engine that just failed back (and the same failure would repeat).
        if engineChosenByFallback { return true }
        let plan = PlaybackPlanner.plan(container: container, facts: nil, device: device,
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable, choice: engineChoice,
                                        forceSDR: playback.video.hdrMode == .sdr, remux: remuxRouting, isLive: isLiveContent)
        playbackPlan = plan
        guard let wanted = plan.engine else {
            handleFailure(PlaybackFailure(kind: .formatUnsupported, detail: plan.blockingMessage ?? "Formato non riproducibile"))
            return false
        }
        if wanted != engine.kind && canUse(wanted) {
            engine.teardown()
            engine = PlaybackEngineFactory.make(wanted, settings: playback, device: device)
            mediaInfo = nil
            bindEngine()
            engineReplaced()
        }
        return true
    }

    /// With TorBox configured, a torrent is chosen automatically only when TorBox says it is in its cache: the automatic choice
    /// never starts a download. Direct links are untouched.
    func debridAutoSelectable(_ ranked: [RankedStream]) async -> [RankedStream] {
        guard env.debrid.isConfigured else { return ranked }
        let hashes = DebridStreamLogic.hashes(in: ranked)
        var statuses: [String: DebridCacheStatus] = [:]
        if !hashes.isEmpty {
            let report = await env.debrid.availability(infoHashes: hashes)
            statuses = report.statuses
        }
        return DebridStreamLogic.autoSelectable(ranked, statuses: statuses, debridConfigured: true)
    }

    func loadFullMetaIfNeeded() async {
        guard !fullMetaLoaded else { return }
        fullMetaLoaded = true
        if meta.videos.isEmpty || (currentVideo != nil && !meta.videos.contains(where: { $0.id == currentVideo?.id })) {
            let resolution = await env.service.meta(type: meta.type, id: meta.id, fallback: meta)
            meta = resolution.meta.merging(fallback: meta)
            if let id = currentVideo?.id, let full = meta.videos.first(where: { $0.id == id }) {
                currentVideo = full
                // A player opened from a download knew no season or episode until now.
                if skipSegments.isEmpty { loadSkipSegments() }
            }
        }
        updateNextEpisode()
    }

    func updateNextEpisode() {
        guard let video = currentVideo else { nextEpisode = nil; return }
        nextEpisode = NextEpisodeResolver.next(after: video.id, in: meta)
    }

    var previousEpisode: Video? {
        guard let video = currentVideo else { return nil }
        return NextEpisodeResolver.previous(before: video.id, in: meta)
    }

    var episodes: [Video] {
        guard let season = currentVideo?.season else { return meta.videos }
        return meta.videos(inSeason: season)
    }

    func episodeSubtitle() -> String? {
        guard let video = currentVideo else { return nil }
        return [video.episodeLabel, video.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var title: String { meta.name }

    // MARK: Engine callbacks

    func handle(_ new: EngineSnapshot) {
        let wasReady = snapshot.isReady
        let old = snapshot
        snapshot = new
        if !reliabilityCounted, new.isPlaying, new.position > 2 { recordReliability(success: true) }
        if new.isPictureInPicturePossible != old.isPictureInPicturePossible {
            env.diagnostics.logDetached(.info, "player", "Il sistema dice Picture in Picture possibile: \(new.isPictureInPicturePossible)")
        }
        if new.isPictureInPictureActive != old.isPictureInPictureActive {
            env.diagnostics.logDetached(.info, "player", "Picture in Picture attivo: \(new.isPictureInPictureActive)")
        }
        if let failure = new.pictureInPictureFailure, failure != old.pictureInPictureFailure {
            statusMessage = "Il Picture in Picture non si è aperto."
            scheduleStatusClear(after: 4)
            env.diagnostics.logDetached(.warning, "player", "Picture in Picture non avviato: \(failure)")
        }
        if new.isReady && !wasReady {
            refreshTracks(); refreshPack()
            if !firstFrameLogged {
                firstFrameLogged = true
                openInterval?.end()
                openInterval = nil
                env.diagnostics.logDetached(.info, "player", String(format: "Apertura: pronto a riprodurre dopo %.1f s dall'avvio del lettore", Date().timeIntervalSince(openStartedAt)))
            }
        }
        if new.isPlaying != old.isPlaying { scrobbleTrakt(new.isPlaying ? .start : .pause) }
        if new.isExternalPlaybackActive != old.isExternalPlaybackActive {
            let where_ = conversionLease != nil ? "indirizzo Wi-Fi del ponte" : (conversion != nil ? "questo telefono (127.0.0.1)" : "indirizzo originale")
            env.diagnostics.logDetached(.info, "player", "AirPlay: riproduzione esterna \(new.isExternalPlaybackActive ? "attiva" : "terminata"), file su: \(where_)")
        }
        if new.isReady != old.isReady || new.isExternalPlaybackActive != old.isExternalPlaybackActive { refreshAirPlayRoute() }
        nowPlaying.updateProgress(position: new.position, duration: new.duration, rate: new.isPlaying ? new.rate : 0, isLive: new.isLive)
        if new.isPlaying { lastRetryPosition = new.position }
        recordProgress(force: false)
        evaluateNextEpisodePrompt()
    }

    var traktActive = false

    /// Dice a Trakt cosa sta succedendo (se è acceso): inizio, pausa, fine.
    func scrobbleTrakt(_ action: TraktClient.ScrobbleAction, finished: Bool = false) {
        guard !snapshot.isLive else { return }
        switch action {
        case .start: traktActive = true
        case .pause: guard traktActive else { return }
        case .stop:
            guard traktActive else { return }
            traktActive = false
        }
        let duration = snapshot.duration
        env.trakt.scrobble(action, meta: meta, video: currentVideo, position: finished ? duration : snapshot.position, duration: duration)
    }

    /// Returns true when a write was scheduled.
    @discardableResult
    func recordProgress(force: Bool, flushAfter: Bool = false) -> Bool {
        guard !progressSuspended else { return false }
        guard snapshot.duration > 0 || force, snapshot.position > 0 else { return false }
        if !force && abs(snapshot.position - lastRecordedPosition) < 5 { return false }
        if snapshot.isLive { return false }
        lastRecordedPosition = snapshot.position
        let store = env.libraryStore
        let meta = self.meta
        let video = currentVideo
        let position = snapshot.position
        let duration = snapshot.duration
        Task {
            _ = await store.recordProgress(meta: meta, video: video, position: position, duration: duration)
            if flushAfter { await store.flush() }
        }
        return true
    }

    func handleEnded() {
        recordFinalCompletion()
        scrobbleTrakt(.stop, finished: true)
        if case .download(let item) = request.source {
            env.downloads.deleteIfWatched(metaID: item.metaID, videoID: item.videoID)
        }
        if nextEpisode != nil && playback.autoplayNextEpisode {
            Task { await playNext(userInitiated: false) }
        } else {
            didFinish = true
        }
    }

    func recordFinalCompletion() {
        let store = env.libraryStore
        let meta = self.meta
        let video = currentVideo
        let duration = max(snapshot.duration, snapshot.position)
        Task { _ = await store.recordProgress(meta: meta, video: video, position: duration, duration: duration) }
    }

    /// Tells the ranking how the source of this addon went (see `SourceReliability`): once per source, started or not.
    func recordReliability(success: Bool) {
        guard !reliabilityCounted, playback.sourceScoring.learnsFromPlayback else { return }
        var stream = currentStream
        if stream == nil, case .stream(let requested) = request.source { stream = requested }
        guard let id = stream?.addonID else { return }
        reliabilityCounted = true
        env.settings.value.playback.sourceScoring.reliability.record(addonID: id, success: success)
    }

    func handleFailure(_ new: PlaybackFailure) {
        isOpeningSource = false
        if new.kind == .codecUnsupported || new.kind == .formatUnsupported,
           convertAfterRefusal(reason: "AVPlayer non decodifica questo video: lo converto sul telefono…") { return }
        if tryEngineFallback(after: new) { return }
        if !isLiveContent { recordReliability(success: false) }
        // The engine's wording may quote the file's address, and a link resolved through TorBox carries a token: it is redacted
        // before it is shown or logged. A link the CDN refused (expired) is dropped, so that "Riprova" asks TorBox for a new one.
        var shown = new
        if currentDebridStream() != nil {
            shown = DebridPlayback.redacted(new)
            if DebridPlayback.invalidatesResolvedLink(new) { forgetDebridLink() }
        }
        failure = shown
        env.diagnostics.logDetached(.error, "player", "Errore di riproduzione (\(shown.kind.rawValue)): \(shown.detail)")
        engine.pause()
    }

    // MARK: Engine selection

    func canUse(_ kind: PlaybackEngineKind) -> Bool {
        switch kind {
        case .avPlayer: return true
        case .mpv: return PlaybackEngineFactory.mpvAvailable
        }
    }

    /// Facts measured by the engine arrive after loading: show them, and if they show that the other engine is the
    /// right one for this file (for example an HEVC track tagged hev1, or Dolby Vision profile 7), switch once.
    func handleMediaInfo(_ info: MediaFormatInfo) {
        mediaInfo = info
        let plan = PlaybackPlanner.plan(container: info.container ?? currentContainer, facts: info, device: device,
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable, choice: engineChoice,
                                        forceSDR: playback.video.hdrMode == .sdr, remux: remuxRouting, isLive: isLiveContent)
        playbackPlan = plan
        if plan.usesRemux, info.source == .avFoundation, conversion == nil,
           convertAfterRefusal(reason: "AVPlayer non decodifica questo video: lo converto sul telefono…") { return }
        guard engineChoice == .automatic, info.source == .avFoundation, engineSwitches == 0,
              let wanted = plan.engine, wanted != engine.kind, canUse(wanted) else { return }
        switchEngine(to: wanted, reason: plan.notes.first(where: { $0.severity != .warning })?.text ?? "Cambio motore di riproduzione…")
    }

    /// An engine that cannot open the file is replaced by the other one, once, resuming at the same position.
    /// Network problems never trigger a switch.
    func tryEngineFallback(after failure: PlaybackFailure) -> Bool {
        guard engineChoice == .automatic, engineSwitches < 2, !tornDown else { return false }
        let target: PlaybackEngineKind = engine.kind == .avPlayer ? .mpv : .avPlayer
        guard canUse(target) else { return false }
        switch failure.kind {
        case .formatUnsupported, .codecUnsupported:
            break
        case .unknown where engine.kind == .mpv && failure.detail.contains("uscita video"):
            break
        default:
            return false
        }
        if target == .avPlayer && !PlaybackPlanner.isNativeToAVFoundation(container: currentContainer) { return false }
        env.diagnostics.logDetached(.warning, "player", "Motore \(engine.kind.rawValue) non riesce ad aprire la sorgente (\(failure.kind.rawValue)): provo \(target.rawValue)")
        switchEngine(to: target, reason: "Questo motore non riesce a riprodurre il file: provo \(target.displayName)…")
        return true
    }

    func switchEngine(to kind: PlaybackEngineKind, reason: String) {
        guard !tornDown, kind != engine.kind else { return }
        engineSwitches += 1
        engineChosenByFallback = true
        engineSwitchReason = reason.replacingOccurrences(of: "…", with: "")
        let position = max(snapshot.position, lastRetryPosition)
        engine.teardown()
        engine = PlaybackEngineFactory.make(kind, settings: playback, device: device)
        mediaInfo = nil
        failure = nil
        bindEngine()
        engineReplaced()
        carriedStatus = reason
        Task { await beginPlayback(startOverride: position > 5 ? position : nil) }
    }

    // MARK: Transport commands

    // MARK: Skip intro / recap

    /// Asks IntroDB for the episode now playing (IMDb id, season and episode: nothing else leaves the device). Nothing is
    /// shown when the setting is off, the title has no IMDb id, or the service knows nothing.
    func loadSkipSegments() {
        skipSegmentsTask?.cancel()
        skipSegments = .none
        // A downloaded episode carries its own intro / recap: works offline and asks nobody.
        if playback.skipSegmentsEnabled, case .download(let file) = request.source,
           let stored = env.downloads.items.first(where: { $0.id == file.id })?.storedSkipSegments {
            skipSegments = stored
            return
        }
        guard playback.skipSegmentsEnabled, !tornDown, let video = currentVideo, let season = video.season, let episode = video.episode,
              let imdb = ExternalIDs.imdbID(fromMetaID: meta.id) else { return }
        let videoID = video.id
        skipSegmentsTask = Task { [weak self, skipSegmentsService = env.skipSegments] in
            let found = await skipSegmentsService.segments(imdbID: imdb, season: season, episode: episode)
            guard !Task.isCancelled, let self = self, !self.tornDown, self.currentVideo?.id == videoID else { return }
            self.skipSegments = found ?? .none
            // Played from a download: keep what was found, so the next time it works offline.
            if let found = found, case .download(let file) = self.request.source { self.env.downloads.saveSkipSegments(found, for: file.id) }
        }
    }

    /// The segment whose button is on offer at the current position.
    var activeSkipSegment: SkipSegment? {
        // Not while the file is still being opened or the next episode is being found: the playhead is then the previous
        // episode's (or zero), and a tap would seek an engine that does not hold this episode yet.
        guard playback.skipSegmentsEnabled, failure == nil, !snapshot.isLive, !skipSegments.isEmpty,
              snapshot.isReady, !isOpeningSource, !isResolvingNext else { return nil }
        return skipSegments.active(at: snapshot.position, duration: snapshot.duration > 0 ? snapshot.duration : nil)
    }

    /// Jumps to the end of the segment on offer.
    func skipActiveSegment() {
        guard let segment = activeSkipSegment else { return }
        let target = snapshot.duration > 0 ? min(segment.end, snapshot.duration) : segment.end
        engine.seek(to: target, precise: true)
    }

    func togglePlayPause() {
        let wasPlaying = snapshot.isPlaying
        // Before the engine has the file there is nothing to play or pause: a tap would only set a false state.
        guard !isOpeningSource else { return }
        if snapshot.isPlaying { engine.pause() } else { engine.play() }
        sendWatchState(playing: !wasPlaying)
    }

    func skip(_ seconds: Double) { engine.seek(by: seconds); sendWatchState(position: snapshot.position + seconds) }
    func skipBack() { skip(-Double(playback.skipBackSeconds)) }
    func skipForward() { skip(Double(playback.skipForwardSeconds)) }
    func seek(to seconds: Double) { engine.seek(to: seconds, precise: true); sendWatchState(position: seconds) }

    // MARK: Watching together (SharePlay)

    var applyingRemote = false

    var sharePlayAvailable: Bool { return env.settings.value.advanced.extras.sharePlay && !isLiveContent }

    func startWatchTogether() {
        Task {
            await env.watchTogether.start(type: meta.type, metaID: meta.id, videoID: currentVideo?.id, title: title)
            if let status = env.watchTogether.status { statusMessage = status; scheduleStatusClear() }
        }
    }

    func currentSyncState() -> (isPlaying: Bool, position: Double) { return (snapshot.isPlaying, snapshot.position) }

    /// What this player just did, for the others in the call (nothing while it is only following them).
    func sendWatchState(playing: Bool? = nil, position: Double? = nil) {
        guard !applyingRemote, env.watchTogether.isActive else { return }
        env.watchTogether.send(isPlaying: playing ?? snapshot.isPlaying, position: position ?? snapshot.position)
    }

    func applyRemote(_ message: PlaybackSyncMessage) {
        guard !tornDown, !isOpeningSource else { return }
        let actions = PlaybackSyncPlanner.actions(localPlaying: snapshot.isPlaying, localPosition: snapshot.position, remote: message,
                                                  now: Date().timeIntervalSince1970)
        guard !actions.isEmpty else { return }
        applyingRemote = true
        for action in actions {
            switch action {
            case .seek(let target): engine.seek(to: target, precise: true)
            case .play: engine.play()
            case .pause: engine.pause()
            }
        }
        // The engine reports the change a moment later: until then what it does is not a choice of this person.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.applyingRemote = false }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        engine.setRate(rate)
    }

    func toggleFill() {
        isFill.toggle()
        engine.setFillScreen(isFill)
    }

    var pictureInPictureAvailability: PictureInPictureAvailability { engine.pictureInPictureAvailability }

    /// The button is always there; when the floating window cannot open the viewer is told why instead of nothing happening.
    func startPictureInPicture() {
        let availability = engine.pictureInPictureAvailability
        guard availability.canStart else {
            statusMessage = availability.explanation
            scheduleStatusClear(after: 5)
            env.diagnostics.logDetached(.info, "player", "Picture in Picture richiesto ma non possibile (\(availability), motore \(engine.kind.rawValue))")
            return
        }
        env.diagnostics.logDetached(.info, "player", "Picture in Picture richiesto")
        engine.startPictureInPicture()
    }

    func configureRemoteCommands() {
        let handlers = NowPlayingService.Handlers(
            play: { [weak self] in self?.engine.play() },
            pause: { [weak self] in self?.engine.pause() },
            toggle: { [weak self] in self?.togglePlayPause() },
            skip: { [weak self] seconds in self?.engine.seek(by: seconds) },
            seek: { [weak self] seconds in self?.engine.seek(to: seconds, precise: true) },
            next: { [weak self] in Task { await self?.playNext() } },
            previous: { [weak self] in Task { await self?.playPrevious() } })
        nowPlaying.configure(handlers: handlers, skipBack: playback.skipBackSeconds, skipForward: playback.skipForwardSeconds)
    }

    // MARK: Retry / source switching

    func retry() {
        failure = nil
        Task { await beginPlayback(startOverride: lastRetryPosition > 5 ? lastRetryPosition : nil) }
    }

    /// Reconnection after the network came back (or switched Wi-Fi ↔ cellular): resume transparently, once.
    func networkChanged(isOnline: Bool) {
        guard isOnline else {
            if snapshot.isPlaying == false && failure == nil && snapshot.isBuffering {
                statusMessage = "Connessione persa: attendo la rete…"
            }
            return
        }
        if let failure = failure, failure.isNetworkRelated, !retriedAfterNetworkLoss {
            retriedAfterNetworkLoss = true
            statusMessage = "Connessione ripristinata: riprendo…"
            retry()
        } else if snapshot.isBuffering {
            engine.play()
        }
    }

    func switchSource(to item: RankedStream) {
        currentStream = item.stream
        reliabilityCounted = false
        sourceName = item.stream.name ?? item.stream.addonName ?? "Sorgente"
        request.source = .stream(item.stream)
        engineChosenByFallback = false
        alternatives = alternatives.filter { $0.id != item.id }
        let position = max(snapshot.position, lastRetryPosition)
        failure = nil
        // Another release of the same title: its subtitles, hash and tracks are not those of the previous one.
        resetSubtitleStateForNewVideo()
        Task { await beginPlayback(startOverride: position > 5 ? position : nil) }
        Task { await loadSubtitleOptions() }
        env.setBingeGroup(item.stream.behaviorHints.bingeGroup, forMeta: meta.id)
    }

    // MARK: Tracks

    func refreshTracks() {
        subtitleTracksKnown = true
        audioTracks = currentAudioTracks()
        refreshEmbeddedSubtitleOptions()
        if !preferredAudioApplied, !audioTracks.isEmpty {
            preferredAudioApplied = true
            applyPreferredAudio()
        }
        syncEngineSubtitleWithSelection()
        reselectEmbeddedAfterEngineChange()
        applyPreferredSubtitleIfNeeded()
    }

    /// Audio language: what the viewer picked by hand for this title, then the preferred language, then the secondary one
    /// ("off" means none).
    func applyPreferredAudio() {
        // A converted file has its audio language chosen before the conversion; AVPlayer sees one track only.
        guard conversionPlan == nil else { return }
        let languages = TrackPreferences.audioLanguages(
            remembered: trackMemory.audioLanguageToApply(forMeta: meta.id),
            primary: SettingsStore.resolvedLanguage(playback.preferredAudioLanguage),
            secondary: SettingsStore.resolvedLanguage(playback.secondaryAudioLanguage))
        guard let match = TrackPreferences.pickAudio(languages: languages, tracks: audioTracks), !match.isSelected else { return }
        engine.selectAudio(id: match.id)
        audioTracks = currentAudioTracks()
    }

    /// Audio track picked by the viewer. Its language is remembered for the next episode of this series.
    func selectAudio(_ track: EngineTrack) {
        preferredAudioApplied = true
        trackMemory.rememberAudio(language: TrackPreferences.audioLanguageToRemember(for: track), metaID: meta.id)
        if let plan = conversionPlan {
            // One audio track goes into the converted file: another one means converting again, from the same position.
            guard let index = Int(track.id), index != plan.audio.first?.index else { return }
            conversionAudio = .track(index: index)
            let position = max(snapshot.position, lastRetryPosition)
            statusMessage = "Cambio traccia audio…"
            Task { await beginPlayback(startOverride: position > 5 ? position : nil) }
            return
        }
        engine.selectAudio(id: track.id)
        audioTracks = currentAudioTracks()
    }

    /// A new engine replaced the old one (fallback to the other engine): its tracks are unknown until it reports them, the audio
    /// language is chosen again, and the subtitle on screen is carried over. A downloaded or imported subtitle is drawn by the app,
    /// so it survives as it is; an embedded track has another id in the new engine and is looked up again by language.
    func engineReplaced() {
        closeConversion()
        preferredAudioApplied = false
        subtitleTracksKnown = false
        engineSubtitlesSilenced = false
        audioTracks = []
        embeddedOptions = []
        if let selected = selectedOption {
            switch selected.kind {
            case .embedded:
                pendingEmbeddedLanguage = selected.languageCode ?? selected.language ?? selected.title
                selectedSubtitleID = nil
                selectedOption = nil
            case .addon, .local:
                engineSubtitleSyncPending = true
            }
        }
        publishSubtitleOptions()
        refreshAirPlayRoute()
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes = minutes, minutes > 0 else { sleepRemaining = nil; return }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepRemaining = Double(minutes) * 60
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                let left = end.timeIntervalSinceNow
                if left <= 0 {
                    self.sleepRemaining = nil
                    self.engine.pause()
                    self.statusMessage = "Timer di spegnimento: riproduzione in pausa."
                    return
                }
                self.sleepRemaining = left
            }
        }
    }

    // MARK: Background / scene

    /// What to do with the picture and the sound when the app changes phase. The rule itself (and why `.inactive` must not
    /// touch the picture) lives in `PlayerBackgroundPolicy`.
    func scenePhaseChanged(_ phase: PlayerBackgroundPolicy.Phase) {
        pictureInPictureGrace?.cancel()
        pictureInPictureGrace = nil
        applyBackgroundPolicy(phase: phase, graceExpired: false)
    }

    func applyBackgroundPolicy(phase: PlayerBackgroundPolicy.Phase, graceExpired: Bool) {
        guard !tornDown else { return }
        if phase == .background && !graceExpired { wasPlayingWhenBackgrounded = snapshot.isPlaying }
        let decision = PlayerBackgroundPolicy.decide(PlayerBackgroundPolicy.State(
            phase: phase,
            isPlaying: snapshot.isPlaying,
            isPictureInPictureActive: snapshot.isPictureInPictureActive,
            isExternalPlaybackActive: snapshot.isExternalPlaybackActive,
            isPictureInPicturePossible: snapshot.isPictureInPicturePossible,
            autoPictureInPicture: playback.autoPictureInPicture,
            allowBackgroundAudio: playback.allowBackgroundAudio,
            pictureInPictureGraceExpired: graceExpired))
        if phase == .active { refreshAirPlayRoute() }
        if decision.recordProgress { recordProgress(force: true) }
        switch decision.video {
        case .attach: engine.setVideoDetached(false)
        case .detach:
            engine.setVideoDetached(true)          // keep the sound, drop the picture
            // The picture stayed attached for the grace period, and the system pauses a player that shows video when the app is
            // no longer on screen: start it again so "continue the audio in the background" holds.
            if graceExpired && wasPlayingWhenBackgrounded && !isInterrupted { engine.play() }
        case .keep: break
        }
        if decision.pause { engine.pause() }
        if phase == .background {
            env.diagnostics.logDetached(.info, "player", "App in background: PiP attivo \(snapshot.isPictureInPictureActive), PiP possibile \(snapshot.isPictureInPicturePossible), automatico \(playback.autoPictureInPicture), attesa PiP \(decision.waitForPictureInPicture), video \(decision.video), pausa \(decision.pause)")
        }
        if decision.waitForPictureInPicture {
            pictureInPictureGrace = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(PlayerBackgroundPolicy.pictureInPictureGrace * 1_000_000_000))
                guard !Task.isCancelled, let self = self else { return }
                self.pictureInPictureGrace = nil
                self.applyBackgroundPolicy(phase: .background, graceExpired: true)
            }
        }
    }

}


/// The explanation shown the first time the sound of an MPV video goes to an AirPlay device.
struct AirPlayAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String

    static func mpvAudioOnly() -> AirPlayAlert {
        return AirPlayAlert(
            title: "AirPlay: sul televisore va solo l'audio",
            message: "Questo video usa il motore MPV, che non sa inviare l'immagine via AirPlay: il suono esce dal dispositivo AirPlay, l'immagine resta sul telefono. Se è un altoparlante va bene così. Per vedere il video sul televisore usa Google Cast o DLNA, scegli una sorgente MP4 o HLS, oppure usa «Duplica schermo» dal Centro di Controllo (mostra lo schermo del telefono; qualità inferiore, non provato con MPV).")
    }
}
