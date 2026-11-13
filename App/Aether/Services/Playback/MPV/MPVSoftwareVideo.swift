#if canImport(Libmpv)
import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import Libmpv
import UIKit

// EXPERIMENTAL — Picture in Picture for the MPV engine.
//
// MPV normally draws with the GPU into a Metal layer, which the system cannot float in a small window and which stops when the app goes to the
// background. This path asks libmpv for its *software* renderer instead: each frame is drawn into a pixel buffer and handed to an
// `AVSampleBufferDisplayLayer`, the only kind of layer the system accepts for a floating window of something that is not an AVPlayer. The price:
// the picture is drawn by the CPU (scaled down to at most 1280 pixels wide) and there is no HDR or Dolby Vision. It is off by default
// (Impostazioni ▸ Riproduzione) and, if the renderer cannot be created, MPV goes back to its normal output by itself.

/// The view that holds the sample-buffer layer.
final class MPVSoftwareVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// «Riempi»: the picture covers the screen (cropping the edges) instead of fitting inside it.
    func setFill(_ fill: Bool) {
        displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

/// Draws the frames of one libmpv instance in software and enqueues them on a display layer.
final class MPVSoftwareRenderer: @unchecked Sendable {
    private var context: OpaquePointer?
    private let queue = DispatchQueue(label: "app.aether.mpv.softrender", qos: .userInitiated)
    private let layer: AVSampleBufferDisplayLayer
    private let sourceSize: @Sendable () -> (Int, Int)
    private var stopped = false
    private let lock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    init(layer: AVSampleBufferDisplayLayer, context: OpaquePointer, sourceSize: @escaping @Sendable () -> (Int, Int)) {
        self.layer = layer
        self.context = context
        self.sourceSize = sourceSize
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        mpv_render_context_set_update_callback(context, { raw in
            guard let raw = raw else { return }
            let renderer = Unmanaged<MPVSoftwareRenderer>.fromOpaque(raw).takeUnretainedValue()
            renderer.queue.async { renderer.renderIfNeeded() }
        }, pointer)
    }

    /// Frees the render context. It has to happen before the libmpv instance is destroyed.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        queue.sync {
            if let context = context {
                mpv_render_context_set_update_callback(context, nil, nil)
                mpv_render_context_free(context)
            }
            context = nil
        }
        layer.flushAndRemoveImage()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func renderIfNeeded() {
        guard !isStopped, let context = context else { return }
        let flags = mpv_render_context_update(context)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        var (width, height) = sourceSize()
        if width < 16 || height < 16 { width = 1280; height = 720 }
        if width > 1280 {
            height = Int(Double(height) * 1280.0 / Double(width))
            width = 1280
        }
        width &= ~1
        height &= ~1
        guard let buffer = makeBuffer(width: width, height: height) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        var size: [Int32] = [Int32(width), Int32(height)]
        var stride = Int(CVPixelBufferGetBytesPerRow(buffer))
        let base = CVPixelBufferGetBaseAddress(buffer)
        size.withUnsafeMutableBufferPointer { sizePointer in
            "bgr0".withCString { format in
                withUnsafeMutablePointer(to: &stride) { stridePointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizePointer.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = mpv_render_context_render(context, &params)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        enqueue(buffer)
    }

    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = (width, height)
        }
        guard let pool = pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format = format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample = sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if layer.status == .failed { layer.flush() }
        if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
    }
}

/// Answers the system for the floating window: play, pause, skips, and when it opens or closes.
final class MPVPiPDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate, @unchecked Sendable {
    var setPlaying: @Sendable (Bool) -> Void = { _ in }
    var skip: @Sendable (Double) -> Void = { _ in }
    var isPaused: @Sendable () -> Bool = { false }
    var duration: @Sendable () -> Double = { 0 }
    var onActiveChanged: @Sendable (Bool) -> Void = { _ in }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) { setPlaying(playing) }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        let seconds = duration()
        return CMTimeRange(start: .zero, duration: CMTime(seconds: seconds > 0 ? seconds : 36000, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { isPaused() }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        skip(CMTimeGetSeconds(skipInterval))
        completionHandler()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { onActiveChanged(true) }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { onActiveChanged(false) }
}

/// The floating window (Picture in Picture) of the software picture.
final class MPVPictureInPicture: @unchecked Sendable {
    let controller: AVPictureInPictureController
    let delegate: MPVPiPDelegate
    var onPossibleChanged: (@Sendable (Bool) -> Void)?
    private var possibleObservation: NSKeyValueObservation?

    init?(layer: AVSampleBufferDisplayLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase = timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        let playbackDelegate = MPVPiPDelegate()
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: playbackDelegate)
        let made = AVPictureInPictureController(contentSource: source)
        made.delegate = playbackDelegate
        made.canStartPictureInPictureAutomaticallyFromInline = true
        controller = made
        delegate = playbackDelegate
        possibleObservation = made.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, change in
            self?.onPossibleChanged?(change.newValue ?? false)
        }
    }
}

extension MPVCore {
    /// A software render context on this instance, or nil if libmpv refuses (the build has no render API, or the options did not fit).
    func makeSoftwareRenderContext() -> OpaquePointer? {
        guard let handle = rawHandle else { return nil }
        var created: OpaquePointer?
        let status = "sw".withCString { api -> Int32 in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            return mpv_render_context_create(&created, handle, &params)
        }
        return status >= 0 ? created : nil
    }
}
#endif
