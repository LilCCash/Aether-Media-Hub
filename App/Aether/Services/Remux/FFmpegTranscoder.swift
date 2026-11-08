import Foundation
import AetherCore

#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil) && canImport(Libswscale) && canImport(Libswresample)
import Libavformat
import Libavcodec
import Libavutil
import Libswscale
import Libswresample

// The full conversion: what the system player cannot read is decoded by FFmpeg and encoded again, the picture by the phone's hardware
// encoder (VideoToolbox, through FFmpeg's `hevc_videotoolbox` / `h264_videotoolbox`) and the sound as AAC. One segment at a time, so a
// segment can be made for any point of the film (seeking) without the ones before it.

private let tcAgain: Int32 = -35               // AVERROR(EAGAIN) on Apple platforms
private let tcEOF: Int32 = -541478725          // AVERROR_EOF
private let tcGlobalHeader: Int32 = 1 << 22    // AV_CODEC_FLAG_GLOBAL_HEADER
private let tcNoPTS = Int64.min                // AV_NOPTS_VALUE

/// How the picture is encoded again.
struct VideoEncoderSettings {
    var codecName: String
    var isHEVC: Bool
    var pixelFormat: AVPixelFormat
    /// FFmpeg's profile number: H.264 High 100, HEVC Main 1, Main 10 2.
    var profile: Int32
    var width: Int32
    var height: Int32
    var timeBase: AVRational
    var frameRate: AVRational
    var bitRate: Int64
    var gop: Int32
    var colorPrimaries: AVColorPrimaries
    var colorTransfer: AVColorTransferCharacteristic
    var colorSpace: AVColorSpace
    var colorRange: AVColorRange
    var sampleAspect: AVRational
    /// Seconds, for the last picture of a piece.
    var frameDuration: Double

    /// HEVC 10 bit for anything deeper than 8 bit, HDR, or bigger than 1080p; H.264 otherwise (every AirPlay receiver plays it).
    static func choose(for parameters: UnsafeMutablePointer<AVCodecParameters>, stream: UnsafeMutablePointer<AVStream>, bitDepth: Int?) -> VideoEncoderSettings {
        let width = max(2, parameters.pointee.width) & ~1
        let height = max(2, parameters.pointee.height) & ~1
        let trc = parameters.pointee.color_trc
        let hdr = trc == AVCOL_TRC_SMPTE2084 || trc == AVCOL_TRC_ARIB_STD_B67
        let deep = (bitDepth ?? 8) > 8
        let large = width > 1920 || height > 1088
        let hevc = deep || hdr || large
        var rate = stream.pointee.avg_frame_rate
        if !(av_q2d(rate) > 0) { rate = stream.pointee.r_frame_rate }
        if !(av_q2d(rate) > 0) { rate = AVRational(num: 24, den: 1) }
        let fps = max(10.0, min(120.0, av_q2d(rate)))
        // Bits per pixel per frame chosen to look like the source on a big screen: generous, the file is not kept.
        let pixels = Double(width) * Double(height) * fps
        let perPixel = hevc ? 0.09 : 0.14
        let bitRate = Int64(min(hevc ? 40_000_000.0 : 20_000_000.0, max(3_000_000.0, pixels * perPixel)))
        return VideoEncoderSettings(codecName: hevc ? "hevc_videotoolbox" : "h264_videotoolbox",
                                    isHEVC: hevc,
                                    pixelFormat: deep || hdr ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12,
                                    profile: hevc ? (deep || hdr ? 2 : 1) : 100,
                                    width: width, height: height,
                                    timeBase: stream.pointee.time_base,
                                    frameRate: rate,
                                    bitRate: bitRate,
                                    gop: Int32(max(48, min(600, fps * 4))),
                                    colorPrimaries: parameters.pointee.color_primaries,
                                    colorTransfer: trc,
                                    colorSpace: parameters.pointee.color_space,
                                    colorRange: parameters.pointee.color_range,
                                    sampleAspect: parameters.pointee.sample_aspect_ratio,
                                    frameDuration: 1.0 / fps)
    }
}

enum FFmpegCodecs {
    static func freeContext(_ context: UnsafeMutablePointer<AVCodecContext>?) {
        var doomed = context
        if doomed != nil { avcodec_free_context(&doomed) }
    }

