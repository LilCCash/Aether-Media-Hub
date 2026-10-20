#if canImport(Libmpv)
import UIKit
import QuartzCore
import Libmpv
import AetherCore

// MARK: - Drawing surface

/// The layer libmpv renders into (through MoltenVK). Two details matter: MoltenVK sometimes asks for a zero-sized
/// drawable while it builds its swapchain, and it toggles the EDR flag from its own thread.
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { return super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { return super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}

final class MPVSurfaceView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        metalLayer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 1 && size.height > 1 { metalLayer.drawableSize = size }
    }
}

/// Stable view handed to the UI; the surface inside it is replaced for every load so that a new mpv instance never
/// shares a Metal layer with one that is still shutting down.
final class MPVContainerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(_ surface: UIView?) {
        subviews.forEach { $0.removeFromSuperview() }
        guard let surface = surface else { return }
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(surface)
    }
}

// MARK: - libmpv wrapper

enum MPVEvent: Sendable {
    case startFile
    case fileLoaded
    case endFile(reason: Int32, errorCode: Int32)
    case seek
    case playbackRestart
    case videoReconfig
    case audioReconfig
    case propertyChanged(name: String, value: MPVValue)
    case log(level: String, text: String)
    case shutdown
}

enum MPVValue: Sendable {
    case none
    case flag(Bool)
    case int(Int64)
    case double(Double)
    case string(String?)
}

