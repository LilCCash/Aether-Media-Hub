#if canImport(Libmpv)
import UIKit
import QuartzCore
import AVFoundation
import AVKit
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
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
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

    /// The libmpv handle for the render API (nil once the instance has been destroyed).
    var rawHandle: OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return destroyed ? nil : handle
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

    /// mpv's own counters (its client API can be read from any thread).
    func liveStats() -> PlaybackLiveStats? {
        guard let core = core else { return nil }
        var stats = PlaybackLiveStats()
        stats.videoBitrate = core.double("video-bitrate")
        stats.audioBitrate = core.double("audio-bitrate")
        stats.displayedFrameRate = core.double("estimated-display-fps") ?? core.double("estimated-vf-fps")
        let dropped = (core.int("frame-drop-count") ?? 0) + (core.int("decoder-frame-drop-count") ?? 0)
        stats.droppedFrames = Int(dropped)
        if let hwdec = core.string("hwdec-current"), !hwdec.isEmpty, hwdec != "no" {
            stats.decoder = "Hardware (\(hwdec))"
        } else {
            stats.decoder = "Software"
        }
        stats.bufferedSeconds = core.double("demuxer-cache-duration")
        return stats
    }
    private var surface: MPVSurfaceView?
    /// Set before `load` for a live channel: mpv then probes the stream briefly instead of reading megabytes before the first picture.
    private var liveStream = false
    // Experimental Picture in Picture (software picture): see MPVSoftwareVideo.swift.
    private var softwareView: MPVSoftwareVideoView?
    private var softwareRenderer: MPVSoftwareRenderer?
    private var pictureInPicture: MPVPictureInPicture?
    private var softwareUnavailable = false
    private var pictureInPictureActive = false
    private var pictureInPicturePossible = false
    private var usesSoftwareVideo: Bool { return settings.mpvPictureInPicture && !headlessVideo && !softwareUnavailable && !hdrNeedsGPU && AVPictureInPictureController.isPictureInPictureSupported() }
    /// The software picture (used for the experimental Picture in Picture) cannot convert HDR or Dolby Vision: an HDR file reopens on
    /// the normal output, which converts it to the screen. Without this the picture came out dark and orange (PQ shown as if it were SDR).
    private var hdrNeedsGPU = false
    private var lastLoad: (url: URL, headers: [String: String])?
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
        if lastLoad?.url != url { hdrNeedsGPU = false }
        lastLoad = (url, headers)
        self.autoplay = autoplay
        didEnd = false
        isLoaded = false
        videoOutputActive = nil
        recentLog.removeAll()
        mediaInfo = nil
        snapshot = EngineSnapshot(rate: desiredRate)

        let software = usesSoftwareVideo
        let surface = MPVSurfaceView(frame: container.bounds)
        if software {
            let view = MPVSoftwareVideoView(frame: container.bounds)
            container.attach(view)
            softwareView = view
        } else {
            container.attach(surface)
            surface.layoutIfNeeded()
            // Starts in plain SDR: the wide range is switched on only once the file proves to be HDR (see `video-params`). Leaving it on
            // for ordinary pictures made their colours come out wrong on HDR screens.
            surface.metalLayer.wantsExtendedDynamicRangeContent = false
            self.surface = surface
        }

        guard let core = MPVCore() else {
            onFailure?(PlaybackFailure(kind: .unknown, detail: "Impossibile creare il motore MPV."))
            return
        }
        if !software { core.setWindow(surface.metalLayer) }
        for pair in MPVOptions.initialOptions(video: settings.video, device: device, headlessVideo: headlessVideo) {
            core.setOption(pair.name, pair.value)
        }
        if software {
            // The software renderer draws through libmpv's own output, not through a Metal layer.
            core.setOption("vo", "libmpv")
            core.setOption("hwdec", settings.video.hardwareDecoding ? "videotoolbox-copy" : "no")
        }
        if liveStream {
            core.setOption("demuxer-lavf-probesize", "500000")
            core.setOption("demuxer-lavf-analyzeduration", "1.5")
            core.setOption("cache-pause-initial", "no")
            core.setOption("cache-pause-wait", "0.5")
        }
        if !software {
            // The picture is always converted to what the screen layer is: sRGB / BT.709. Left to detect it, the renderer could take the
            // layer for a wide-gamut HDR surface and send BT.2020 colours into it (reds turn orange and pale).
            core.setOption("target-colorspace-hint", "no")
            core.setOption("target-prim", "bt.709")
            core.setOption("target-trc", "srgb")
            core.setOption("icc-profile-auto", "no")
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
        if software {
            guard let view = softwareView, let context = core.makeSoftwareRenderContext() else {
                // This build of libmpv cannot render in software: back to the normal output, once, and remember it.
                softwareUnavailable = true
                recentLog.append("PiP MPV: il renderer software non è disponibile, uso l'uscita normale.")
                destroyCore()
                load(url: url, headers: headers, startAt: startAt, autoplay: autoplay)
                return
            }
            softwareRenderer = MPVSoftwareRenderer(layer: view.displayLayer, context: context, sourceSize: { [weak core] in
                (Int(core?.int("dwidth") ?? 0), Int(core?.int("dheight") ?? 0))
            })
            setUpPictureInPicture(layer: view.displayLayer)
        }
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
            matchOutputToPicture()
            publishMediaInfo()
        default:
            break
        }
    }

    /// HDR output only for a picture that is really HDR (PQ or HLG) on a screen that shows it; every other picture is drawn as plain SDR.
    private func matchOutputToPicture() {
        if softwareView != nil, let core = core, !hdrNeedsGPU {
            let transfer = (core.string("video-params/gamma") ?? "").lowercased()
            let matrix = (core.string("video-params/colormatrix") ?? "").lowercased()
            if transfer.contains("pq") || transfer.contains("hlg") || matrix.contains("dolby") {
                hdrNeedsGPU = true
                recentLog.append("Immagine HDR (\(transfer), \(matrix)): riapro con l'uscita normale, che la converte per lo schermo (niente PiP per questo file).")
                if let last = lastLoad {
                    let position = core.double("time-pos") ?? 0
                    let wasPlaying = !(core.flag("pause") ?? false)
                    destroyCore()
                    load(url: last.url, headers: last.headers, startAt: position > 1 ? position : nil, autoplay: wasPlaying)
                }
                return
            }
        }
        guard let core = core, let surface = surface else { return }
        let transfer = (core.string("video-params/gamma") ?? "").lowercased()
        let isHDR = transfer.contains("pq") || transfer.contains("hlg")
        // Always SDR output: mpv tone-maps HDR files to the screen. Passing PQ/HLG through to an 8-bit layer (the swapchain made before
        // the file was known) showed HDR pictures washed out and shifted (red logos came out orange).
        let wide = false
        if surface.metalLayer.wantsExtendedDynamicRangeContent != wide {
            surface.metalLayer.wantsExtendedDynamicRangeContent = wide
        }
        _ = core.setProperty("target-colorspace-hint", wide ? "yes" : "no")
        _ = core.setProperty("target-prim", "bt.709")
        _ = core.setProperty("target-trc", "srgb")
        recentLog.append("Immagine: trasferimento \(transfer.isEmpty ? "?" : transfer), primari \(core.string("video-params/primaries") ?? "?"), matrice \(core.string("video-params/colormatrix") ?? "?"), decoder \(core.string("hwdec-current") ?? "?"), file HDR \(isHDR ? "sì" : "no"), HDR in uscita \(wide ? "sì" : "no"), destinazione \(core.string("target-prim") ?? "?")/\(core.string("target-trc") ?? "?"), picco \(core.string("video-params/sig-peak") ?? "?")")
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

    var supportsPictureInPicture: Bool { return pictureInPicture != nil }
    var pictureInPictureAvailability: PictureInPictureAvailability {
        guard pictureInPicture != nil else { return .engineUnsupported(engine: kind.displayName) }
        return pictureInPicturePossible ? .available : .notReadyYet
    }

    func startPictureInPicture() {
        guard let pip = pictureInPicture, pip.controller.isPictureInPicturePossible else { return }
        pip.controller.startPictureInPicture()
    }

    func stopPictureInPicture() { pictureInPicture?.controller.stopPictureInPicture() }

    func setAutoPictureInPicture(_ enabled: Bool) { pictureInPicture?.controller.canStartPictureInPictureAutomaticallyFromInline = enabled }

    private func setUpPictureInPicture(layer: AVSampleBufferDisplayLayer) {
        guard let pip = MPVPictureInPicture(layer: layer) else { return }
        let core = self.core
        pip.delegate.setPlaying = { [weak self] playing in
            DispatchQueue.main.async { MainActor.assumeIsolated { if playing { self?.play() } else { self?.pause() } } }
        }
        pip.delegate.skip = { [weak self] seconds in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.seek(by: seconds) } }
        }
        pip.delegate.isPaused = { [weak core] in core?.flag("pause") ?? false }
        pip.delegate.duration = { [weak core] in core?.double("duration") ?? 0 }
        pip.delegate.onActiveChanged = { [weak self] active in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.pictureInPictureActive = active
                self?.snapshot.isPictureInPictureActive = active
                self?.applyVideoDetached()
            } }
        }
        pip.onPossibleChanged = { [weak self] possible in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.pictureInPicturePossible = possible
                self?.snapshot.isPictureInPicturePossible = possible
            } }
        }
        pictureInPicture = pip
        pictureInPicturePossible = pip.controller.isPictureInPicturePossible
        snapshot.isPictureInPicturePossible = pictureInPicturePossible
    }

    func setVideoDetached(_ detached: Bool) {
        videoDetached = detached
        applyVideoDetached()
    }

    /// Metal work is not allowed while the app is in the background: stop decoding/drawing video, keep the sound.
    private func applyVideoDetached() {
        // With the software picture the window keeps drawing in the background while it is open; without it, the picture stops and only the sound goes on.
        let detach = videoDetached && !(softwareRenderer != nil && pictureInPictureActive)
        core?.setProperty("vid", detach ? "no" : "auto")
    }

    // MARK: Teardown

    private func destroyCore() {
        positionTimer?.invalidate()
        positionTimer = nil
        // The render context goes first: libmpv cannot be destroyed while one is still attached to it.
        softwareRenderer?.stop()
        softwareRenderer = nil
        pictureInPicture?.controller.stopPictureInPicture()
        pictureInPicture = nil
        pictureInPictureActive = false
        pictureInPicturePossible = false
        if let core = core {
            let layerKeepAlive = surface
            let viewKeepAlive = softwareView
            core.shutdown { DispatchQueue.main.async { _ = layerKeepAlive; _ = viewKeepAlive } }
        }
        core = nil
        surface = nil
        softwareView = nil
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

// MARK: - Self test

/// Creates a throw-away libmpv instance with null outputs and reads what the linked libraries report. Used by the unit
/// tests (and the "Stato dei player" page could use it): it proves that libmpv really is in the app and works.
struct MPVSelfTestResult: Equatable {
    var initStatus: Int32
    var mpvVersion: String?
    var ffmpegVersion: String?
    var decoders: String
    var demuxers: String
}

enum MPVSelfTest {
    static func run() -> MPVSelfTestResult? {
        guard let core = MPVCore() else { return nil }
        for (name, value) in [("config", "no"), ("terminal", "no"), ("idle", "yes"), ("vo", "null"), ("ao", "null"),
                              ("load-scripts", "no"), ("ytdl", "no"), ("osc", "no")] {
            core.setOption(name, value)
        }
        let status = core.initialize()
        var result = MPVSelfTestResult(initStatus: status, mpvVersion: nil, ffmpegVersion: nil, decoders: "", demuxers: "")
        if status >= 0 {
            result.mpvVersion = core.string("mpv-version")
            result.ffmpegVersion = core.string("ffmpeg-version")
            result.decoders = core.string("decoder-list") ?? ""
            result.demuxers = core.string("demuxer-lavf-list") ?? ""
        }
        core.shutdown()
        return result
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
extension MPVEngine: LiveStreamHinting {
    func setLiveStream(_ live: Bool) { liveStream = live }
}
#endif
