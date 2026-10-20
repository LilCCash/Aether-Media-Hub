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
    private let nowPlaying = NowPlayingService()
    private let audioSession = AudioSessionController()

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

    private var currentContainer: String? { PlayerViewModel.container(of: request, env: env) }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
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
        failure = nil
        statusMessage = nil
        retriedAfterNetworkLoss = false
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
            guard let resolved = StreamResolver.playbackURL(for: stream, streamingServer: env.streamPreferences().streamingServer) else {
                handleFailure(PlaybackFailure(kind: .formatUnsupported, detail: "Sorgente non riproducibile"))
                return
            }
            if let blocked = await env.validateMediaURL(resolved) {
                handleFailure(PlaybackFailure(kind: .unknown, detail: blocked.message))
                return
            }
            url = resolved
            headers = stream.behaviorHints.proxyRequestHeaders
        }

        var start = startOverride
        if start == nil, playback.autoResume {
            let key = currentVideo?.id ?? meta.id
            if let saved = await env.libraryStore.resumePosition(metaID: meta.id, videoID: key) {
                start = max(0, saved - Double(playback.resumeRewindSeconds))
            }
        }
        lastRetryPosition = start ?? 0
        engine.setRate(playbackRate)
        engine.load(url: url, headers: headers, startAt: start, autoplay: true)
        if start != nil && (start ?? 0) > 1 { statusMessage = "Riprendo da \(Format.duration(start ?? 0))" }
        scheduleStatusClear()
    }

    private func loadFullMetaIfNeeded() async {
        guard !fullMetaLoaded else { return }
        fullMetaLoaded = true
        if meta.videos.isEmpty || (currentVideo != nil && !meta.videos.contains(where: { $0.id == currentVideo?.id })) {
            let resolution = await env.service.meta(type: meta.type, id: meta.id, fallback: meta)
            meta = resolution.meta.merging(fallback: meta)
            if let id = currentVideo?.id, let full = meta.videos.first(where: { $0.id == id }) { currentVideo = full }
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
        snapshot = new
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
        if tryEngineFallback(after: new) { return }
        failure = new
        env.diagnostics.logDetached(.error, "player", "Errore di riproduzione (\(new.kind.rawValue)): \(new.detail)")
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

    func togglePlayPause() {
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

    func startPictureInPicture() { engine.startPictureInPicture() }
    var supportsPictureInPicture: Bool { engine.supportsPictureInPicture }

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
        alternatives = alternatives.filter { $0.id != item.id }
        let position = max(snapshot.position, lastRetryPosition)
        failure = nil
        Task { await beginPlayback(startOverride: position > 5 ? position : nil) }
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

        // Persist where we left the current episode before moving on.
        recordProgress(force: true)

        let result: (streams: [AddonStream], errors: [String: AddonError])
        if let prefetched = nextStreamsTask, video.id == nextEpisode?.id {
            result = await prefetched.value
        } else {
            result = await env.service.allStreams(type: meta.type, videoID: video.id)
        }
        let ranked = StreamSelector.rank(result.streams, preferences: env.streamPreferences())
        let binge = currentStream?.behaviorHints.bingeGroup ?? env.bingeGroup(forMeta: meta.id)
        guard let best = StreamSelector.autoSelect(ranked, previousBingeGroup: binge) else {
            statusMessage = nil
            handleFailure(PlaybackFailure(kind: .notFound, detail: "Nessuna sorgente riproducibile per \(video.episodeLabel ?? "questo episodio")."))
            return
        }
        currentVideo = video
        currentStream = best.stream
        sourceName = best.stream.name ?? best.stream.addonName ?? "Sorgente"
        request.video = video
        request.source = .stream(best.stream)
        alternatives = ranked.filter { $0.info.support.isPlayable && $0.id != best.id }
        resetSubtitleStateForNewVideo()
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
        audioTracks = engine.audioTracks()
        refreshEmbeddedSubtitleOptions()
        if !preferredAudioApplied, !audioTracks.isEmpty {
            preferredAudioApplied = true
            applyPreferredAudio()
        }
        applyPreferredSubtitleIfNeeded()
    }

    private func applyPreferredAudio() {
        guard let language = SettingsStore.resolvedLanguage(playback.preferredAudioLanguage) else { return }
        if let match = audioTracks.first(where: { LanguageCodes.matches($0.language ?? "", language) || LanguageCodes.matches($0.title, language) }),
           !match.isSelected {
            engine.selectAudio(id: match.id)
            audioTracks = engine.audioTracks()
        }
    }

    func selectAudio(_ track: EngineTrack) {
        engine.selectAudio(id: track.id)
        audioTracks = engine.audioTracks()
    }

    // MARK: Subtitles

    private func refreshEmbeddedSubtitleOptions() {
        let embedded = engine.embeddedSubtitleTracks().map {
            SubtitleOption(id: "embedded-\($0.id)", title: $0.title, detail: "Incorporato", language: $0.language, kind: .embedded($0.id))
        }
        let others = subtitleOptions.filter { if case .embedded = $0.kind { return false } else { return true } }
        subtitleOptions = embedded + others
    }

    private func loadSubtitleOptions() async {
        guard let video = currentVideo ?? Optional(Video(id: meta.id, title: meta.name)) else { return }
        var options: [SubtitleOption] = []
        var seen = Set<String>()
        func add(_ subtitle: AddonSubtitle, source: String?) {
            guard seen.insert(subtitle.url).inserted else { return }
            let language = LanguageCodes.displayName(subtitle.lang)
            options.append(SubtitleOption(id: "addon-\(subtitle.id)-\(options.count)",
                                          title: subtitle.label ?? language,
                                          detail: [subtitle.label != nil ? language : nil, source ?? subtitle.addonName].compactMap { $0 }.joined(separator: " · "),
                                          language: subtitle.lang, kind: .addon(subtitle)))
        }
        for subtitle in currentStream?.subtitles ?? [] { add(subtitle, source: currentStream?.addonName) }
        let hints = currentStream?.behaviorHints
        let remote = await env.service.subtitles(type: meta.type, videoID: video.id, videoHash: hints?.videoHash,
                                                 videoSize: hints?.videoSize, filename: hints?.filename)
        for subtitle in remote { add(subtitle, source: nil) }
        let embedded = subtitleOptions.filter { if case .embedded = $0.kind { return true } else { return false } }
        let locals = subtitleOptions.filter { if case .local = $0.kind { return true } else { return false } }
        subtitleOptions = embedded + options + locals
        applyPreferredSubtitleIfNeeded()
    }

    private func applyPreferredSubtitleIfNeeded() {
        guard !preferredSubtitleApplied, selectedSubtitleID == nil else { return }
        guard let language = SettingsStore.resolvedLanguage(playback.preferredSubtitleLanguage) else { return }
        guard !subtitleOptions.isEmpty else { return }
        // Prefer embedded tracks (no download, perfectly in sync) and fall back to addon subtitles.
        let match = subtitleOptions.first(where: {
            if case .embedded = $0.kind { return LanguageCodes.matches($0.language ?? "", language) || LanguageCodes.matches($0.title, language) }
            return false
        }) ?? subtitleOptions.first(where: {
            if case .addon = $0.kind { return LanguageCodes.matches($0.language ?? "", language) }
            return false
        })
        if let match = match {
            preferredSubtitleApplied = true
            selectSubtitle(match)
        }
    }

    func disableSubtitles() {
        selectedSubtitleID = nil
        timeline = nil
        activeCues = []
        subtitleError = nil
        engine.selectEmbeddedSubtitle(id: nil)
    }

    func selectSubtitle(_ option: SubtitleOption) {
        subtitleTask?.cancel()
        subtitleError = nil
        selectedSubtitleID = option.id
        switch option.kind {
        case .embedded(let id):
            timeline = nil
            activeCues = []
            engine.selectEmbeddedSubtitle(id: id)
        case .addon(let subtitle):
            engine.selectEmbeddedSubtitle(id: nil)
            guard let url = URL.lenient(subtitle.url) else { subtitleError = "URL dei sottotitoli non valido."; return }
            loadExternal(cacheKey: option.id, language: subtitle.lang) {
                let response = try await self.env.http.send(HTTPRequest(url: url, timeout: 15, maxBytes: HTTPLimits.subtitle, purpose: .addonRequest))
                guard response.isSuccess else { throw AddonError.http(status: response.statusCode) }
                return response.data
            }
        case .local(let url):
            engine.selectEmbeddedSubtitle(id: nil)
            loadExternal(cacheKey: option.id, language: option.language) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }
        }
    }

    private func loadExternal(cacheKey: String, language: String?, fetch: @escaping () async throws -> Data) {
        if let cached = cueCache[cacheKey] {
            timeline = cached
            updateCues()
            return
        }
        timeline = nil
        activeCues = []
        subtitleTask = Task { [weak self] in
            do {
                let data = try await fetch()
                let cues = try SubtitleParser.parse(data, languageHint: language)
                if Task.isCancelled { return }
                let timeline = SubtitleTimeline(cues: cues)
                self?.cueCache[cacheKey] = timeline
                if self?.selectedSubtitleID == cacheKey {
                    self?.timeline = timeline
                    self?.updateCues()
                }
            } catch {
                if Task.isCancelled { return }
                let message: String
                if let subtitleError = error as? SubtitleError { message = subtitleError.message }
                else if let addonError = error as? AddonError { message = "Sottotitoli non scaricabili: \(addonError.message)" }
                else { message = "Sottotitoli non utilizzabili: \(error.localizedDescription)" }
                self?.subtitleError = message
            }
        }
    }

    func importLocalSubtitle(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let option = SubtitleOption(id: "local-\(url.lastPathComponent)", title: name, detail: "File locale", language: nil, kind: .local(url))
        subtitleOptions.removeAll(where: { $0.id == option.id })
        subtitleOptions.append(option)
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

    func scenePhaseChanged(isActive: Bool) {
        if isActive {
            engine.setVideoDetached(false)
            airPlayRoute = AudioSessionController.airPlayRouteName()
            return
        }
        recordProgress(force: true)
        if snapshot.isPictureInPictureActive || snapshot.isExternalPlaybackActive { return }
        if playback.allowBackgroundAudio {
            engine.setVideoDetached(true)          // keep the sound, drop the picture
        } else {
            engine.pause()
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

    func externalSubtitleCount() -> Int {
        return subtitleOptions.filter { if case .embedded = $0.kind { return false } else { return true } }.count
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
        return StreamAnalyzer.analyze(stream, streamingServer: env.streamPreferences().streamingServer,
                                      capabilities: PlaybackEngineFactory.capabilities)
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

    private func scheduleStatusClear() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            self?.statusMessage = nil
        }
    }
}