/// One libmpv instance. Everything that touches the handle after `initialize` is thread-safe in libmpv; destruction is
/// serialised with event draining on `queue` so the wakeup callback can never outlive the handle.
final class MPVCore: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let queue = DispatchQueue(label: "app.aether.mpv.core", qos: .userInitiated)
    private let lock = NSLock()
    private var destroyed = false
    private var eventHandler: (@Sendable (MPVEvent) -> Void)?
    /// Called on the core's queue.
    var onEvent: (@Sendable (MPVEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }
        set {
            lock.lock()
            eventHandler = newValue
            lock.unlock()
        }
    }

    init?() {
        guard let created = mpv_create() else { return nil }
        handle = created
    }

    // MARK: Options (before initialize)

    @discardableResult
    func setOption(_ name: String, _ value: String) -> Int32 {
        guard let handle = handle else { return -1 }
        return mpv_set_option_string(handle, name, value)
    }

    @discardableResult
    func setWindow(_ layer: AnyObject) -> Int32 {
        guard let handle = handle else { return -1 }
        var pointer = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        return mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &pointer)
    }

    func initialize() -> Int32 {
        guard let handle = handle else { return -1 }
        let status = mpv_initialize(handle)
        if status < 0 { return status }
        _ = mpv_request_log_messages(handle, "warn")
        let context = Unmanaged.passUnretained(self).toOpaque()
        mpv_set_wakeup_callback(handle, { context in
            guard let context = context else { return }
            let core = Unmanaged<MPVCore>.fromOpaque(context).takeUnretainedValue()
            core.queue.async { core.drainEvents() }
        }, context)
        return status
    }

    // MARK: Observation

    func observe(_ name: String, _ format: mpv_format) {
        guard let handle = handle else { return }
        mpv_observe_property(handle, 0, name, format)
    }

    // MARK: Commands and properties

    @discardableResult
    func command(_ arguments: [String], async: Bool = false) -> Int32 {
        guard let handle = handle else { return -1 }
        let owned: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = owned.map { pointer in pointer.map { UnsafePointer($0) } }
        argv.append(nil)
        if async { return mpv_command_async(handle, 0, &argv) }
        return mpv_command(handle, &argv)
    }

    @discardableResult
    func setProperty(_ name: String, _ value: String) -> Int32 {
        guard let handle = handle else { return -1 }
        return mpv_set_property_string(handle, name, value)
    }

    func string(_ name: String) -> String? {
        guard let handle = handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    func double(_ name: String) -> Double? {
        guard let handle = handle else { return nil }
        var value = 0.0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int(_ name: String) -> Int64? {
        guard let handle = handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    func flag(_ name: String) -> Bool? {
        guard let handle = handle else { return nil }
        var value: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    static func errorText(_ code: Int32) -> String {
        return String(cString: mpv_error_string(code))
    }

    // MARK: Events

    fileprivate func drainEvents() {
        lock.lock()
        let alive = !destroyed
        lock.unlock()
        guard alive, let handle = handle else { return }
        while true {
            guard let event = mpv_wait_event(handle, 0) else { return }
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { return }
            if let mapped = map(event), let handler = onEvent { handler(mapped) }
            if id == MPV_EVENT_SHUTDOWN { return }
        }
    }

    private func map(_ event: UnsafeMutablePointer<mpv_event>) -> MPVEvent? {
        let id = event.pointee.event_id
        switch id {
        case MPV_EVENT_START_FILE: return .startFile
        case MPV_EVENT_FILE_LOADED: return .fileLoaded
        case MPV_EVENT_SEEK: return .seek
        case MPV_EVENT_PLAYBACK_RESTART: return .playbackRestart
        case MPV_EVENT_VIDEO_RECONFIG: return .videoReconfig
        case MPV_EVENT_AUDIO_RECONFIG: return .audioReconfig
        case MPV_EVENT_SHUTDOWN: return .shutdown
        case MPV_EVENT_END_FILE:
            guard let data = event.pointee.data else { return .endFile(reason: -1, errorCode: 0) }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            return .endFile(reason: Int32(end.reason.rawValue), errorCode: end.error)
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.pointee.data else { return nil }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let level = message.level.map { String(cString: $0) } ?? ""
            let text = message.text.map { String(cString: $0) } ?? ""
            return .log(level: level, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.pointee.data else { return nil }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            let name = String(cString: property.name)
            guard let payload = property.data else { return .propertyChanged(name: name, value: .none) }
            switch property.format {
            case MPV_FORMAT_FLAG:
                return .propertyChanged(name: name, value: .flag(payload.assumingMemoryBound(to: Int32.self).pointee != 0))
            case MPV_FORMAT_INT64:
                return .propertyChanged(name: name, value: .int(payload.assumingMemoryBound(to: Int64.self).pointee))
            case MPV_FORMAT_DOUBLE:
                return .propertyChanged(name: name, value: .double(payload.assumingMemoryBound(to: Double.self).pointee))
            case MPV_FORMAT_STRING:
                let pointer = payload.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                return .propertyChanged(name: name, value: .string(pointer.map { String(cString: $0) }))
            default:
                return .propertyChanged(name: name, value: .none)
            }
        default:
            return nil
        }
    }

    // MARK: Destruction

    /// Stops event delivery and destroys the handle on the core's queue (it blocks until mpv's threads are done).
    func shutdown(then completion: (@Sendable () -> Void)? = nil) {
        lock.lock()
        if destroyed {
            lock.unlock()
            return
        }
        destroyed = true
        eventHandler = nil
        lock.unlock()
        queue.async { [self] in
            if let handle = handle {
                mpv_set_wakeup_callback(handle, nil, nil)
                mpv_terminate_destroy(handle)
            }
            handle = nil
            completion?()
        }
    }
}

// MARK: - Engine

@MainActor
final class MPVEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .mpv

    private(set) var snapshot = EngineSnapshot() {
        didSet { if snapshot != oldValue { onSnapshot?(snapshot) } }
    }
    var onSnapshot: ((EngineSnapshot) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: ((PlaybackFailure) -> Void)?
    var onTracksChanged: (() -> Void)?
    var onMediaInfo: ((MediaFormatInfo) -> Void)?
    private(set) var mediaInfo: MediaFormatInfo?

    private let container = MPVContainerView()
    var videoView: UIView { container }

    private let settings: PlaybackSettings
    private let device: DeviceVideoCapabilities
    private let headlessVideo: Bool

    private var core: MPVCore?
    private var surface: MPVSurfaceView?
    private var positionTimer: Timer?
    private var recentLog: [String] = []
    private var desiredRate: Float = 1
    private var fill = false
    private var autoplay = true
    private var didEnd = false
    private var isLoaded = false
    private var videoOutputActive: Bool?
    private var subtitleDelay: Double = 0
    private var videoDetached = false

    init(settings: PlaybackSettings, device: DeviceVideoCapabilities, headlessVideo: Bool = false) {
        self.settings = settings
        self.device = device
        self.headlessVideo = headlessVideo
        super.init()
    }

    deinit {
        positionTimer?.invalidate()
    }

    // MARK: Loading

    func load(url: URL, headers: [String: String], startAt: Double?, autoplay: Bool) {
        destroyCore()
        self.autoplay = autoplay
        didEnd = false
        isLoaded = false
        videoOutputActive = nil
        recentLog.removeAll()
        mediaInfo = nil
        snapshot = EngineSnapshot(rate: desiredRate)

        let surface = MPVSurfaceView(frame: container.bounds)
        container.attach(surface)
        surface.layoutIfNeeded()
        surface.metalLayer.wantsExtendedDynamicRangeContent = MPVOptions.wantsExtendedDynamicRange(video: settings.video, device: device)
        self.surface = surface

        guard let core = MPVCore() else {
            onFailure?(PlaybackFailure(kind: .unknown, detail: "Impossibile creare il motore MPV."))
            return
        }
        core.setWindow(surface.metalLayer)
        for pair in MPVOptions.initialOptions(video: settings.video, device: device, headlessVideo: headlessVideo) {
            core.setOption(pair.name, pair.value)
        }
        for pair in MPVOptions.subtitleStyleProperties(settings.subtitleStyle) { core.setOption(pair.name, pair.value) }
        for pair in MPVOptions.headerOptions(headers) { core.setOption(pair.name, pair.value) }
        if let start = startAt, start > 1 { core.setOption("start", String(format: "%.3f", start)) }
        if !autoplay { core.setOption("pause", "yes") }
        core.setOption("speed", String(format: "%.3f", desiredRate))
        core.setOption("panscan", MPVOptions.panscan(fill: fill))
        core.setOption("sub-delay", String(format: "%.3f", subtitleDelay))
        let audioLanguages = MPVOptions.languagePriorityList([settings.preferredAudioLanguage, settings.secondaryAudioLanguage])
        if !audioLanguages.isEmpty { core.setOption("alang", audioLanguages) }

        core.onEvent = { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        let status = core.initialize()
        if status < 0 {
            let text = MPVCore.errorText(status)
            core.shutdown()
            onFailure?(PlaybackFailure(kind: .unknown, detail: "Avvio del motore MPV non riuscito (\(text))."))
            return
        }
        for (name, format) in [("pause", MPV_FORMAT_FLAG), ("core-idle", MPV_FORMAT_FLAG), ("paused-for-cache", MPV_FORMAT_FLAG),
                               ("seeking", MPV_FORMAT_FLAG), ("eof-reached", MPV_FORMAT_FLAG), ("vo-configured", MPV_FORMAT_FLAG),
                               ("duration", MPV_FORMAT_DOUBLE), ("speed", MPV_FORMAT_DOUBLE),
                               ("dwidth", MPV_FORMAT_INT64), ("dheight", MPV_FORMAT_INT64),
                               ("track-list", MPV_FORMAT_NONE), ("video-params", MPV_FORMAT_NONE)] {
            core.observe(name, format)
        }
        self.core = core
        applyVideoDetached()
        core.command(["loadfile", url.absoluteString, "replace"], async: true)
        startPositionTimer()
    }

    // MARK: Events

    private func handle(_ event: MPVEvent) {
        switch event {
        case .startFile:
            snapshot.isBuffering = true
        case .fileLoaded:
            isLoaded = true
            snapshot.isReady = true
            snapshot.isBuffering = false
            refreshFlags()
            onTracksChanged?()
            publishMediaInfo()
        case .videoReconfig:
            publishMediaInfo()
        case .audioReconfig, .seek, .playbackRestart:
            refreshFlags()
        case .endFile(let reason, let errorCode):
            handleEndFile(reason: reason, errorCode: errorCode)
        case .log(_, let text):
            recentLog.append(text)
            if recentLog.count > 40 { recentLog.removeFirst(recentLog.count - 40) }
        case .shutdown:
            break
        case .propertyChanged(let name, let value):
            propertyChanged(name, value)
        }
    }

    private func propertyChanged(_ name: String, _ value: MPVValue) {
        switch (name, value) {
        case ("pause", .flag), ("core-idle", .flag), ("paused-for-cache", .flag), ("seeking", .flag):
            refreshFlags()
        case ("eof-reached", .flag(let reached)):
            if reached && !didEnd {
                didEnd = true
                snapshot.isPlaying = false
                onEnded?()
            }
        case ("vo-configured", .flag(let active)):
            videoOutputActive = active
            publishMediaInfo()
        case ("duration", .double(let seconds)):
            snapshot.duration = max(0, seconds)
            snapshot.isLive = false
        case ("duration", _):
            snapshot.duration = 0
            snapshot.isLive = isLoaded
        case ("speed", .double(let speed)):
            snapshot.rate = Float(speed)
        case ("dwidth", .int(let width)):
            snapshot.videoSize.width = CGFloat(width)
        case ("dheight", .int(let height)):
            snapshot.videoSize.height = CGFloat(height)
        case ("track-list", _):
            onTracksChanged?()
            publishMediaInfo()
        case ("video-params", _):
            publishMediaInfo()
        default:
            break
        }
    }

    private func refreshFlags() {
        guard let core = core else { return }
        let paused = core.flag("pause") ?? false
        let idle = core.flag("core-idle") ?? false
        let cache = core.flag("paused-for-cache") ?? false
        let seeking = core.flag("seeking") ?? false
        snapshot.isPlaying = !paused && !didEnd
        snapshot.isBuffering = isLoaded ? (cache || seeking || (!paused && idle && !didEnd)) : true
    }

    private func handleEndFile(reason: Int32, errorCode: Int32) {
        // mpv_end_file_reason: 0 eof, 2 stop, 3 quit, 4 error, 5 redirect.
        if reason == 4 {
            let failure = MPVErrorMapper.map(code: errorCode, message: MPVCore.errorText(errorCode), recentLog: recentLog)
            snapshot.isPlaying = false
            snapshot.isBuffering = false
            onFailure?(failure)
        } else if reason == 0, !didEnd {
            didEnd = true
            snapshot.isPlaying = false
            onEnded?()
        }
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let core = core, isLoaded else { return }
        if let position = core.double("time-pos") { snapshot.position = max(0, position) }
        if let cached = core.double("demuxer-cache-time"), cached.isFinite { snapshot.bufferedPosition = max(0, cached) }
    }

    // MARK: Facts

    private func publishMediaInfo() {
        guard let core = core, isLoaded else { return }
        var info = MPVFactsReader.read(core)
        info.videoOutputActive = videoOutputActive
        if info != mediaInfo {
            mediaInfo = info
            onMediaInfo?(info)
        }
    }

    // MARK: Transport

    func currentTime() -> Double {
        return core?.double("time-pos") ?? snapshot.position
    }

    func play() {
        autoplay = true
        core?.setProperty("pause", "no")
        snapshot.isPlaying = !didEnd
    }

    func pause() {
        autoplay = false
        core?.setProperty("pause", "yes")
        snapshot.isPlaying = false
    }

    func seek(to seconds: Double, precise: Bool) {
        let target = max(0, seconds)
        snapshot.position = target
        didEnd = false
        core?.command(["seek", String(format: "%.3f", target), precise ? "absolute+exact" : "absolute"], async: true)
    }

    func seek(by delta: Double) {
        let current = currentTime()
        var target = current + delta
        if snapshot.duration > 0 { target = min(target, snapshot.duration - 0.5) }
        seek(to: max(0, target), precise: true)
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        snapshot.rate = rate
        core?.setProperty("speed", String(format: "%.3f", rate))
    }

    func setFillScreen(_ fill: Bool) {
        self.fill = fill
        core?.setProperty("panscan", MPVOptions.panscan(fill: fill))
    }

    func setEmbeddedSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        core?.setProperty("sub-delay", String(format: "%.3f", seconds))
    }

    // MARK: Tracks

    private func tracks(ofType type: String) -> [EngineTrack] {
        guard let core = core else { return [] }
        let count = Int(core.int("track-list/count") ?? 0)
        var result: [EngineTrack] = []
        for index in 0..<max(0, count) {
            guard core.string("track-list/\(index)/type") == type, let id = core.int("track-list/\(index)/id") else { continue }
            let language = core.string("track-list/\(index)/lang")
            let title = core.string("track-list/\(index)/title")
            let codec = core.string("track-list/\(index)/codec")
            let selected = core.flag("track-list/\(index)/selected") ?? false
            let forced = core.flag("track-list/\(index)/forced") ?? false
            let external = core.flag("track-list/\(index)/external") ?? false
            if type == "sub" && external { continue }
            var parts: [String] = []
            if let language = language, !language.isEmpty {
                parts.append(Locale.current.localizedString(forLanguageCode: language)?.capitalized ?? language.uppercased())
            }
            if let title = title, !title.isEmpty, title.caseInsensitiveCompare(parts.first ?? "") != .orderedSame { parts.append(title) }
            if forced { parts.append("forzati") }
            if parts.isEmpty { parts.append("Traccia \(id)") }
            if let codec = codec, type == "audio" { parts.append(codec.uppercased()) }
            result.append(EngineTrack(id: "\(id)", title: parts.joined(separator: " · "), language: language, isSelected: selected))
        }
        return result
    }

    func audioTracks() -> [EngineTrack] { tracks(ofType: "audio") }
    func embeddedSubtitleTracks() -> [EngineTrack] { tracks(ofType: "sub") }

    func selectAudio(id: String?) {
        core?.setProperty("aid", id ?? "auto")
        onTracksChanged?()
    }

    func selectEmbeddedSubtitle(id: String?) {
        core?.setProperty("sid", id ?? "no")
        onTracksChanged?()
    }

    // MARK: Picture in Picture / background

    var supportsPictureInPicture: Bool { false }
    func startPictureInPicture() {}
    func stopPictureInPicture() {}
    func setAutoPictureInPicture(_ enabled: Bool) {}

    func setVideoDetached(_ detached: Bool) {
        videoDetached = detached
        applyVideoDetached()
    }

    /// Metal work is not allowed while the app is in the background: stop decoding/drawing video, keep the sound.
    private func applyVideoDetached() {
        core?.setProperty("vid", videoDetached ? "no" : "auto")
    }

    // MARK: Teardown

    private func destroyCore() {
        positionTimer?.invalidate()
        positionTimer = nil
        if let core = core {
            let layerKeepAlive = surface
            core.shutdown { DispatchQueue.main.async { _ = layerKeepAlive } }
        }
        core = nil
        surface = nil
    }

    func teardown() {
        destroyCore()
        container.attach(nil)
        onSnapshot = nil
        onEnded = nil
        onFailure = nil
        onTracksChanged = nil
        onMediaInfo = nil
    }
}

// MARK: - Facts from mpv

enum MPVFactsReader {
    /// Everything here is a property mpv reports about the file it opened: nothing is guessed from the name.
    static func read(_ core: MPVCore) -> MediaFormatInfo {
        var video = VideoTrackFacts()
        video.codecName = core.string("video-format") ?? core.string("video-codec")
        video.width = Int(core.int("video-params/w") ?? core.int("width") ?? 0)
        video.height = Int(core.int("video-params/h") ?? core.int("height") ?? 0)
        video.frameRate = core.double("container-fps")
        video.primaries = core.string("video-params/primaries")
        video.transfer = core.string("video-params/gamma")
        video.matrix = core.string("video-params/colormatrix")
        video.peakNits = core.double("video-params/sig-peak").map { $0 * 203 }
        video.range = DynamicRange.classify(primaries: video.primaries, transfer: video.transfer)
        if let format = core.string("video-params/pixelformat") {
            if format.contains("p010") || format.contains("p10") || format.contains("10le") || format.contains("10be") { video.bitDepth = 10 }
            else if format.contains("p012") || format.contains("p12") || format.contains("12le") || format.contains("12be") { video.bitDepth = 12 }
            else { video.bitDepth = 8 }
        }

        var audio: [AudioTrackFacts] = []
        var subtitleCount = 0
        let count = Int(core.int("track-list/count") ?? 0)
        for index in 0..<max(0, count) {
            let type = core.string("track-list/\(index)/type")
            if type == "video", video.dolbyVision == nil, let profile = core.int("track-list/\(index)/dolby-vision-profile"), profile > 0 {
                let level = core.int("track-list/\(index)/dolby-vision-level") ?? 0
                video.dolbyVision = DolbyVisionInfo(profile: Int(profile), level: Int(level), baseLayerCompatibility: baseLayerCompatibility(forProfile: Int(profile), transfer: video.transfer))
            } else if type == "audio" {
                audio.append(AudioTrackFacts(codecName: core.string("track-list/\(index)/codec"),
                                             channels: core.int("track-list/\(index)/demux-channel-count").map { Int($0) },
                                             language: core.string("track-list/\(index)/lang"),
                                             title: core.string("track-list/\(index)/title")))
            } else if type == "sub" {
                subtitleCount += 1
            }
        }
        let hasVideo = (video.codecName != nil) || video.width > 0
        var info = MediaFormatInfo(source: .mpv, container: core.string("file-format"), duration: core.double("duration"),
                                   video: hasVideo ? [video] : [], audio: audio, subtitleTrackCount: subtitleCount,
                                   platformPlayability: .unknown)
        let decoder = core.string("hwdec-current")
        info.hardwareDecoder = (decoder == nil || decoder == "no" || decoder == "") ? "software" : decoder
        return info
    }

    /// mpv reports the profile number only; the base-layer compatibility is inferred from what is certain per profile
    /// (5 has none, 7 is Blu-ray HDR10) and from the transfer function for profile 8.
    static func baseLayerCompatibility(forProfile profile: Int, transfer: String?) -> Int {
        switch profile {
        case 5: return 0
        case 7: return 6
        case 8:
            let key = (transfer ?? "").lowercased()
            if key.isEmpty { return 0 }
            if key.contains("hlg") { return 4 }
            if key.contains("pq") { return 1 }
            return 2
        default: return 0
        }
    }
}
#endif
