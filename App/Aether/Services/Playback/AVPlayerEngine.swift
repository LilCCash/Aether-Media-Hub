import AVFoundation
import AVKit
import Combine
import AetherCore

/// UIView whose backing layer is an `AVPlayerLayer` (required for Picture-in-Picture and AirPlay video).
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

@MainActor
final class AVPlayerEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .avPlayer

    private(set) var snapshot = EngineSnapshot() {
        didSet { if snapshot != oldValue { onSnapshot?(snapshot) } }
    }
    var onSnapshot: ((EngineSnapshot) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((PlaybackFailure) -> Void)?
    var onTracksChanged: (() -> Void)?
    private(set) var mediaInfo: MediaFormatInfo?
    var onMediaInfo: ((MediaFormatInfo) -> Void)?

    private let view = PlayerLayerView()
    var videoView: UIView { view }

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var cancellables = Set<AnyCancellable>()
    private var itemCancellables = Set<AnyCancellable>()
    private var timeObserver: Any?
    private var pip: AVPictureInPictureController?
    /// The controller is made once the audio session is active (see `load`); asking earlier gives "not possible".
    private var pipAttempted = false
    /// The system has begun moving the picture into the floating window but has not finished: it must not be detached now.
    private var pipStarting = false
    private var wantsAutoPictureInPicture = true
    private var pipPossibleCancellable: AnyCancellable?
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var pendingStart: Double?
    private var autoplay = true
    private var desiredRate: Float = 1
    private let bufferSeconds: Int
    private var containerExtension: String?

    /// - Parameter bufferSeconds: forward buffer target; 0 lets AVFoundation decide.
    init(bufferSeconds: Int = 0) {
        self.bufferSeconds = bufferSeconds
        super.init()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.automaticallyWaitsToMinimizeStalling = true
        view.playerLayer.player = player

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPlaybackFlags() }
            .store(in: &cancellables)
        player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.snapshot.isExternalPlaybackActive = active }
            .store(in: &cancellables)
        player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in if rate > 0 { self?.snapshot.rate = rate } }
            .store(in: &cancellables)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.timeTick(time) }
        }

    }

    /// Creates the Picture in Picture controller on first use. It is done when a file is loaded, not in `init`: the audio session
    /// category `.playback` has to be in place first or the system keeps answering "not possible".
    private func ensurePictureInPictureController() {
        guard !pipAttempted else { return }
        pipAttempted = true
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: view.playerLayer) else { return }
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = wantsAutoPictureInPicture
        pip = controller
        snapshot.isPictureInPicturePossible = controller.isPictureInPicturePossible
        pipPossibleCancellable = controller.publisher(for: \.isPictureInPicturePossible)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] possible in self?.snapshot.isPictureInPicturePossible = possible }
    }

    deinit {
        if let observer = timeObserver { player.removeTimeObserver(observer) }
    }

    // MARK: Loading

    func load(url: URL, headers: [String: String], startAt: Double?, autoplay: Bool) {
        ensurePictureInPictureController()
        teardownItem()
        self.autoplay = autoplay
        pendingStart = (startAt ?? 0) > 1 ? startAt : nil
        var options: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        if !headers.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = headers
        }
        let asset = AVURLAsset(url: url, options: options)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = TimeInterval(bufferSeconds)
        containerExtension = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
        mediaInfo = nil
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        item = newItem
        var fresh = EngineSnapshot(rate: desiredRate)
        fresh.isPictureInPictureActive = snapshot.isPictureInPictureActive
        fresh.isPictureInPicturePossible = snapshot.isPictureInPicturePossible
        snapshot = fresh
        observe(newItem)
        player.replaceCurrentItem(with: newItem)
        if autoplay { player.playImmediately(atRate: desiredRate) }
        Task { await loadTracks(for: asset) }
    }

    private func observe(_ item: AVPlayerItem) {
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.itemStatusChanged(status) }
            .store(in: &itemCancellables)
        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPlaybackFlags() }
            .store(in: &itemCancellables)
        item.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPlaybackFlags() }
            .store(in: &itemCancellables)
        item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in self?.snapshot.videoSize = size }
            .store(in: &itemCancellables)
        item.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in self?.durationChanged(duration) }
            .store(in: &itemCancellables)
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onEnded?() }
            .store(in: &itemCancellables)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                if let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError { self?.report(error) }
            }
            .store(in: &itemCancellables)
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: item)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.snapshot.isBuffering = true }
            .store(in: &itemCancellables)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            snapshot.isReady = true
            if let start = pendingStart {
                pendingStart = nil
                seek(to: start, precise: true)
            }
            if autoplay && player.timeControlStatus == .paused { player.playImmediately(atRate: desiredRate) }
            refreshPlaybackFlags()
        case .failed:
            if let error = item?.error as NSError? { report(error) }
        default:
            break
        }
    }

    private func durationChanged(_ time: CMTime) {
        if time.isIndefinite {
            snapshot.isLive = true
            snapshot.duration = 0
        } else if time.isNumeric {
            snapshot.isLive = false
            snapshot.duration = max(0, time.seconds)
        }
    }

    private func report(_ error: NSError) {
        var underlying: [(domain: String, code: Int)] = []
        var current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        var guardCount = 0
        while let inner = current, guardCount < 4 {
            underlying.append((domain: inner.domain, code: inner.code))
            current = inner.userInfo[NSUnderlyingErrorKey] as? NSError
            guardCount += 1
        }
        let failure = PlaybackErrorMapper.map(domain: error.domain, code: error.code,
                                              description: error.localizedDescription, underlying: underlying)
        onFailure?(failure)
    }

    private func refreshPlaybackFlags() {
        let playing = player.timeControlStatus == .playing
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let emptyBuffer = item?.isPlaybackBufferEmpty ?? false
        snapshot.isPlaying = playing || (waiting && (autoplay || snapshot.isPlaying))
        snapshot.isBuffering = waiting || (emptyBuffer && !(item?.isPlaybackLikelyToKeepUp ?? true))
    }

    private func timeTick(_ time: CMTime) {
        guard time.isNumeric else { return }
        snapshot.position = max(0, time.seconds)
        if let range = item?.loadedTimeRanges.first?.timeRangeValue {
            snapshot.bufferedPosition = range.end.seconds.isFinite ? range.end.seconds : 0
        }
    }

    // MARK: Transport

    func currentTime() -> Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : snapshot.position
    }

    func play() {
        autoplay = true
        player.playImmediately(atRate: desiredRate)
        // The system reports the new state a moment later; until then the button must not still say "play" (a second tap
        // would then start nothing), as the MPV engine already does.
        if item != nil { snapshot.isPlaying = true }
    }

    func pause() {
        autoplay = false
        player.pause()
        snapshot.isPlaying = false
    }

    func seek(to seconds: Double, precise: Bool) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 1, preferredTimescale: 600)
        snapshot.position = max(0, seconds)
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlaybackFlags() }
        }
    }

    func seek(by delta: Double) {
        let current = player.currentTime().seconds
        var target = (current.isFinite ? current : snapshot.position) + delta
        if snapshot.duration > 0 { target = min(target, snapshot.duration - 0.5) }
        seek(to: max(0, target), precise: true)
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        snapshot.rate = rate
        if player.timeControlStatus != .paused { player.rate = rate }
    }

    func setFillScreen(_ fill: Bool) {
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    // MARK: Tracks

    private func loadTracks(for asset: AVAsset) async {
        let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard item?.asset === asset else { return }
        audioGroup = audio
        legibleGroup = legible
        onTracksChanged?()
        let facts = await MediaProbe.facts(for: asset, container: containerExtension,
                                           subtitleTrackCount: legible?.options.count ?? 0)
        guard item?.asset === asset else { return }
        mediaInfo = facts
        onMediaInfo?(facts)
    }

    private func tracks(in group: AVMediaSelectionGroup?) -> [EngineTrack] {
        guard let group = group, let item = item else { return [] }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        return group.options.enumerated().map { index, option in
            EngineTrack(id: "\(index)", title: option.displayName,
                        language: option.extendedLanguageTag ?? option.locale?.identifier,
                        isSelected: option == selected)
        }
    }

    func audioTracks() -> [EngineTrack] { tracks(in: audioGroup) }

    func embeddedSubtitleTracks() -> [EngineTrack] {
        // Hide forced/auto "Off" style entries that are not real tracks.
        return tracks(in: legibleGroup)
    }

    func selectAudio(id: String?) {
        guard let group = audioGroup, let item = item else { return }
        if let id = id, let index = Int(id), group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        }
        onTracksChanged?()
    }

    func selectEmbeddedSubtitle(id: String?) {
        guard let group = legibleGroup, let item = item else { return }
        if let id = id, let index = Int(id), group.options.indices.contains(index) {
            item.select(group.options[index], in: group)
        } else {
            item.select(nil, in: group)
        }
        onTracksChanged?()
    }

    // MARK: Picture in Picture / background

    /// What the engine can do in principle on this device; `pictureInPictureAvailability` says whether it can right now.
    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    var pictureInPictureAvailability: PictureInPictureAvailability {
        return PictureInPictureAvailability.evaluate(engine: .avPlayer,
                                                     deviceSupportsPictureInPicture: AVPictureInPictureController.isPictureInPictureSupported(),
                                                     controllerExists: pip != nil || !pipAttempted,
                                                     isPossible: pip?.isPictureInPicturePossible ?? false,
                                                     fileIsReady: snapshot.isReady)
    }

    func startPictureInPicture() {
        ensurePictureInPictureController()
        guard let pip = pip, pip.isPictureInPicturePossible else { return }
        snapshot.pictureInPictureFailure = nil
        view.playerLayer.player = player
        pip.startPictureInPicture()
    }

    func stopPictureInPicture() {
        pip?.stopPictureInPicture()
    }

    func setAutoPictureInPicture(_ enabled: Bool) {
        wantsAutoPictureInPicture = enabled
        pip?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func setVideoDetached(_ detached: Bool) {
        if detached {
            // Not while Picture in Picture is on or on its way: the controller's own flag is checked as well, because the
            // snapshot is updated one hop later than the delegate callback.
            if snapshot.isPictureInPictureActive || pipStarting || pip?.isPictureInPictureActive == true { return }
            view.playerLayer.player = nil
        } else {
            view.playerLayer.player = player
        }
    }

    // MARK: Teardown

    private func teardownItem() {
        itemCancellables.removeAll()
        audioGroup = nil
        legibleGroup = nil
        player.replaceCurrentItem(with: nil)
        item = nil
    }

    func teardown() {
        pipPossibleCancellable = nil
        pip?.stopPictureInPicture()
        player.pause()
        teardownItem()
        cancellables.removeAll()
        onSnapshot = nil
        onEnded = nil
        onFailure = nil
        onTracksChanged = nil
        onMediaInfo = nil
    }
}

extension AVPlayerEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.pipStarting = true }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipStarting = false
            self.snapshot.isPictureInPictureActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.pipStarting = false
            self.snapshot.isPictureInPictureActive = false
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        let message = (error as NSError).localizedDescription
        Task { @MainActor in
            self.pipStarting = false
            self.snapshot.pictureInPictureFailure = message
            // The app already left the screen while the window was starting: fall back to sound only (the view model resumes
            // the sound if the system paused it).
            if UIApplication.shared.applicationState == .background { self.view.playerLayer.player = nil }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The player screen stays presented underneath, so there is nothing to rebuild.
        completionHandler(true)
    }
}
