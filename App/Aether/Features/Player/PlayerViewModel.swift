import SwiftUI
import AVFoundation
import AetherCore

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
    @Published private(set) var snapshot = EngineSnapshot()
    @Published private(set) var failure: PlaybackFailure?
    @Published private(set) var statusMessage: String?
    /// True from the start of a load until the engine has been given the file (TorBox may take seconds to answer first).
    @Published private(set) var isOpeningSource = true
    /// The intro and recap of the episode now playing, when IntroDB knows them (see `activeSkipSegment`).
    @Published private(set) var skipSegments = EpisodeSkipSegments.none
    @Published private(set) var sourceName: String
    @Published private(set) var currentVideo: Video?
    @Published private(set) var meta: MetaItem
    @Published private(set) var audioTracks: [EngineTrack] = []
    @Published private(set) var subtitleOptions: [SubtitleOption] = []
    @Published private(set) var selectedSubtitleID: String?
    @Published private(set) var activeCues: [SubtitleCue] = []
    @Published private(set) var subtitleError: String?
    /// Addon subtitles grouped by language and ranked for this viewer (`SubtitleCatalog`).
    @Published private(set) var subtitleGroups: [SubtitleLanguageGroup] = []
    /// `.loading` until the addons have answered for the first time.
    @Published private(set) var subtitleListPhase: SubtitleListPhase = .loading
    /// At least one installed, enabled addon can serve subtitles for this title.
    @Published private(set) var hasSubtitleProvider = false
    @Published var subtitleDelay: Double
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published private(set) var nextEpisode: Video?
    @Published private(set) var nextCountdown: Int?
    @Published private(set) var isResolvingNext = false
    @Published private(set) var alternatives: [RankedStream]
    @Published private(set) var engine: PlaybackEngine
    @Published private(set) var mediaInfo: MediaFormatInfo?
    @Published private(set) var playbackPlan: PlaybackPlan?
    @Published private(set) var airPlayRoute: String?
    @Published private(set) var didFinish = false
    @Published var isFill = false
    @Published var playbackRate: Float = 1

    // MARK: Collaborators
    private let env: AppEnvironment
    private var request: PlayerRequest
    private let device: DeviceVideoCapabilities
    private var engineSwitches = 0
    /// The engine was changed on purpose (a fallback) for the file now playing: a restart must keep it.
    private var engineChosenByFallback = false
    private let nowPlaying = NowPlayingService()
    private let audioSession = AudioSessionController()
    private var pictureInPictureGrace: Task<Void, Never>?
    private var statusClear: Task<Void, Never>?

    // MARK: Internals
    private var currentStream: AddonStream?
    private var lastRecordedPosition: Double = -100
    private var lastRetryPosition: Double = 0
    private var timeline: SubtitleTimeline?
    private var cueCache: [String: SubtitleTimeline] = [:]
    private var subtitleTask: Task<Void, Never>?
    private var cueTimer: Timer?
    private var sleepTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var nextStreamsTask: Task<(streams: [AddonStream], errors: [String: AddonError]), Never>?
    private var tornDown = false
    private var preferredAudioApplied = false
    private var preferredSubtitleApplied = false
    // Subtitles: lists, selection and the one-time decisions of the current video.
    private var embeddedOptions: [SubtitleOption] = []
    private var localOptions: [SubtitleOption] = []
    private var subtitleCandidates: [SubtitleCandidate] = []
    /// Subtitles announced by the stream itself.
    private var streamSubtitles: [AddonSubtitle] = []
    /// Answers of the addons asked without a local hash / with the hash computed on this device.
    private var plainSubtitles: [AddonSubtitle] = []
    private var hashedSubtitles: [AddonSubtitle] = []
    private var selectedOption: SubtitleOption?
    private var failedSubtitle: SubtitleOption?
    private var subtitleGeneration = 0
    private var subtitleHashTask: Task<Void, Never>?
    private var localHashes: [String: SubtitleHashResult] = [:]
    private var attemptedHashStreams = Set<String>()
    private var subtitleTracksKnown = false
    private var engineSubtitlesSilenced = false
    private var engineSubtitleSyncPending = false
    private var pendingEmbeddedLanguage: String?
    /// Audio and subtitle choices made by hand in this session (applied to the next episode of the same series).
    private(set) var trackMemory = SessionTrackMemory()
    private var retriedAfterNetworkLoss = false
    private var wasPlayingBeforeInterruption = false
    private var fullMetaLoaded = false
    // TorBox: a torrent source is turned into a direct link before `engine.load`. That link carries a token, so it lives only here
    // (never in `request`, `currentStream`, the library, a download or a Cast hand-off) and is never logged.
    private var debridStream: AddonStream?
    private var debridStreamKey: String?
    private var debridTask: Task<AddonStream, Error>?
    /// Bumped by every start; a start that was overtaken (or outlived `teardown()`) must not load its source into an engine.
    private var loadGeneration = 0
    /// True from the moment the next episode is chosen until its source is loaded: the engine still holds the previous
    /// episode then, and its position must not be saved under the new one.
    private var progressSuspended = false
    private var debridGeneration = 0
    private var debridProgressSequence = 0
    private var skipSegmentsTask: Task<Void, Never>?

    private var playback: PlaybackSettings { env.settings.value.playback }

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
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable, choice: settings.engine,
                                        forceSDR: settings.video.hdrMode == .sdr)
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

    // MARK: Lifecycle

    func start() {
        guard !tornDown else { return }
        bindEngine()

        audioSession.onInterruptionBegan = { [weak self] in
            guard let self = self else { return }
            self.wasPlayingBeforeInterruption = self.snapshot.isPlaying
            self.engine.pause()
        }
        audioSession.onInterruptionEnded = { [weak self] shouldResume in
            guard let self = self else { return }
            if shouldResume && self.wasPlayingBeforeInterruption { self.engine.play() }
        }
        audioSession.onRouteLost = { [weak self] in self?.engine.pause() }
        audioSession.activate()
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
    private func bindEngine() {
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
    private static func container(of request: PlayerRequest, env: AppEnvironment) -> String? {
        switch request.source {
        case .stream(let stream):
            return StreamAnalyzer.analyze(stream, streamingServer: env.streamPreferences().streamingServer).container
        case .download(let item):
            let ext = env.downloads.localURL(for: item)?.pathExtension.lowercased() ?? ""
            return ext.isEmpty ? nil : ext
        }
    }

    /// For a torrent resolved through TorBox the container is the one of the file TorBox returned.
    private var currentContainer: String? {
        if let direct = currentDebridStream() {
            return StreamAnalyzer.analyze(direct, streamingServer: nil).container
        }
        return PlayerViewModel.container(of: request, env: env)
    }

    func teardown() {
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

    private func beginPlayback(startOverride: Double?) async {
        loadGeneration += 1
        let generation = loadGeneration
        isOpeningSource = true
        failure = nil
        statusMessage = nil
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
        case .stream(let stream):
            var source = stream
            if DebridStreamLogic.isTorrent(stream) && env.debrid.isConfigured {
                // A torrent has no address of its own: TorBox turns it into a direct link first (progress and errors show here).
                guard let direct = await resolveTorrentWithTorBox(stream) else { return }
                guard !tornDown, generation == loadGeneration else { return }
                source = direct
                guard adoptEngine(forResolved: direct) else { return }
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
        engine.load(url: url, headers: headers, startAt: start, autoplay: true)
        isOpeningSource = false
        if start != nil && (start ?? 0) > 1 { statusMessage = "Riprendo da \(Format.duration(start ?? 0))" }
        scheduleStatusClear()
    }

    // MARK: TorBox (torrent sources)

    /// What identifies one resolution: the torrent and the video it is played for.
    private func debridKey(for stream: AddonStream) -> String {
        return AddonStream.sourceKey(stream.source) + "|" + DebridStreamLogic.stremioID(meta: meta, video: currentVideo)
    }

    /// The direct link TorBox produced for the source that plays now, if there is one.
    private func currentDebridStream() -> AddonStream? {
        guard let direct = debridStream, let key = debridStreamKey else { return nil }
        guard case .stream(let stream) = request.source else { return nil }
        return debridKey(for: stream) == key ? direct : nil
    }

    /// True while the source that plays is a torrent turned into a link by TorBox (its address carries a token and is not
    /// handed to Cast or DLNA receivers).
    var isPlayingThroughTorBox: Bool { return currentDebridStream() != nil }

    private func forgetDebridLink() {
        debridStream = nil
        debridStreamKey = nil
    }

    /// Turns a torrent into a direct-link stream through TorBox. The player only plays what TorBox already has in its cache:
    /// starting a download needs the user's confirmation, which the stream picker asks for. nil when it did not work (the failure
    /// panel is showing) or when the player moved on or closed in the meantime.
    private func resolveTorrentWithTorBox(_ stream: AddonStream) async -> AddonStream? {
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

    private func debridProgressArrived(_ progress: DebridProgress, sequence: Int, generation: Int) {
        guard generation == debridGeneration, sequence > debridProgressSequence, failure == nil, !tornDown else { return }
        debridProgressSequence = sequence
        statusMessage = DebridFormat.statusLine(for: progress)
    }

    /// The file TorBox returned decides the container, and so the engine (a Matroska file needs MPV). False when no engine can
    /// play it; the failure panel then says why.
    private func adoptEngine(forResolved direct: AddonStream) -> Bool {
        // A restart after an engine fallback keeps the engine the fallback chose: planning again from the file name alone
        // would put the engine that just failed back (and the same failure would repeat).
        if engineChosenByFallback { return true }
        let container = StreamAnalyzer.analyze(direct, streamingServer: nil).container
        let plan = PlaybackPlanner.plan(container: container, facts: nil, device: device,
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable, choice: playback.engine,
                                        forceSDR: playback.video.hdrMode == .sdr)
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
    private func debridAutoSelectable(_ ranked: [RankedStream]) async -> [RankedStream] {
        guard env.debrid.isConfigured else { return ranked }
        let hashes = DebridStreamLogic.hashes(in: ranked)
        var statuses: [String: DebridCacheStatus] = [:]
        if !hashes.isEmpty {
            let report = await env.debrid.availability(infoHashes: hashes)
            statuses = report.statuses
        }
        return DebridStreamLogic.autoSelectable(ranked, statuses: statuses, debridConfigured: true)
    }

    private func loadFullMetaIfNeeded() async {
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

    private func updateNextEpisode() {
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

    private func handle(_ new: EngineSnapshot) {
        let wasReady = snapshot.isReady
        let old = snapshot
        snapshot = new
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
            refreshTracks()
            airPlayRoute = AudioSessionController.airPlayRouteName()
        }
        if new.isExternalPlaybackActive { airPlayRoute = AudioSessionController.airPlayRouteName() } else { airPlayRoute = nil }
        nowPlaying.updateProgress(position: new.position, duration: new.duration, rate: new.isPlaying ? new.rate : 0, isLive: new.isLive)
        if new.isPlaying { lastRetryPosition = new.position }
        recordProgress(force: false)
        evaluateNextEpisodePrompt()
    }

    /// Returns true when a write was scheduled.
    @discardableResult
    private func recordProgress(force: Bool, flushAfter: Bool = false) -> Bool {
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

    private func handleEnded() {
        recordFinalCompletion()
        if case .download(let item) = request.source {
            env.downloads.deleteIfWatched(metaID: item.metaID, videoID: item.videoID)
        }
        if nextEpisode != nil && playback.autoplayNextEpisode {
            Task { await playNext() }
        } else {
            didFinish = true
        }
    }

    private func recordFinalCompletion() {
        let store = env.libraryStore
        let meta = self.meta
        let video = currentVideo
        let duration = max(snapshot.duration, snapshot.position)
        Task { _ = await store.recordProgress(meta: meta, video: video, position: duration, duration: duration) }
    }

    private func handleFailure(_ new: PlaybackFailure) {
        isOpeningSource = false
        if tryEngineFallback(after: new) { return }
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

    private func canUse(_ kind: PlaybackEngineKind) -> Bool {
        switch kind {
        case .avPlayer: return true
        case .mpv: return PlaybackEngineFactory.mpvAvailable
        }
    }

    /// Facts measured by the engine arrive after loading: show them, and if they show that the other engine is the
    /// right one for this file (for example an HEVC track tagged hev1, or Dolby Vision profile 7), switch once.
    private func handleMediaInfo(_ info: MediaFormatInfo) {
        mediaInfo = info
        let plan = PlaybackPlanner.plan(container: info.container ?? currentContainer, facts: info, device: device,
                                        mpvAvailable: PlaybackEngineFactory.mpvAvailable, choice: playback.engine,
                                        forceSDR: playback.video.hdrMode == .sdr)
        playbackPlan = plan
        guard playback.engine == .automatic, info.source == .avFoundation, engineSwitches == 0,
              let wanted = plan.engine, wanted != engine.kind, canUse(wanted) else { return }
        switchEngine(to: wanted, reason: plan.notes.first(where: { $0.severity != .warning })?.text ?? "Cambio motore di riproduzione…")
    }

    /// An engine that cannot open the file is replaced by the other one, once, resuming at the same position.
    /// Network problems never trigger a switch.
    private func tryEngineFallback(after failure: PlaybackFailure) -> Bool {
        guard playback.engine == .automatic, engineSwitches < 2, !tornDown else { return false }
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

    private func switchEngine(to kind: PlaybackEngineKind, reason: String) {
        guard !tornDown, kind != engine.kind else { return }
        engineSwitches += 1
        engineChosenByFallback = true
        let position = max(snapshot.position, lastRetryPosition)
        engine.teardown()
        engine = PlaybackEngineFactory.make(kind, settings: playback, device: device)
        mediaInfo = nil
        failure = nil
        bindEngine()
        engineReplaced()
        statusMessage = reason
        Task { await beginPlayback(startOverride: position > 5 ? position : nil) }
    }

    // MARK: Transport commands

    // MARK: Skip intro / recap

    /// Asks IntroDB for the episode now playing (IMDb id, season and episode: nothing else leaves the device). Nothing is
    /// shown when the setting is off, the title has no IMDb id, or the service knows nothing.
    private func loadSkipSegments() {
        skipSegmentsTask?.cancel()
        skipSegments = .none
        guard playback.skipSegmentsEnabled, !tornDown, let video = currentVideo, let season = video.season, let episode = video.episode,
              let imdb = ExternalIDs.imdbID(fromMetaID: meta.id) else { return }
        let videoID = video.id
        skipSegmentsTask = Task { [weak self, skipSegmentsService = env.skipSegments] in
            let found = await skipSegmentsService.segments(imdbID: imdb, season: season, episode: episode)
            guard !Task.isCancelled, let self = self, !self.tornDown, self.currentVideo?.id == videoID else { return }
            self.skipSegments = found ?? .none
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
        // Before the engine has the file there is nothing to play or pause: a tap would only set a false state.
        guard !isOpeningSource else { return }
        if snapshot.isPlaying { engine.pause() } else { engine.play() }
    }

    func skip(_ seconds: Double) { engine.seek(by: seconds) }
    func skipBack() { engine.seek(by: -Double(playback.skipBackSeconds)) }
    func skipForward() { engine.seek(by: Double(playback.skipForwardSeconds)) }
    func seek(to seconds: Double) { engine.seek(to: seconds, precise: true) }

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

    private func configureRemoteCommands() {
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

    // MARK: Episodes

    func play(episode: Video) async {
        await switchEpisode(to: episode)
    }

    func playPrevious() async {
        if let previous = previousEpisode { await switchEpisode(to: previous) }
    }

    func playNext() async {
        guard let next = nextEpisode else { return }
        await switchEpisode(to: next)
    }

    private func switchEpisode(to video: Video) async {
        guard !isResolvingNext else { return }
        isResolvingNext = true
        countdownTask?.cancel()
        nextCountdown = nil
        statusMessage = "Cerco la sorgente per \(video.episodeLabel ?? "l'episodio")…"
        defer { isResolvingNext = false }

        // Persist where we left the current episode before moving on, then stop recording until the new source is loaded:
        // finding it (and, for a torrent, TorBox's answer) can take a while and the old episode would be saved as the new one.
        recordProgress(force: true)
        progressSuspended = true
        engine.pause()

        let result: (streams: [AddonStream], errors: [String: AddonError])
        if let prefetched = nextStreamsTask, video.id == nextEpisode?.id {
            result = await prefetched.value
        } else {
            result = await env.service.allStreams(type: meta.type, videoID: video.id)
        }
        let ranked = StreamSelector.rank(result.streams, preferences: env.streamPreferences())
        let binge = currentStream?.behaviorHints.bingeGroup ?? env.bingeGroup(forMeta: meta.id)
        let choices = await debridAutoSelectable(ranked)
        guard let best = StreamSelector.autoSelect(choices, previousBingeGroup: binge) else {
            statusMessage = nil
            handleFailure(PlaybackFailure(kind: .notFound, detail: "Nessuna sorgente riproducibile per \(video.episodeLabel ?? "questo episodio")."))
            return
        }
        currentVideo = video
        currentStream = best.stream
        sourceName = best.stream.name ?? best.stream.addonName ?? "Sorgente"
        request.video = video
        request.source = .stream(best.stream)
        engineChosenByFallback = false
        alternatives = ranked.filter { $0.info.support.isPlayable && $0.id != best.id }
        resetSubtitleStateForNewVideo()
        loadSkipSegments()
        lastRecordedPosition = -100
        didFinish = false
        nextStreamsTask = nil
        updateNextEpisode()
        env.setBingeGroup(best.stream.behaviorHints.bingeGroup, forMeta: meta.id)
        nowPlaying.setMetadata(title: meta.name, subtitle: episodeSubtitle(),
                               artworkURL: (video.thumbnail ?? meta.background ?? meta.poster).flatMap { URL.lenient($0) }, loader: env.images)
        await beginPlayback(startOverride: nil)
        await loadSubtitleOptions()
    }

    /// Near the end of an episode: prefetch the next one's sources and, if autoplay is on, run the countdown.
    private func evaluateNextEpisodePrompt() {
        guard let next = nextEpisode, snapshot.duration > 120, !snapshot.isLive else { return }
        let remaining = snapshot.duration - snapshot.position
        if nextStreamsTask == nil, snapshot.position / snapshot.duration > 0.8 {
            let service = env.service
            let type = meta.type
            nextStreamsTask = Task { await service.allStreams(type: type, videoID: next.id) }
        }
        let countdown = playback.nextEpisodeCountdownSeconds
        guard playback.autoplayNextEpisode, countdown > 0 else { return }
        if remaining <= Double(countdown) + 1, remaining > 0.5, countdownTask == nil, nextCountdown == nil, snapshot.isPlaying {
            startCountdown(from: countdown)
        } else if remaining > Double(countdown) + 3 {
            cancelCountdown()
        }
    }

    private func startCountdown(from seconds: Int) {
        nextCountdown = seconds
        countdownTask = Task { [weak self] in
            var left = seconds
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                self?.nextCountdown = left
            }
            if Task.isCancelled { return }
            self?.countdownTask = nil
            await self?.playNext()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        nextCountdown = nil
    }

    // MARK: Tracks

    private func refreshTracks() {
        subtitleTracksKnown = true
        audioTracks = engine.audioTracks()
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
    private func applyPreferredAudio() {
        let languages = TrackPreferences.audioLanguages(
            remembered: trackMemory.audioLanguageToApply(forMeta: meta.id),
            primary: SettingsStore.resolvedLanguage(playback.preferredAudioLanguage),
            secondary: SettingsStore.resolvedLanguage(playback.secondaryAudioLanguage))
        guard let match = TrackPreferences.pickAudio(languages: languages, tracks: audioTracks), !match.isSelected else { return }
        engine.selectAudio(id: match.id)
        audioTracks = engine.audioTracks()
    }

    /// Audio track picked by the viewer. Its language is remembered for the next episode of this series.
    func selectAudio(_ track: EngineTrack) {
        preferredAudioApplied = true
        trackMemory.rememberAudio(language: TrackPreferences.audioLanguageToRemember(for: track), metaID: meta.id)
        engine.selectAudio(id: track.id)
        audioTracks = engine.audioTracks()
    }

    /// A new engine replaced the old one (fallback to the other engine): its tracks are unknown until it reports them, the audio
    /// language is chosen again, and the subtitle on screen is carried over. A downloaded or imported subtitle is drawn by the app,
    /// so it survives as it is; an embedded track has another id in the new engine and is looked up again by language.
    func engineReplaced() {
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
    }

    // MARK: Subtitles

    private func refreshEmbeddedSubtitleOptions() {
        var options: [SubtitleOption] = []
        for track in engine.embeddedSubtitleTracks() {
            let code = TrackPreferences.languageCode(language: track.language, title: track.title)
            options.append(SubtitleOption(id: "embedded-\(track.id)", title: track.title, detail: "Incorporato",
                                          language: track.language, kind: .embedded(track.id), languageCode: code))
        }
        embeddedOptions = options
        // The embedded track that was on is no longer reported: do not claim it still is.
        if let selected = selectedOption, case .embedded = selected.kind {
            let stillThere = options.contains(where: { (option: SubtitleOption) -> Bool in
                return option.id == selected.id
            })
            if !stillThere {
                selectedSubtitleID = nil
                selectedOption = nil
            }
        }
        publishSubtitleOptions()
    }

    /// `subtitleOptions` = embedded tracks first, then the addon subtitles in the order of the groups, then imported files.
    private func publishSubtitleOptions() {
        var addonOptions: [SubtitleOption] = []
        for group in subtitleGroups {
            for candidate in group.candidates { addonOptions.append(SubtitleOption.addon(candidate)) }
        }
        subtitleOptions = embeddedOptions + addonOptions + localOptions
    }

    // MARK: Subtitles from addons

    /// Languages for the ranking of the list and for the automatic choice: what the viewer picked by hand for this title, then the
    /// preferred language, then the secondary one ("off" means none).
    private func subtitleWishes() -> (ranking: [String], automatic: [String]) {
        let remembered = trackMemory.subtitleChoiceToApply(forMeta: meta.id)
        let primary = SettingsStore.resolvedLanguage(playback.preferredSubtitleLanguage)
        let secondary = SettingsStore.resolvedLanguage(playback.secondarySubtitleLanguage)
        let ranking = TrackPreferences.subtitleRanking(remembered: remembered, primary: primary, secondary: secondary)
        let automatic = TrackPreferences.automaticSubtitleLanguages(remembered: remembered, primary: primary, secondary: secondary)
        return (ranking, automatic)
    }

    /// Asks every installed subtitles addon for this video. The first answer carries what the stream announces (hash, size, file
    /// name) and never waits for anything else. When the stream announces no hash, one is computed on this device in the
    /// background (`SubtitleHashProbe`, once per stream and session; never for downloads, HLS or non-public http) and the addons
    /// are asked again with it: both answers end up in the list.
    private func loadSubtitleOptions() async {
        subtitleGeneration += 1
        let generation = subtitleGeneration
        subtitleHashTask?.cancel()
        subtitleHashTask = nil

        let stream = currentStream
        let type = meta.type
        let videoID = currentVideo?.id ?? meta.id
        var announced: [AddonSubtitle] = []
        for subtitle in stream?.subtitles ?? [] {
            var entry = subtitle
            if entry.addonName == nil { entry.addonName = stream?.addonName }
            announced.append(entry)
        }
        streamSubtitles = announced
        plainSubtitles = []
        hashedSubtitles = []
        subtitleListPhase = .loading
        rebuildSubtitleList()
        applyPreferredSubtitleIfNeeded()

        let handles = await env.service.handles()
        guard generation == subtitleGeneration, !tornDown else { return }
        let providers = SubtitleAddonSupport.providers(in: handles, type: type, videoID: videoID)
        hasSubtitleProvider = !providers.isEmpty
        if providers.isEmpty {
            finishSubtitleLoading()
            return
        }

        var known: SubtitleHashResult?
        if let stream = stream { known = localHashes[stream.id] }
        let params = SubtitleVideoParams.resolve(stream: stream, local: known, filename: nil)
        startHashProbeIfNeeded(generation: generation, type: type, videoID: videoID)
        let answer = await env.service.subtitles(type: type, videoID: videoID, params: params)
        guard generation == subtitleGeneration, !tornDown else { return }
        if known != nil { hashedSubtitles = answer } else { plainSubtitles = answer }
        finishSubtitleLoading()
    }

    private func finishSubtitleLoading() {
        subtitleListPhase = .ready
        rebuildSubtitleList()
        applyPreferredSubtitleIfNeeded()
    }

    private func startHashProbeIfNeeded(generation: Int, type: String, videoID: String) {
        var isDownload = false
        if case .download = request.source { isDownload = true }
        guard let stream = currentStream, SubtitleHashPlan.shouldProbe(stream: stream, isDownload: isDownload) else { return }
        if localHashes[stream.id] != nil || attemptedHashStreams.contains(stream.id) { return }
        attemptedHashStreams.insert(stream.id)
        let probe = SubtitleHashProbe(http: env.http, policy: env.settings.value.networkPolicy(allowLoopback: env.isUITesting))
        subtitleHashTask = Task { [weak self] in
            let outcome = await probe.probe(stream: stream)
            if Task.isCancelled { return }
            await self?.hashProbeFinished(outcome, stream: stream, type: type, videoID: videoID, generation: generation)
        }
    }

    private func hashProbeFinished(_ outcome: Result<SubtitleHashResult, SubtitleHashFailure>, stream: AddonStream,
                                   type: String, videoID: String, generation: Int) async {
        guard !tornDown else { return }
        switch outcome {
        case .failure(let reason):
            // Not an error for the viewer: the addons simply keep answering without a hash.
            if reason != .cancelled {
                env.diagnostics.logDetached(.info, "subtitles", "Hash del video non calcolato: \(reason.message)")
            }
        case .success(let hashed):
            localHashes[stream.id] = hashed
            guard generation == subtitleGeneration else { return }
            let params = SubtitleVideoParams.resolve(stream: stream, local: hashed, filename: nil)
            let refined = await env.service.subtitles(type: type, videoID: videoID, params: params)
            guard generation == subtitleGeneration, !tornDown else { return }
            hashedSubtitles = refined
            rebuildSubtitleList()
        }
    }

    /// Ranks and groups what the stream and the addons offered (`SubtitleCatalog`). Answers with the local hash come first.
    private func rebuildSubtitleList() {
        var pool: [AddonSubtitle] = streamSubtitles
        pool.append(contentsOf: hashedSubtitles)
        pool.append(contentsOf: plainSubtitles)
        // The subtitle on screen stays in the list even if a refreshed answer no longer carries it.
        if let selected = selectedOption, case .addon(let subtitle) = selected.kind {
            let wanted = subtitle.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let present = pool.contains(where: { (entry: AddonSubtitle) -> Bool in
                return entry.url.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            })
            if !present { pool.append(subtitle) }
        }
        let preferences = SubtitlePreferences(languages: subtitleWishes().ranking, preferHearingImpaired: false)
        let candidates = SubtitleCatalog.candidates(from: pool, preferences: preferences)
        subtitleCandidates = candidates
        let groups = SubtitleCatalog.groups(from: candidates)
        if groups != subtitleGroups { subtitleGroups = groups }
        publishSubtitleOptions()
    }

    // MARK: Automatic choice

    /// At the start of a video: an embedded track in the preferred language, otherwise the best addon subtitle for the preferred
    /// language, then the same for the secondary one. Nothing when both are "off". What the viewer picked by hand earlier for this
    /// title replaces the settings. Runs once the engine has reported its tracks and the addons have answered.
    private func applyPreferredSubtitleIfNeeded() {
        guard !preferredSubtitleApplied, selectedSubtitleID == nil, subtitleTracksKnown, !tornDown else { return }
        let wishes = subtitleWishes().automatic
        if wishes.isEmpty {
            preferredSubtitleApplied = true
            silenceEngineSubtitles()
            return
        }
        var embedded: [EmbeddedSubtitleInfo] = []
        for option in embeddedOptions {
            embedded.append(EmbeddedSubtitleInfo(optionID: option.id, title: option.title, language: option.language))
        }
        let decision = TrackPreferences.decide(languages: wishes, embedded: embedded, candidates: subtitleCandidates,
                                               listIsFinal: subtitleListPhase == .ready)
        switch decision {
        case .embedded(let optionID):
            guard let option = embeddedOptions.first(where: { (item: SubtitleOption) -> Bool in
                return item.id == optionID
            }) else { return }
            preferredSubtitleApplied = true
            activateSubtitle(option)
        case .addon(let candidate):
            preferredSubtitleApplied = true
            activateSubtitle(SubtitleOption.addon(candidate))
        case .wait:
            return
        case .nothing:
            preferredSubtitleApplied = true
            silenceEngineSubtitles()
        }
    }

    /// No subtitle was chosen: an embedded track the engine switched on by itself (a default or forced track) is switched off, so
    /// that what the sheet says ("Disattivati") is what the viewer sees. Asked once per video.
    private func silenceEngineSubtitles() {
        if engineSubtitlesSilenced { return }
        engineSubtitlesSilenced = true
        let engineHasOneOn = engine.embeddedSubtitleTracks().contains(where: { (track: EngineTrack) -> Bool in
            return track.isSelected
        })
        if engineHasOneOn { engine.selectEmbeddedSubtitle(id: nil) }
    }

    /// After an engine change the new engine may switch on a subtitle track of its own: when the viewer's subtitle is drawn by
    /// the app (downloaded or imported), it must be the only one on screen.
    private func syncEngineSubtitleWithSelection() {
        if !engineSubtitleSyncPending || embeddedOptions.isEmpty { return }
        engineSubtitleSyncPending = false
        guard let selected = selectedOption else { return }
        switch selected.kind {
        case .addon, .local:
            engine.selectEmbeddedSubtitle(id: nil)
        case .embedded:
            return
        }
    }

    /// After an engine change the embedded track that was on is looked up again by language: track ids differ between engines.
    private func reselectEmbeddedAfterEngineChange() {
        guard let language = pendingEmbeddedLanguage, !embeddedOptions.isEmpty else { return }
        pendingEmbeddedLanguage = nil
        guard selectedSubtitleID == nil else { return }
        var embedded: [EmbeddedSubtitleInfo] = []
        for option in embeddedOptions {
            embedded.append(EmbeddedSubtitleInfo(optionID: option.id, title: option.title, language: option.language))
        }
        if let match = TrackPreferences.embeddedMatch(embedded, language: language),
           let option = embeddedOptions.first(where: { (item: SubtitleOption) -> Bool in return item.id == match.optionID }) {
            activateSubtitle(option)
        } else {
            statusMessage = "I sottotitoli incorporati non sono disponibili con questo motore."
            scheduleStatusClear()
        }
    }

    /// A new video (next episode, other source): the subtitle on screen, the lists and the one-time decisions start over.
    /// What the viewer chose by hand (`trackMemory`) is kept: it applies to the next video of the same title.
    private func resetSubtitleStateForNewVideo() {
        subtitleTask?.cancel()
        subtitleHashTask?.cancel()
        subtitleHashTask = nil
        subtitleGeneration += 1
        timeline = nil
        activeCues = []
        selectedSubtitleID = nil
        selectedOption = nil
        subtitleError = nil
        failedSubtitle = nil
        cueCache = [:]
        streamSubtitles = []
        plainSubtitles = []
        hashedSubtitles = []
        subtitleCandidates = []
        subtitleGroups = []
        embeddedOptions = []
        localOptions = []
        subtitleOptions = []
        audioTracks = []
        subtitleListPhase = .loading
        hasSubtitleProvider = false
        preferredAudioApplied = false
        preferredSubtitleApplied = false
        subtitleTracksKnown = false
        engineSubtitlesSilenced = false
        engineSubtitleSyncPending = false
        pendingEmbeddedLanguage = nil
    }

    // MARK: Choosing a subtitle

    /// Subtitles off, chosen by the viewer. Remembered for the next episode of this series.
    func disableSubtitles() {
        preferredSubtitleApplied = true
        trackMemory.rememberSubtitle(.off, metaID: meta.id)
        subtitleTask?.cancel()
        selectedSubtitleID = nil
        selectedOption = nil
        timeline = nil
        activeCues = []
        subtitleError = nil
        failedSubtitle = nil
        engine.selectEmbeddedSubtitle(id: nil)
    }

    /// A subtitle chosen by the viewer. Its language is remembered for the next episode of this series.
    func selectSubtitle(_ option: SubtitleOption) {
        preferredSubtitleApplied = true
        switch option.kind {
        case .embedded, .addon:
            if let code = option.languageCode {
                trackMemory.rememberSubtitle(.language(code), metaID: meta.id)
            } else {
                trackMemory.forgetSubtitle()
            }
        case .local:
            trackMemory.forgetSubtitle()
        }
        activateSubtitle(option)
    }

    /// Switches a subtitle on without touching the memory of what the viewer chose (used by the automatic choice as well).
    private func activateSubtitle(_ option: SubtitleOption) {
        subtitleTask?.cancel()
        subtitleError = nil
        failedSubtitle = nil
        selectedSubtitleID = option.id
        selectedOption = option
        switch option.kind {
        case .embedded(let id):
            timeline = nil
            activeCues = []
            engine.selectEmbeddedSubtitle(id: id)
        case .addon(let subtitle):
            engine.selectEmbeddedSubtitle(id: nil)
            guard let url = URL.lenient(subtitle.url) else {
                subtitleDidFail(option, message: "L'indirizzo dei sottotitoli non è valido.")
                return
            }
            let loader = SubtitleFileLoader(http: env.http)
            loadExternal(option) { () async throws -> Data in
                return try await loader.download(url: url)
            }
        case .local(let url):
            engine.selectEmbeddedSubtitle(id: nil)
            loadExternal(option) { () async throws -> Data in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }
        }
    }

    /// Downloads (or reads) and parses a subtitle; the cues are drawn by the app's own overlay, so they do not depend on the engine.
    private func loadExternal(_ option: SubtitleOption, fetch: @escaping () async throws -> Data) {
        if let cached = cueCache[option.id] {
            timeline = cached
            updateCues()
            return
        }
        timeline = nil
        activeCues = []
        let language = option.language
        let encoding = option.encodingHint
        subtitleTask = Task { [weak self] in
            do {
                let data = try await fetch()
                let cues = try await SubtitleFileLoader.parse(data, languageHint: language, encodingHint: encoding)
                if Task.isCancelled { return }
                self?.subtitleDidLoad(option, cues: cues)
            } catch {
                if Task.isCancelled { return }
                self?.subtitleDidFail(option, message: SubtitleFileLoader.message(for: error))
            }
        }
    }

    private func subtitleDidLoad(_ option: SubtitleOption, cues: [SubtitleCue]) {
        let loaded = SubtitleTimeline(cues: cues)
        cueCache[option.id] = loaded
        guard selectedSubtitleID == option.id else { return }
        timeline = loaded
        updateCues()
    }

    /// The file could not be downloaded or read: say so, clear the selection and leave playback alone.
    private func subtitleDidFail(_ option: SubtitleOption, message: String) {
        guard selectedSubtitleID == option.id else { return }
        selectedSubtitleID = nil
        selectedOption = nil
        timeline = nil
        activeCues = []
        subtitleError = message
        failedSubtitle = option
        statusMessage = message
        scheduleStatusClear()
        env.diagnostics.logDetached(.warning, "subtitles", message)
    }

    /// Tries again with the subtitle that failed.
    func retrySubtitle() {
        guard let option = failedSubtitle else { return }
        activateSubtitle(option)
    }

    func importLocalSubtitle(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let option = SubtitleOption(id: "local-\(url.lastPathComponent)", title: name, detail: "File locale", language: nil, kind: .local(url))
        localOptions.removeAll(where: { (item: SubtitleOption) -> Bool in return item.id == option.id })
        localOptions.append(option)
        // A file with the same name may have been replaced since the last import.
        cueCache.removeValue(forKey: option.id)
        publishSubtitleOptions()
        selectSubtitle(option)
    }

    func adjustSubtitleDelay(by amount: Double) {
        subtitleDelay = min(60, max(-60, subtitleDelay + amount))
        engine.setEmbeddedSubtitleDelay(subtitleDelay)
        updateCues()
    }

    private func startCueTimer() {
        cueTimer?.invalidate()
        cueTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCues() }
        }
    }

    private func updateCues() {
        guard let timeline = timeline else {
            if !activeCues.isEmpty { activeCues = [] }
            return
        }
        var cues = timeline.active(at: engine.currentTime(), delay: subtitleDelay)
        if playback.stripHearingImpairedTags {
            cues = cues.compactMap { cue -> SubtitleCue? in
                let text = SubtitleCleaner.stripHearingImpaired(cue.text)
                return text.isEmpty ? nil : SubtitleCue(start: cue.start, end: cue.end, text: text)
            }
        }
        if cues != activeCues { activeCues = cues }
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

    private func applyBackgroundPolicy(phase: PlayerBackgroundPolicy.Phase, graceExpired: Bool) {
        let decision = PlayerBackgroundPolicy.decide(PlayerBackgroundPolicy.State(
            phase: phase,
            isPlaying: snapshot.isPlaying,
            isPictureInPictureActive: snapshot.isPictureInPictureActive,
            isExternalPlaybackActive: snapshot.isExternalPlaybackActive,
            isPictureInPicturePossible: snapshot.isPictureInPicturePossible,
            autoPictureInPicture: playback.autoPictureInPicture,
            allowBackgroundAudio: playback.allowBackgroundAudio,
            pictureInPictureGraceExpired: graceExpired))
        if phase == .active { airPlayRoute = AudioSessionController.airPlayRouteName() }
        if decision.recordProgress { recordProgress(force: true) }
        switch decision.video {
        case .attach: engine.setVideoDetached(false)
        case .detach: engine.setVideoDetached(true)          // keep the sound, drop the picture
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

    struct CastPlan {
        var media: CastMedia
        var info: StreamInfo
        var headers: [String: String]
    }

    /// Everything needed to send the current video to a remote receiver, or nil when it cannot be sent
    /// (downloaded files only exist on this phone; AirPlay is the way to put them on a TV).
    func castPlan() -> CastPlan? {
        guard case .stream(let stream) = request.source,
              let url = StreamResolver.playbackURL(for: stream, streamingServer: env.streamPreferences().streamingServer) else { return nil }
        let info = StreamAnalyzer.analyze(stream, streamingServer: env.streamPreferences().streamingServer)
        let artwork = (currentVideo?.thumbnail ?? meta.poster ?? meta.background).flatMap { URL.lenient($0) }
        let media = CastMedia(url: url, title: meta.name, subtitle: episodeSubtitle(), artworkURL: artwork,
                              contentType: CastMedia.contentType(forContainer: info.container),
                              isLive: snapshot.isLive, startPosition: max(snapshot.position, 0))
        return CastPlan(media: media, info: info, headers: stream.behaviorHints.proxyRequestHeaders)
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

    private var lastRemoteRecord: Double = -100

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

    /// A newer message replaces the older one's timer, so a long message is not cut short by an earlier schedule.
    private func scheduleStatusClear(after seconds: Double = 3.5) {
        statusClear?.cancel()
        statusClear = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }
}
