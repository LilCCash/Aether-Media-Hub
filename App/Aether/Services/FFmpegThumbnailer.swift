import Foundation
import UIKit

#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil) && canImport(Libswscale)
import Libavformat
import Libavcodec
import Libavutil
import Libswscale

/// The little pictures of the progress bar for ANY file and ANY player: the frame is cut from the original source (the same address the player
/// reads, never the local conversion) with the FFmpeg that ships inside MPVKit, so MKV, AVI, TS, WebM, HLS and MP4 are all the same to it, whether the
/// picture is then played by AVPlayer or by MPV. Only key frames are decoded (a keyframe near the asked time is enough and much faster).
/// One instance per source: it keeps the file open, answers one request at a time and drops the ones that have been overtaken by a newer one.
final class FFmpegThumbnailer: @unchecked Sendable {
    static let isAvailable = true

    private let address: String
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "app.aether.thumbnails", qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var decoder: UnsafeMutablePointer<AVCodecContext>?
    private var scaler: OpaquePointer?
    private var scalerKey = ""
    private var videoIndex: Int32 = -1
    private var timeBase = AVRational(num: 1, den: 1000)
    private var startTime: Int64 = 0
    private var attempted = false
    private var usable = false

    init(url: URL, headers: [String: String]) {
        self.address = url.isFileURL ? url.path : url.absoluteString
        self.headers = headers
    }

    deinit { closeEverything() }

    /// Stops working on what was asked before (the finger has moved on) and frees the file.
    func close() {
        lock.lock()
        generation += 1
        lock.unlock()
        queue.async { [self] in closeEverything() }
    }