    static func decoder(for parameters: UnsafeMutablePointer<AVCodecParameters>, timeBase: AVRational, threads: Int32 = 0) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id), let context = avcodec_alloc_context3(codec) else { return nil }
        guard avcodec_parameters_to_context(context, parameters) >= 0 else { freeContext(context); return nil }
        context.pointee.pkt_timebase = timeBase
        context.pointee.thread_count = threads
        guard avcodec_open2(context, codec, nil) >= 0 else { freeContext(context); return nil }
        return context
    }

    static func videoEncoder(_ settings: VideoEncoderSettings) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let codec = avcodec_find_encoder_by_name(settings.codecName), let context = avcodec_alloc_context3(codec) else { return nil }
        context.pointee.width = settings.width
        context.pointee.height = settings.height
        context.pointee.pix_fmt = settings.pixelFormat
        context.pointee.time_base = settings.timeBase
        context.pointee.framerate = settings.frameRate
        context.pointee.bit_rate = settings.bitRate
        context.pointee.gop_size = settings.gop
        context.pointee.max_b_frames = 0
        context.pointee.flags |= tcGlobalHeader
        context.pointee.color_primaries = settings.colorPrimaries
        context.pointee.color_trc = settings.colorTransfer
        context.pointee.colorspace = settings.colorSpace
        context.pointee.color_range = settings.colorRange
        context.pointee.profile = settings.profile
        if settings.sampleAspect.num > 0 && settings.sampleAspect.den > 0 { context.pointee.sample_aspect_ratio = settings.sampleAspect }
        var options: OpaquePointer?
        // The hardware encoder first; the software one only where there is none (the simulator the tests run on).
        av_dict_set(&options, "allow_sw", "1", 0)
        let status = avcodec_open2(context, codec, &options)
        av_dict_free(&options)
        guard status >= 0 else { freeContext(context); return nil }
        return context
    }

    /// The parameters a muxer stream needs, taken from an open encoder (the caller frees them).
    static func parameters(of encoder: UnsafeMutablePointer<AVCodecContext>) -> UnsafeMutablePointer<AVCodecParameters>? {
        guard let parameters = avcodec_parameters_alloc() else { return nil }
        guard avcodec_parameters_from_context(parameters, encoder) >= 0 else {
            var doomed: UnsafeMutablePointer<AVCodecParameters>? = parameters
            avcodec_parameters_free(&doomed)
            return nil
        }
        return parameters
    }

    /// The codec string of the encoder's output (for the master playlist), from the parameter sets it writes.
    static func codecString(settings: VideoEncoderSettings) -> String? {
        guard let encoder = videoEncoder(settings) else { return nil }
        defer { freeContext(encoder) }
        guard let data = encoder.pointee.extradata, encoder.pointee.extradata_size > 0 else { return nil }
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(encoder.pointee.extradata_size)))
        return codecString(extradata: bytes, settings: settings)
    }

    /// VideoToolbox writes its parameter sets with start codes (Annex B), not as the MP4 configuration record: H.264 reads its profile
    /// and level from the SPS; HEVC gets a level from the picture size (the muxer writes the real record into the init segment).
    static func codecString(extradata bytes: [UInt8], settings: VideoEncoderSettings) -> String {
        if bytes.first == 1 {
            let parsed = settings.isHEVC ? CodecStrings.hvc1(hvcC: bytes) : CodecStrings.avc1(avcC: bytes)
            if let text = parsed { return text }
        }
        let pixels = Int(settings.width) * Int(settings.height)
        let fps = settings.frameDuration > 0 ? 1.0 / settings.frameDuration : 30
        if settings.isHEVC {
            let level: Int
            if pixels > 2_228_224 { level = fps > 30.5 ? 153 : 150 } else if pixels > 983_040 { level = fps > 30.5 ? 123 : 120 } else { level = 93 }
            return settings.profile == 2 ? "hvc1.2.4.L\(level).90" : "hvc1.1.6.L\(level).90"
        }
        // The first NAL of type 7 (SPS): profile, constraints and level are its three bytes after the header.
        var index = 0
        while index + 4 < bytes.count {
            let isStart = bytes[index] == 0 && bytes[index + 1] == 0 && (bytes[index + 2] == 1 || (bytes[index + 2] == 0 && index + 3 < bytes.count && bytes[index + 3] == 1))
            if isStart {
                let header = bytes[index + 2] == 1 ? index + 3 : index + 4
                if header + 3 < bytes.count, bytes[header] & 0x1F == 7 {
                    return String(format: "avc1.%02X%02X%02X", bytes[header + 1], bytes[header + 2], bytes[header + 3])
                }
                index = header
            } else {
                index += 1
            }
        }
        return pixels > 2_228_224 ? "avc1.640033" : "avc1.640029"
    }
}