    func image(at seconds: Double, maxWidth: Int = 320) async -> UIImage? {
        lock.lock()
        generation += 1
        let token = generation
        lock.unlock()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            queue.async { [self] in
                if isStale(token) { continuation.resume(returning: nil); return }
                continuation.resume(returning: render(seconds: max(0, seconds), maxWidth: maxWidth, token: token))
            }
        }
    }

    private func isStale(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != generation
    }

    // MARK: Opening

    private func openIfNeeded() -> Bool {
        if attempted { return usable }
        attempted = true
        var options: UnsafeMutablePointer<AVDictionary>?
        defer { av_dict_free(&options) }
        if !headers.isEmpty {
            let joined = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
            av_dict_set(&options, "headers", joined, 0)
        }
        av_dict_set(&options, "user_agent", "Aether", 0)
        av_dict_set(&options, "rw_timeout", "12000000", 0)
        av_dict_set(&options, "probesize", "3000000", 0)
        av_dict_set(&options, "analyzeduration", "2000000", 0)
        var opened: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&opened, address, nil, &options) >= 0, let ic = opened else { return false }
        context = ic
        guard avformat_find_stream_info(ic, nil) >= 0 else { closeEverything(); return false }
        var chosen: Int32 = -1
        for index in 0..<Int(ic.pointee.nb_streams) {
            guard let stream = ic.pointee.streams[index], let parameters = stream.pointee.codecpar else { continue }
            if parameters.pointee.codec_type == AVMEDIA_TYPE_VIDEO && (stream.pointee.disposition & 0x0400) == 0 {   // not an attached cover picture
                chosen = Int32(index)
                break
            }
        }
        guard chosen >= 0, let stream = ic.pointee.streams[Int(chosen)], let parameters = stream.pointee.codecpar,
              let codec = avcodec_find_decoder(parameters.pointee.codec_id), let codecContext = avcodec_alloc_context3(codec) else { closeEverything(); return false }
        guard avcodec_parameters_to_context(codecContext, parameters) >= 0 else {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = codecContext
            avcodec_free_context(&doomed)
            closeEverything()
            return false
        }
        codecContext.pointee.thread_count = 2
        codecContext.pointee.skip_frame = AVDISCARD_NONKEY
        codecContext.pointee.skip_loop_filter = AVDISCARD_ALL
        guard avcodec_open2(codecContext, codec, nil) >= 0 else {
            var doomed: UnsafeMutablePointer<AVCodecContext>? = codecContext
            avcodec_free_context(&doomed)
            closeEverything()
            return false
        }
        decoder = codecContext
        videoIndex = chosen
        timeBase = stream.pointee.time_base
        startTime = stream.pointee.start_time == Int64.min ? 0 : stream.pointee.start_time
        usable = true
        return true
    }

    private func closeEverything() {
        if let scaler = scaler { sws_freeContext(scaler) }
        scaler = nil
        scalerKey = ""
        if decoder != nil { avcodec_free_context(&decoder) }
        decoder = nil
        if context != nil { avformat_close_input(&context) }
        context = nil
        usable = false
    }

    // MARK: One picture

    private func render(seconds: Double, maxWidth: Int, token: Int) -> UIImage? {
        guard openIfNeeded(), let ic = context, let codec = decoder else { return nil }
        let numerator = Double(timeBase.num == 0 ? 1 : timeBase.num)
        let target = startTime + Int64(seconds * Double(timeBase.den) / numerator)
        if av_seek_frame(ic, videoIndex, target, 1) < 0 { return nil }   // 1 = backward: the key frame at or before the time
        avcodec_flush_buffers(codec)

        var scratchPacket = av_packet_alloc()
        defer { av_packet_free(&scratchPacket) }
        var scratchFrame = av_frame_alloc()
        defer { av_frame_free(&scratchFrame) }
        guard let packet = scratchPacket, let frame = scratchFrame else { return nil }

        var read = 0
        var decoded = false
        while read < 400 {
            if isStale(token) { return nil }
            let status = av_read_frame(ic, packet)
            if status < 0 { break }
            read += 1
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == videoIndex else { continue }
            if avcodec_send_packet(codec, packet) < 0 { continue }
            if avcodec_receive_frame(codec, frame) >= 0 { decoded = true; break }
        }
        guard decoded, frame.pointee.width > 0, frame.pointee.height > 0 else { return nil }
        return picture(from: frame, maxWidth: maxWidth)
    }

    private func picture(from frame: UnsafeMutablePointer<AVFrame>, maxWidth: Int) -> UIImage? {
        let sourceWidth = Int(frame.pointee.width)
        let sourceHeight = Int(frame.pointee.height)
        let width = min(maxWidth, sourceWidth) & ~1
        let height = max(2, (Int(Double(sourceHeight) * Double(width) / Double(sourceWidth))) & ~1)
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let key = "\(sourceWidth)x\(sourceHeight)-\(frame.pointee.format)-\(width)x\(height)"
        if key != scalerKey {
            if let old = scaler { sws_freeContext(old) }
            scaler = sws_getContext(Int32(sourceWidth), Int32(sourceHeight), format, Int32(width), Int32(height), AV_PIX_FMT_RGBA, 2, nil, nil, nil)   // 2 = bilinear
            scalerKey = key
        }
        guard let scaler = scaler else { return nil }
        var scratchTarget = av_frame_alloc()
        defer { av_frame_free(&scratchTarget) }
        guard let target = scratchTarget else { return nil }
        target.pointee.format = AV_PIX_FMT_RGBA.rawValue
        target.pointee.width = Int32(width)
        target.pointee.height = Int32(height)
        guard av_frame_get_buffer(target, 0) >= 0 else { return nil }
        guard sws_scale_frame(scaler, target, frame) >= 0 else { return nil }
        guard let base = target.pointee.data.0,
              let bitmap = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: Int(target.pointee.linesize.0),
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = bitmap.makeImage() else { return nil }
        return UIImage(cgImage: image)
    }
}
#else
final class FFmpegThumbnailer: @unchecked Sendable {
    static let isAvailable = false
    init(url: URL, headers: [String: String]) {}
    func close() {}
    func image(at seconds: Double, maxWidth: Int = 320) async -> UIImage? { return nil }
}
#endif