/// The encoded packets of one segment and the parameters of the stream they belong to.
final class EncodedTrack {
    var packets: [UnsafeMutablePointer<AVPacket>] = []
    var parameters: UnsafeMutablePointer<AVCodecParameters>?
    var timeBase = AVRational(num: 1, den: 1000)

    deinit {
        for var packet in packets.map({ Optional($0) }) { av_packet_free(&packet) }
        if parameters != nil { avcodec_parameters_free(&parameters) }
    }
}

// MARK: - Picture

enum VideoSegmentTranscoder {
    /// Decodes `packets` (in decode order, from a keyframe) and encodes the frames whose time is in `[start, end)` again. The packets'
    /// times are in `stream`'s time base, and so are the encoded ones (the encoder uses the same time base).
    static func transcode(packets: [UnsafeMutablePointer<AVPacket>], stream: UnsafeMutablePointer<AVStream>, settings: VideoEncoderSettings,
                          start: Double, end: Double, isLast: Bool, cancelled: () -> Bool) throws -> EncodedTrack {
        guard let parameters = stream.pointee.codecpar,
              let decoder = FFmpegCodecs.decoder(for: parameters, timeBase: stream.pointee.time_base) else { throw RemuxError.unreadable }
        defer { FFmpegCodecs.freeContext(decoder) }
        guard let encoder = FFmpegCodecs.videoEncoder(settings) else { throw RemuxError.engine(code: -1) }
        defer { FFmpegCodecs.freeContext(encoder) }
        let output = EncodedTrack()
        output.parameters = FFmpegCodecs.parameters(of: encoder)
        output.timeBase = settings.timeBase
        if settings.isHEVC { output.parameters?.pointee.codec_tag = fourCC("hvc1") }

        var scratchFrame = av_frame_alloc()
        defer { av_frame_free(&scratchFrame) }
        var scratchTarget = av_frame_alloc()
        defer { av_frame_free(&scratchTarget) }
        var scratchPacket = av_packet_alloc()
        defer { av_packet_free(&scratchPacket) }
        guard let frame = scratchFrame, let target = scratchTarget, let encoded = scratchPacket else { throw RemuxError.unreadable }
        var scaler: UnsafeMutablePointer<SwsContext>?
        var scalerKey = ""
        defer { if let used = scaler { sws_freeContext(used) } }
        let base = av_q2d(stream.pointee.time_base)
        var lastPTS = tcNoPTS

        func drainEncoder() throws {
            while true {
                let status = avcodec_receive_packet(encoder, encoded)
                if status == tcAgain || status == tcEOF { return }
                if status < 0 { throw RemuxError.engine(code: Int(status)) }
                if encoded.pointee.dts == tcNoPTS { encoded.pointee.dts = encoded.pointee.pts }
                if let copy = av_packet_clone(encoded) { output.packets.append(copy) }
                av_packet_unref(encoded)
            }
        }

        func encode(_ source: UnsafeMutablePointer<AVFrame>, pts: Int64) throws {
            let key = "\(source.pointee.width)x\(source.pointee.height)-\(source.pointee.format)"
            if key != scalerKey {
                if let old = scaler { sws_freeContext(old) }
                scaler = sws_getContext(source.pointee.width, source.pointee.height, AVPixelFormat(rawValue: source.pointee.format),
                                        settings.width, settings.height, settings.pixelFormat, 2, nil, nil, nil)   // 2 = bilinear
                scalerKey = key
            }
            guard let scaler = scaler else { throw RemuxError.engine(code: -2) }
            av_frame_unref(target)
            target.pointee.format = settings.pixelFormat.rawValue
            target.pointee.width = settings.width
            target.pointee.height = settings.height
            target.pointee.color_primaries = settings.colorPrimaries
            target.pointee.color_trc = settings.colorTransfer
            target.pointee.colorspace = settings.colorSpace
            target.pointee.color_range = settings.colorRange
            guard av_frame_get_buffer(target, 0) >= 0 else { throw RemuxError.engine(code: -3) }
            guard sws_scale_frame(scaler, target, source) >= 0 else { throw RemuxError.engine(code: -4) }
            target.pointee.pts = pts
            var status = avcodec_send_frame(encoder, target)
            if status == tcAgain {
                try drainEncoder()
                status = avcodec_send_frame(encoder, target)
            }
            if status < 0 && status != tcAgain { throw RemuxError.engine(code: Int(status)) }
            try drainEncoder()
        }

        func drainDecoder() throws {
            while true {
                if cancelled() { throw RemuxError.closed }
                let status = avcodec_receive_frame(decoder, frame)
                if status == tcAgain || status == tcEOF { return }
                if status < 0 { throw RemuxError.engine(code: Int(status)) }
                defer { av_frame_unref(frame) }
                var pts = frame.pointee.best_effort_timestamp
                if pts == tcNoPTS { pts = frame.pointee.pts }
                if pts == tcNoPTS { continue }
                let seconds = Double(pts) * base
                // Frames of the piece before (leading pictures) and of the next one are made by those pieces.
                if seconds < start - 0.0005 { continue }
                if !isLast && seconds >= end - 0.0005 { continue }
                if lastPTS != tcNoPTS && pts <= lastPTS { continue }
                lastPTS = pts
                try encode(frame, pts: pts)
            }
        }

        for packet in packets {
            if cancelled() { throw RemuxError.closed }
            if avcodec_send_packet(decoder, packet) == tcAgain {
                try drainDecoder()
                _ = avcodec_send_packet(decoder, packet)
            }
            // A damaged packet is skipped: the decoder resynchronises at the next one.
            try drainDecoder()
        }
        _ = avcodec_send_packet(decoder, nil)
        try drainDecoder()
        _ = avcodec_send_frame(encoder, nil)
        try drainEncoder()
        guard !output.packets.isEmpty else { throw RemuxError.unreadable }
        // Every picture lasts until the next one; the last one a frame, so the piece ends where the next begins.
        output.packets.sort { $0.pointee.pts < $1.pointee.pts }
        let frameTicks = max(1, Int64((settings.frameDuration / av_q2d(settings.timeBase)).rounded()))
        for (position, packet) in output.packets.enumerated() {
            packet.pointee.dts = packet.pointee.pts
            if position + 1 < output.packets.count {
                packet.pointee.duration = max(1, output.packets[position + 1].pointee.pts - packet.pointee.pts)
            } else {
                packet.pointee.duration = frameTicks
            }
        }
        return output
    }

    static func fourCC(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in text.utf8.prefix(4).enumerated() { value |= UInt32(byte) << UInt32(8 * index) }
        return value
    }
}

// MARK: - Sound

enum AudioSegmentTranscoder {
    static let frameSize = 1024

    /// The rate and channels the AAC track gets for a source.
    static let encoderRates: Set<Int32> = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]

    /// The rate and channels the AAC track gets for a source: 5.1 for anything with surround (what AAC carries to every receiver),
    /// stereo, or mono.
    static func outputFormat(sampleRate: Int32, channels: Int32) -> (rate: Int32, channels: Int32, mask: UInt64) {
        let rate: Int32 = encoderRates.contains(sampleRate) ? sampleRate : 48000
        switch channels {
        case 6...: return (rate, 6, 0x3F)        // FL FR FC LFE BL BR (5.1 back, the layout of AAC's 5.1)
        case 2...5: return (rate, 2, 0x3)
        default: return (rate, 1, 0x4)
        }
    }

    static func layout(mask: UInt64) -> AVChannelLayout {
        var layout = AVChannelLayout()
        _ = av_channel_layout_from_mask(&layout, mask)
        return layout
    }

    static func encoder(rate: Int32, channels: Int32, mask: UInt64) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let codec = avcodec_find_encoder_by_name("aac"), let context = avcodec_alloc_context3(codec) else { return nil }
        context.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
        context.pointee.sample_rate = rate
        context.pointee.ch_layout = layout(mask: mask)
        context.pointee.bit_rate = channels >= 6 ? 448_000 : (channels == 2 ? 192_000 : 96_000)
        context.pointee.time_base = AVRational(num: 1, den: rate)
        context.pointee.flags |= tcGlobalHeader
        guard avcodec_open2(context, codec, nil) >= 0 else { FFmpegCodecs.freeContext(context); return nil }
        return context
    }

    /// Decodes the sound of a piece (with some sound before it, so the encoder is warmed up) and encodes the AAC frames that belong to
    /// `[start, end)` on a grid of 1024-sample frames counted from the start of the film: two pieces made apart join without a gap or an
    /// overlap. Packet times are in samples (time base 1/rate), without any offset.
    static func transcode(packets: [UnsafeMutablePointer<AVPacket>], stream: UnsafeMutablePointer<AVStream>, start: Double, end: Double,
                          isLast: Bool, cancelled: () -> Bool) throws -> EncodedTrack {
        guard let parameters = stream.pointee.codecpar,
              let decoder = FFmpegCodecs.decoder(for: parameters, timeBase: stream.pointee.time_base, threads: 1) else { throw RemuxError.unreadable }
        defer { FFmpegCodecs.freeContext(decoder) }
        let format = outputFormat(sampleRate: decoder.pointee.sample_rate, channels: decoder.pointee.ch_layout.nb_channels)
        guard let encoder = encoder(rate: format.rate, channels: format.channels, mask: format.mask) else { throw RemuxError.engine(code: -10) }
        defer { FFmpegCodecs.freeContext(encoder) }
        let output = EncodedTrack()
        output.parameters = FFmpegCodecs.parameters(of: encoder)
        // No edit list is written, so the encoder's priming is not declared: the packets kept already start on the film's time.
        output.parameters?.pointee.initial_padding = 0
        output.timeBase = AVRational(num: 1, den: format.rate)

        let rate = Double(format.rate)
        let channelCount = Int(format.channels)
        var planes = [[Float]](repeating: [], count: channelCount)
        var bufferStart: Int64?
        let base = av_q2d(stream.pointee.time_base)

        var resampler: OpaquePointer?
        defer { if resampler != nil { swr_free(&resampler) } }
        var scratchFrame = av_frame_alloc()
        defer { av_frame_free(&scratchFrame) }
        var scratchConverted = av_frame_alloc()
        defer { av_frame_free(&scratchConverted) }
        guard let frame = scratchFrame, let converted = scratchConverted else { throw RemuxError.unreadable }

        func append(_ source: UnsafeMutablePointer<AVFrame>?) throws {
            guard let swr = resampler else { return }
            av_frame_unref(converted)
            converted.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            converted.pointee.sample_rate = format.rate
            converted.pointee.ch_layout = layout(mask: format.mask)
            let status = swr_convert_frame(swr, converted, source)
            if status < 0 { throw RemuxError.engine(code: Int(status)) }
            let count = Int(converted.pointee.nb_samples)
            guard count > 0, let data = converted.pointee.extended_data else { return }
            for channel in 0..<channelCount {
                guard let plane = data[channel] else { continue }
                let samples = UnsafeMutableRawPointer(plane).assumingMemoryBound(to: Float.self)
                planes[channel].append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            }
        }

        func drainDecoder() throws {
            while true {
                if cancelled() { throw RemuxError.closed }
                let status = avcodec_receive_frame(decoder, frame)
                if status == tcAgain || status == tcEOF { return }
                if status < 0 { throw RemuxError.engine(code: Int(status)) }
                defer { av_frame_unref(frame) }
                if resampler == nil {
                    var outLayout = layout(mask: format.mask)
                    var inLayout = frame.pointee.ch_layout
                    if inLayout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&inLayout, inLayout.nb_channels) }
                    let made = swr_alloc_set_opts2(&resampler, &outLayout, AV_SAMPLE_FMT_FLTP, format.rate,
                                                   &inLayout, AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate, 0, nil)
                    guard made >= 0, let swr = resampler, swr_init(swr) >= 0 else { throw RemuxError.engine(code: -11) }
                }
                if bufferStart == nil {
                    var pts = frame.pointee.best_effort_timestamp
                    if pts == tcNoPTS { pts = frame.pointee.pts }
                    let seconds = pts == tcNoPTS ? start : Double(pts) * base
                    bufferStart = Int64((seconds * rate).rounded())
                }
                try append(frame)
            }
        }

        for packet in packets {
            if cancelled() { throw RemuxError.closed }
            if avcodec_send_packet(decoder, packet) == tcAgain {
                try drainDecoder()
                _ = avcodec_send_packet(decoder, packet)
            }
            try drainDecoder()
        }
        _ = avcodec_send_packet(decoder, nil)
        try drainDecoder()
        try append(nil)

        // The grid: frame k holds samples [k·1024, (k+1)·1024) of the film.
        let size = Int64(frameSize)
        let firstKept = max(0, Int64((start * rate / Double(size)).rounded(.up)))
        let warmUp = max(0, firstKept - 4)
        let lastExclusive: Int64? = isLast ? nil : Int64((end * rate / Double(size)).rounded(.up))
        let available = Int64(planes.first?.count ?? 0)
        let origin = bufferStart ?? warmUp * size
        // Samples from `warmUp · 1024`: missing ones are silence, extra ones before it are dropped.
        let offset = Int(origin - warmUp * size)
        if offset > 0 {
            for channel in 0..<channelCount { planes[channel].insert(contentsOf: [Float](repeating: 0, count: offset), at: 0) }
        } else if offset < 0 {
            let drop = min(-offset, Int(available))
            for channel in 0..<channelCount { planes[channel].removeFirst(drop) }
        }
        let have = Int64(planes.first?.count ?? 0)
        let framesToEncode: Int64
        if let last = lastExclusive {
            // One frame more than kept: the encoder hands a frame over one frame late.
            framesToEncode = max(0, last + 1 - warmUp)
        } else {
            framesToEncode = (have + size - 1) / size + 1
        }

        var scratchInput = av_frame_alloc()
        defer { av_frame_free(&scratchInput) }
        var scratchPacket = av_packet_alloc()
        defer { av_packet_free(&scratchPacket) }
        guard let input = scratchInput, let encoded = scratchPacket else { throw RemuxError.unreadable }

        func drainEncoder() throws {
            while true {
                let status = avcodec_receive_packet(encoder, encoded)
                if status == tcAgain || status == tcEOF { return }
                if status < 0 { throw RemuxError.engine(code: Int(status)) }
                let pts = encoded.pointee.pts
                let keep = pts >= firstKept * size && (lastExclusive.map { pts < $0 * size } ?? true)
                if keep {
                    encoded.pointee.dts = pts
                    if let copy = av_packet_clone(encoded) { output.packets.append(copy) }
                }
                av_packet_unref(encoded)
            }
        }

        var position: Int64 = 0
        while position < framesToEncode {
            if cancelled() { throw RemuxError.closed }
            av_frame_unref(input)
            input.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            input.pointee.sample_rate = format.rate
            input.pointee.nb_samples = Int32(size)
            input.pointee.ch_layout = layout(mask: format.mask)
            guard av_frame_get_buffer(input, 0) >= 0, let data = input.pointee.extended_data else { throw RemuxError.engine(code: -12) }
            let from = Int(position * size)
            for channel in 0..<channelCount {
                guard let plane = data[channel] else { continue }
                let target = UnsafeMutableRawPointer(plane).assumingMemoryBound(to: Float.self)
                let source = planes[channel]
                for sample in 0..<Int(size) {
                    let index = from + sample
                    target[sample] = index < source.count ? source[index] : 0
                }
            }
            input.pointee.pts = (warmUp + position) * size
            var status = avcodec_send_frame(encoder, input)
            if status == tcAgain {
                try drainEncoder()
                status = avcodec_send_frame(encoder, input)
            }
            if status < 0 && status != tcAgain { throw RemuxError.engine(code: Int(status)) }
            try drainEncoder()
            position += 1
        }
        _ = avcodec_send_frame(encoder, nil)
        try drainEncoder()
        return output
    }
}

// MARK: - Subtitles

enum SubtitleTextReader {
    /// The text of a subtitle packet as the codec stores it (mov_text keeps a 16-bit length in front).
    static func text(of packet: UnsafeMutablePointer<AVPacket>, codec: String) -> String? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        var bytes = Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
        if codec.lowercased() == "mov_text" {
            guard bytes.count >= 2 else { return nil }
            let length = Int(bytes[0]) << 8 | Int(bytes[1])
            bytes = Array(bytes.dropFirst(2).prefix(length))
        }
        while bytes.last == 0 { bytes.removeLast() }
        let raw = String(decoding: bytes, as: UTF8.self)
        return WebVTTWriter.text(of: raw, codec: codec)
    }
}

#endif
