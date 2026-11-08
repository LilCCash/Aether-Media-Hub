import Foundation
import AetherCore

/// Why a live channel could not be converted, in words for the viewer.
enum LiveRemuxError: Error, Equatable {
    case unavailable
    case unreadable
    case unsupported(String)
    case timedOut

    var message: String {
        switch self {
        case .unavailable: return "La conversione delle dirette non è inclusa in questa versione."
        case .unreadable: return "Il canale non risponde o non si riesce a leggere."
        case .unsupported(let what): return "Il canale usa \(what), che non si può convertire con la conversione «Leggera»: attiva quella «Completa» oppure usa MPV."
        case .timedOut: return "Il canale non ha mandato abbastanza video per iniziare."
        }
    }
}

#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil) && canImport(Libswscale) && canImport(Libswresample)
import Libavformat
import Libavcodec
import Libavutil
import Libswscale
import Libswresample

private let lvEOF: Int32 = -541478725
private let lvAgain: Int32 = -35
private let lvNoPTS = Int64.min
private let lvKey: Int32 = 1
private let lvGlobalHeader: Int32 = 1 << 22

private let lvInterrupt: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
    guard let opaque = opaque else { return 0 }
    return Unmanaged<LiveRemuxEngine>.fromOpaque(opaque).takeUnretainedValue().isClosed ? 1 : 0
}

/// A live channel turned into HLS for the system player while it plays: the stream is read without end, cut into pieces of about two
/// seconds at its keyframes, and the last pieces are offered in a live playlist. Picture H.264/HEVC and sound AAC/AC-3/E-AC-3/MP3 are
/// copied; other sound (MP2, common on TV channels) is encoded as AAC; with the full conversion other pictures (MPEG-2…) are encoded as
/// H.264 with the phone's encoder.
final class LiveRemuxEngine: @unchecked Sendable {
    struct Piece {
        let sequence: Int
        let duration: Double
        let data: Data
    }

    private let url: URL
    private let headers: [String: String]
    private let full: Bool
    private let lock = NSLock()
    private var pieces: [Piece] = []
    private var initData: Data?
    private var failure: LiveRemuxError?
    private var ended = false
    private var closedFlag = false
    private var nextSequence = 0
    private let window = 8
    private let target = 2.0
    /// The streams it found, for the diagnostics.
    private(set) var summary = ""

    init(url: URL, headers: [String: String], full: Bool) {
        self.url = url
        self.headers = headers
        self.full = full
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closedFlag
    }

    /// Starts reading and returns once two pieces are ready (or says why it cannot).
    func start(timeout: TimeInterval = 25) async throws {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "app.aether.live-remux"
        thread.qualityOfService = .userInitiated
        thread.start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let state: (count: Int, failure: LiveRemuxError?, ended: Bool) = locked { (pieces.count, failure, ended) }
            if let failure = state.failure { close(); throw failure }
            if state.count >= 2 { return }
            if state.ended { close(); throw LiveRemuxError.unreadable }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        close()
        throw LiveRemuxError.timedOut
    }

    func close() {
        locked { closedFlag = true }
    }

    func playlist() -> String {
        return locked {
            let longest = pieces.map { $0.duration }.max() ?? target
            var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(max(1, Int(longest.rounded(.up))))",
                         "#EXT-X-MEDIA-SEQUENCE:\(pieces.first?.sequence ?? 0)", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"init.mp4\""]
            for piece in pieces {
                lines.append(String(format: "#EXTINF:%.3f,", locale: Locale(identifier: "en_US_POSIX"), piece.duration))
                lines.append("seg-\(piece.sequence).m4s")
            }
            if ended { lines.append("#EXT-X-ENDLIST") }
            lines.append("")
            return lines.joined(separator: "\n")
        }
    }

    func initSegment() -> Data? { return locked { initData } }

    func piece(_ sequence: Int) -> Data? { return locked { pieces.first { $0.sequence == sequence }?.data } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func fail(_ error: LiveRemuxError) {
        locked {
            if failure == nil && pieces.isEmpty { failure = error }
            ended = true
        }
    }

    // MARK: Reading

    private struct Track {
        var input: Int
        var timeBase: AVRational
        /// Parameters of what is written (the input's when copied, the encoder's when encoded).
        var parameters: UnsafeMutablePointer<AVCodecParameters>
        var ownsParameters: Bool
    }

    private func run() {
        var context: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard let allocated = context else { fail(.unreadable); return }
        allocated.pointee.interrupt_callback.callback = lvInterrupt
        allocated.pointee.interrupt_callback.opaque = Unmanaged.passUnretained(self).toOpaque()
        var options: OpaquePointer?
        let headerText = headers.filter { $0.key.lowercased() != "user-agent" }.map { "\($0.key): \($0.value)\r\n" }.joined()
        if !headerText.isEmpty { av_dict_set(&options, "headers", headerText, 0) }
        if let agent = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value { av_dict_set(&options, "user_agent", agent, 0) }
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        av_dict_set(&options, "reconnect_delay_max", "4", 0)
        av_dict_set(&options, "rw_timeout", "15000000", 0)
        av_dict_set(&options, "analyzeduration", "3000000", 0)
        av_dict_set(&options, "probesize", "3000000", 0)
        av_dict_set(&options, "fflags", "+genpts+discardcorrupt", 0)
        let opened = avformat_open_input(&context, url.absoluteString, nil, &options)
        av_dict_free(&options)
        guard opened >= 0, let ic = context else { fail(.unreadable); return }
        defer { var doomed: UnsafeMutablePointer<AVFormatContext>? = ic; avformat_close_input(&doomed) }
        guard avformat_find_stream_info(ic, nil) >= 0 else { fail(.unreadable); return }

        let videoIndex = Int(av_find_best_stream(ic, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        guard videoIndex >= 0, let videoStream = ic.pointee.streams[videoIndex], let videoPar = videoStream.pointee.codecpar else {
            fail(.unsupported("solo audio")); return
        }
        let audioIndex = Int(av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, -1, Int32(videoIndex), nil, 0))
        let audioStream: UnsafeMutablePointer<AVStream>? = audioIndex >= 0 ? ic.pointee.streams[audioIndex] : nil

        // What passes as it is, what is made again.
        let videoCodec = videoPar.pointee.codec_id
        var depth = Int(videoPar.pointee.bits_per_raw_sample)
        if depth <= 0, videoPar.pointee.format >= 0, let descriptor = av_pix_fmt_desc_get(AVPixelFormat(videoPar.pointee.format)) {
            depth = Int(descriptor.pointee.comp.0.depth)
        }
        let videoCopies = (videoCodec == AV_CODEC_ID_H264 && depth <= 8) || (videoCodec == AV_CODEC_ID_HEVC && depth <= 10)
        let videoName = String(cString: avcodec_get_name(videoCodec))
        if !videoCopies && !full { fail(.unsupported("il video \(RemuxNamesBridge.display(videoName))")); return }
        var audioCopies = false
        if let par = audioStream?.pointee.codecpar {
            let id = par.pointee.codec_id
            audioCopies = id == AV_CODEC_ID_AAC || id == AV_CODEC_ID_AC3 || id == AV_CODEC_ID_EAC3 || id == AV_CODEC_ID_MP3
        }
        let audioName = audioStream?.pointee.codecpar.map { String(cString: avcodec_get_name($0.pointee.codec_id)) } ?? "nessuno"
        summary = "video \(videoName)\(videoCopies ? " copiato" : " ricodificato in H.264"), audio \(audioName)\(audioStream == nil ? "" : (audioCopies ? " copiato" : " ricodificato in AAC"))"

        // Encoders.
        var videoEncoder: LiveVideoEncoder?
        if !videoCopies {
            guard let made = LiveVideoEncoder(stream: videoStream) else { fail(.unsupported("un video che il telefono non sa ricodificare")); return }
            videoEncoder = made
        }
        var audioEncoder: LiveAudioEncoder?
        if let stream = audioStream, !audioCopies {
            audioEncoder = LiveAudioEncoder(stream: stream)
        }

        var tracks: [Track] = []
        if let encoder = videoEncoder {
            tracks.append(Track(input: videoIndex, timeBase: encoder.timeBase, parameters: encoder.parameters, ownsParameters: false))
        } else {
            tracks.append(Track(input: videoIndex, timeBase: videoStream.pointee.time_base, parameters: videoPar, ownsParameters: false))
        }
        if let stream = audioStream, let par = stream.pointee.codecpar {
            if let encoder = audioEncoder {
                tracks.append(Track(input: audioIndex, timeBase: encoder.timeBase, parameters: encoder.parameters, ownsParameters: false))
            } else if audioCopies {
                tracks.append(Track(input: audioIndex, timeBase: stream.pointee.time_base, parameters: par, ownsParameters: false))
            }
        }

        var scratch = av_packet_alloc()
        defer { av_packet_free(&scratch) }
        guard let packet = scratch else { fail(.unreadable); return }
        // Pending packets per output track, in that track's time base, already moved so the channel starts at zero.
        var pending: [[UnsafeMutablePointer<AVPacket>]] = Array(repeating: [], count: tracks.count)
        defer { for list in pending { for var item in list.map({ Optional($0) }) { av_packet_free(&item) } } }
        var origin: Double?            // seconds of the first picture
        var pieceStart: Double?        // seconds (from origin) where the piece being gathered starts
        var lastVideoTime = 0.0
        var shift = 0.0                // added after a jump of the channel's clock

        func seconds(_ value: Int64, _ base: AVRational) -> Double { return Double(value) * av_q2d(base) }
        func ticks(_ value: Double, _ base: AVRational) -> Int64 { return Int64((value / av_q2d(base)).rounded()) }

        /// A packet of output track `track` with times in seconds from the origin.
        func queue(_ item: UnsafeMutablePointer<AVPacket>, track: Int) {
            pending[track].append(item)
        }

        func cut(at time: Double) {
            guard let start = pieceStart, time - start > 0.2 else { return }
            // The first piece makes the init segment, which must declare the sound too: it waits for some.
            if tracks.count > 1, locked({ initData == nil }),
               !pending[1].contains(where: { seconds($0.pointee.dts, tracks[1].timeBase) < time }) { return }
            var chosen: [[UnsafeMutablePointer<AVPacket>]] = Array(repeating: [], count: tracks.count)
            for index in tracks.indices {
                let base = tracks[index].timeBase
                var keep: [UnsafeMutablePointer<AVPacket>] = []
                for item in pending[index] {
                    let at = seconds(item.pointee.dts, base)
                    if index == 0 || at < time { chosen[index].append(item) } else { keep.append(item) }
                }
                pending[index] = keep
            }
            if let data = mux(tracks: tracks, packets: chosen) {
                locked {
                    if initData == nil { initData = data.initPart }
                    pieces.append(Piece(sequence: nextSequence, duration: time - start, data: data.fragment))
                    nextSequence += 1
                    if pieces.count > window { pieces.removeFirst(pieces.count - window) }
                }
            }
            for list in chosen { for var item in list.map({ Optional($0) }) { av_packet_free(&item) } }
            pieceStart = time
        }

        while !isClosed {
            let status = av_read_frame(ic, packet)
            if status == lvAgain { continue }
            if status < 0 { break }
            defer { av_packet_unref(packet) }
            let index = Int(packet.pointee.stream_index)
            guard index == videoIndex || index == audioIndex, let stream = ic.pointee.streams[index] else { continue }
            if packet.pointee.dts == lvNoPTS { packet.pointee.dts = packet.pointee.pts }
            if packet.pointee.pts == lvNoPTS { packet.pointee.pts = packet.pointee.dts }
            guard packet.pointee.dts != lvNoPTS else { continue }
            let base = stream.pointee.time_base
            if index == videoIndex {
                if origin == nil {
                    // The channel starts at its first keyframe: what comes before cannot be shown.
                    guard packet.pointee.flags & lvKey != 0 || videoEncoder != nil else { continue }
                    origin = seconds(packet.pointee.dts, base)
                    pieceStart = 0
                }
                guard let zero = origin else { continue }
                var time = seconds(packet.pointee.dts, base) - zero + shift
                // A clock that jumps (the channel restarted its stream) is stitched to the time before.
                if time < lastVideoTime - 1 || time > lastVideoTime + 10 {
                    shift += lastVideoTime + 0.04 - time
                    time = lastVideoTime + 0.04
                }
                lastVideoTime = time
                if let encoder = videoEncoder {
                    let made = encoder.encode(packet, time: time, keyEvery: target)
                    for item in made {
                        let at = seconds(item.pointee.dts, encoder.timeBase)
                        if item.pointee.flags & lvKey != 0, let start = pieceStart, at - start >= target - 0.05 { cut(at: at) }
                        queue(item, track: 0)
                    }
                } else {
                    if packet.pointee.flags & lvKey != 0, let start = pieceStart, time - start >= target - 0.05 { cut(at: time) }
                    guard let copy = av_packet_clone(packet) else { continue }
                    let offset = ticks(-zero + shift, base)
                    copy.pointee.dts += offset
                    copy.pointee.pts += offset
                    queue(copy, track: 0)
                }
            } else if let zero = origin, tracks.count > 1 {
                let time = seconds(packet.pointee.pts, base) - zero + shift
                guard time >= 0 else { continue }
                if let encoder = audioEncoder {
                    for item in encoder.encode(packet, time: time) { queue(item, track: 1) }
                } else {
                    guard let copy = av_packet_clone(packet) else { continue }
                    let offset = ticks(-zero + shift, base)
                    copy.pointee.pts += offset
                    copy.pointee.dts = copy.pointee.pts
                    queue(copy, track: 1)
                }
            }
        }
        locked { ended = true }
        if !isClosed, let start = pieceStart, lastVideoTime > start { cut(at: lastVideoTime + 0.04) }
        if locked({ pieces.isEmpty }) { fail(.unreadable) }
        // The tracks point into the encoders: they must live until the last piece is made.
        withExtendedLifetime((videoEncoder, audioEncoder)) {}
    }

    // MARK: Pieces

    /// One fragmented MP4 piece of the gathered packets (and the init segment the first time).
    private func mux(tracks allTracks: [Track], packets allPackets: [[UnsafeMutablePointer<AVPacket>]]) -> (initPart: Data, fragment: Data)? {
        guard !allPackets[0].isEmpty else { return nil }
        // A track with nothing in this piece (a gap in the sound) is left out: declared empty, it would stop the fragment.
        let used = allTracks.indices.filter { $0 == 0 || !allPackets[$0].isEmpty }
        let tracks = used.map { allTracks[$0] }
        let packets = used.map { allPackets[$0] }
        var created: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(&created, nil, "mp4", nil) >= 0, let oc = created else { return nil }
        defer { avformat_free_context(oc) }
        guard avio_open_dyn_buf(&oc.pointee.pb) >= 0 else { return nil }
        var bufferOpen = true
        defer {
            if bufferOpen {
                var scrap: UnsafeMutablePointer<UInt8>?
                _ = avio_close_dyn_buf(oc.pointee.pb, &scrap)
                av_free(scrap)
                oc.pointee.pb = nil
            }
        }
        for track in tracks {
            guard let stream = avformat_new_stream(oc, nil), let par = stream.pointee.codecpar,
                  avcodec_parameters_copy(par, track.parameters) >= 0 else { return nil }
            par.pointee.codec_tag = 0
            if par.pointee.codec_id == AV_CODEC_ID_HEVC { par.pointee.codec_tag = RemuxTag.hvc1 }
            if par.pointee.codec_type == AVMEDIA_TYPE_AUDIO && par.pointee.frame_size == 0 {
                switch par.pointee.codec_id {
                case AV_CODEC_ID_AAC: par.pointee.frame_size = 1024
                case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: par.pointee.frame_size = 1536
                case AV_CODEC_ID_MP3: par.pointee.frame_size = 1152
                default: break
                }
            }
            par.pointee.initial_padding = 0
            stream.pointee.time_base = track.timeBase
        }
        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_custom+empty_moov+delay_moov+default_base_moof+skip_trailer", 0)
        av_dict_set(&options, "use_editlist", "0", 0)
        oc.pointee.avoid_negative_ts = 0
        let header = avformat_write_header(oc, &options)
        av_dict_free(&options)
        guard header >= 0 else { return nil }
        var first: [Int: Int64] = [:]
        for (index, list) in packets.enumerated() {
            guard let target = oc.pointee.streams[index] else { continue }
            for item in list {
                guard let handed = av_packet_clone(item) else { continue }
                handed.pointee.stream_index = Int32(index)
                av_packet_rescale_ts(handed, tracks[index].timeBase, target.pointee.time_base)
                if first[index] == nil || handed.pointee.dts < (first[index] ?? 0) { first[index] = handed.pointee.dts }
                var optional: UnsafeMutablePointer<AVPacket>? = handed
                _ = av_interleaved_write_frame(oc, handed)
                av_packet_free(&optional)
            }
        }
        guard av_write_trailer(oc) >= 0 else { return nil }
        var raw: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(oc.pointee.pb, &raw)
        oc.pointee.pb = nil
        bufferOpen = false
        defer { av_free(raw) }
        guard size > 0, let memory = raw else { return nil }
        guard var parts = MP4Fragment.split(Data(bytes: memory, count: Int(size))) else { return nil }
        var times: [UInt32: UInt64] = [:]
        for (index, value) in first { times[UInt32(index + 1)] = UInt64(max(0, value)) }
        guard MP4Fragment.setDecodeTimes(in: &parts.fragment, times) else { return nil }
        return parts
    }
}

enum RemuxTag {
    static let hvc1: UInt32 = {
        var value: UInt32 = 0
        for (index, byte) in "hvc1".utf8.enumerated() { value |= UInt32(byte) << UInt32(8 * index) }
        return value
    }()
}

/// Codec names for the viewer (the Core's own list).
enum RemuxNamesBridge {
    static func display(_ codec: String) -> String {
        switch codec.lowercased() {
        case "mpeg2video": return "MPEG-2"
        case "mpeg4": return "MPEG-4"
        case "h264": return "H.264 a 10 bit"
        case "hevc": return "HEVC a 12 bit"
        case "vc1": return "VC-1"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        default: return codec.uppercased()
        }
    }
}

// MARK: - Encoders that keep running for the whole channel

/// Decodes the channel's picture and encodes it as H.264 with the phone's encoder, a keyframe every couple of seconds.
final class LiveVideoEncoder {
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let encoder: UnsafeMutablePointer<AVCodecContext>
    let parameters: UnsafeMutablePointer<AVCodecParameters>
    let timeBase: AVRational
    private let stream: UnsafeMutablePointer<AVStream>
    private var frame = av_frame_alloc()
    private var target = av_frame_alloc()
    private var output = av_packet_alloc()
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var scalerKey = ""
    private var nextKey = 0.0
    private var lastPTS = Int64.min
    private let width: Int32
    private let height: Int32

    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let par = stream.pointee.codecpar,
              let decoder = FFmpegCodecs.decoder(for: par, timeBase: stream.pointee.time_base) else { return nil }
        var settings = VideoEncoderSettings.choose(for: par, stream: stream, bitDepth: 8)
        // A live picture is H.264 8 bit: every receiver plays it, and it is quick to make.
        settings.codecName = "h264_videotoolbox"
        settings.isHEVC = false
        settings.pixelFormat = AV_PIX_FMT_NV12
        settings.profile = 100
        settings.timeBase = AVRational(num: 1, den: 90000)
        settings.gop = 600
        guard let encoder = FFmpegCodecs.videoEncoder(settings), let parameters = FFmpegCodecs.parameters(of: encoder) else {
            FFmpegCodecs.freeContext(decoder)
            return nil
        }
        self.stream = stream
        self.decoder = decoder
        self.encoder = encoder
        self.parameters = parameters
        self.timeBase = settings.timeBase
        self.width = settings.width
        self.height = settings.height
    }

    deinit {
        av_frame_free(&frame)
        av_frame_free(&target)
        av_packet_free(&output)
        if let scaler = scaler { sws_freeContext(scaler) }
        var par: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&par)
        FFmpegCodecs.freeContext(decoder)
        FFmpegCodecs.freeContext(encoder)
    }

    /// The encoded packets that came out for this input packet; `time` is the packet's time from the start of the channel.
    func encode(_ packet: UnsafeMutablePointer<AVPacket>, time: Double, keyEvery: Double) -> [UnsafeMutablePointer<AVPacket>] {
        var made: [UnsafeMutablePointer<AVPacket>] = []
        guard let frame = frame, let target = target, let output = output else { return made }
        let inputBase = av_q2d(stream.pointee.time_base)
        let offset = time - Double(packet.pointee.dts) * inputBase
        _ = avcodec_send_packet(decoder, packet)
        while avcodec_receive_frame(decoder, frame) >= 0 {
            defer { av_frame_unref(frame) }
            var stamp = frame.pointee.best_effort_timestamp
            if stamp == Int64.min { stamp = frame.pointee.pts }
            if stamp == Int64.min { continue }
            let seconds = Double(stamp) * inputBase + offset
            let pts = Int64((seconds * 90000).rounded())
            if pts <= lastPTS { continue }
            lastPTS = pts
            let key = "\(frame.pointee.width)x\(frame.pointee.height)-\(frame.pointee.format)"
            if key != scalerKey {
                if let old = scaler { sws_freeContext(old) }
                scaler = sws_getContext(frame.pointee.width, frame.pointee.height, AVPixelFormat(rawValue: frame.pointee.format),
                                        width, height, AV_PIX_FMT_NV12, 2, nil, nil, nil)
                scalerKey = key
            }
            guard let scaler = scaler else { continue }
            av_frame_unref(target)
            target.pointee.format = AV_PIX_FMT_NV12.rawValue
            target.pointee.width = width
            target.pointee.height = height
            guard av_frame_get_buffer(target, 0) >= 0, sws_scale_frame(scaler, target, frame) >= 0 else { continue }
            target.pointee.pts = pts
            // A keyframe every `keyEvery` seconds: the pieces are cut there.
            if seconds >= nextKey {
                target.pointee.pict_type = AV_PICTURE_TYPE_I
                nextKey = seconds + keyEvery
            } else {
                target.pointee.pict_type = AV_PICTURE_TYPE_NONE
            }
            _ = avcodec_send_frame(encoder, target)
            while avcodec_receive_packet(encoder, output) >= 0 {
                if output.pointee.dts == Int64.min { output.pointee.dts = output.pointee.pts }
                output.pointee.dts = output.pointee.pts
                if let copy = av_packet_clone(output) { made.append(copy) }
                av_packet_unref(output)
            }
        }
        return made
    }
}

/// Decodes the channel's sound (MP2, Opus, DTS…) and encodes it as AAC, frame after frame.
final class LiveAudioEncoder {
    private let decoder: UnsafeMutablePointer<AVCodecContext>
    private let encoder: UnsafeMutablePointer<AVCodecContext>
    let parameters: UnsafeMutablePointer<AVCodecParameters>
    let timeBase: AVRational
    private let stream: UnsafeMutablePointer<AVStream>
    private let rate: Int32
    private let channels: Int
    private let mask: UInt64
    private var resampler: OpaquePointer?
    private var frame = av_frame_alloc()
    private var converted = av_frame_alloc()
    private var input = av_frame_alloc()
    private var output = av_packet_alloc()
    private var planes: [[Float]]
    /// The sample (from the start of the channel) the next encoded frame starts at.
    private var nextSample: Int64?

    init?(stream: UnsafeMutablePointer<AVStream>) {
        guard let par = stream.pointee.codecpar,
              let decoder = FFmpegCodecs.decoder(for: par, timeBase: stream.pointee.time_base, threads: 1) else { return nil }
        let format = AudioSegmentTranscoder.outputFormat(sampleRate: decoder.pointee.sample_rate, channels: decoder.pointee.ch_layout.nb_channels)
        guard let encoder = AudioSegmentTranscoder.encoder(rate: format.rate, channels: format.channels, mask: format.mask),
              let parameters = FFmpegCodecs.parameters(of: encoder) else {
            FFmpegCodecs.freeContext(decoder)
            return nil
        }
        parameters.pointee.initial_padding = 0
        self.stream = stream
        self.decoder = decoder
        self.encoder = encoder
        self.parameters = parameters
        self.rate = format.rate
        self.channels = Int(format.channels)
        self.mask = format.mask
        self.timeBase = AVRational(num: 1, den: format.rate)
        self.planes = Array(repeating: [], count: Int(format.channels))
    }

    deinit {
        av_frame_free(&frame)
        av_frame_free(&converted)
        av_frame_free(&input)
        av_packet_free(&output)
        if resampler != nil { swr_free(&resampler) }
        var par: UnsafeMutablePointer<AVCodecParameters>? = parameters
        avcodec_parameters_free(&par)
        FFmpegCodecs.freeContext(decoder)
        FFmpegCodecs.freeContext(encoder)
    }

    func encode(_ packet: UnsafeMutablePointer<AVPacket>, time: Double) -> [UnsafeMutablePointer<AVPacket>] {
        var made: [UnsafeMutablePointer<AVPacket>] = []
        guard let frame = frame, let converted = converted, let input = input, let output = output else { return made }
        if nextSample == nil { nextSample = Int64((time * Double(rate)).rounded()) }
        _ = avcodec_send_packet(decoder, packet)
        while avcodec_receive_frame(decoder, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if resampler == nil {
                var outLayout = AudioSegmentTranscoder.layout(mask: mask)
                var inLayout = frame.pointee.ch_layout
                if inLayout.order == AV_CHANNEL_ORDER_UNSPEC { av_channel_layout_default(&inLayout, inLayout.nb_channels) }
                guard swr_alloc_set_opts2(&resampler, &outLayout, AV_SAMPLE_FMT_FLTP, rate, &inLayout,
                                          AVSampleFormat(rawValue: frame.pointee.format), frame.pointee.sample_rate, 0, nil) >= 0,
                      let swr = resampler, swr_init(swr) >= 0 else { return made }
            }
            guard let swr = resampler else { return made }
            av_frame_unref(converted)
            converted.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            converted.pointee.sample_rate = rate
            converted.pointee.ch_layout = AudioSegmentTranscoder.layout(mask: mask)
            guard swr_convert_frame(swr, converted, frame) >= 0, let data = converted.pointee.extended_data else { continue }
            let count = Int(converted.pointee.nb_samples)
            for channel in 0..<channels {
                guard let plane = data[channel] else { continue }
                let samples = UnsafeMutableRawPointer(plane).assumingMemoryBound(to: Float.self)
                planes[channel].append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            }
        }
        let size = AudioSegmentTranscoder.frameSize
        while (planes.first?.count ?? 0) >= size {
            av_frame_unref(input)
            input.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
            input.pointee.sample_rate = rate
            input.pointee.nb_samples = Int32(size)
            input.pointee.ch_layout = AudioSegmentTranscoder.layout(mask: mask)
            guard av_frame_get_buffer(input, 0) >= 0, let data = input.pointee.extended_data else { break }
            for channel in 0..<channels {
                guard let plane = data[channel] else { continue }
                let target = UnsafeMutableRawPointer(plane).assumingMemoryBound(to: Float.self)
                planes[channel].withUnsafeBufferPointer { source in
                    if let base = source.baseAddress { target.update(from: base, count: size) }
                }
                planes[channel].removeFirst(size)
            }
            let start = nextSample ?? 0
            input.pointee.pts = start
            nextSample = start + Int64(size)
            _ = avcodec_send_frame(encoder, input)
            while avcodec_receive_packet(encoder, output) >= 0 {
                if output.pointee.pts >= 0 {
                    output.pointee.dts = output.pointee.pts
                    if let copy = av_packet_clone(output) { made.append(copy) }
                }
                av_packet_unref(output)
            }
        }
        return made
    }
}

#else

final class LiveRemuxEngine: @unchecked Sendable {
    init(url: URL, headers: [String: String], full: Bool) {}
    func start(timeout: TimeInterval = 25) async throws { throw LiveRemuxError.unavailable }
    func close() {}
    func playlist() -> String { return "" }
    func initSegment() -> Data? { return nil }
    func piece(_ sequence: Int) -> Data? { return nil }
    var summary: String { return "" }
}

#endif

// MARK: - Served on the phone

/// The live channel as files for the relay's server on 127.0.0.1: the playlist, the init segment and the pieces.
final class LiveRemuxSource: RelaySource, @unchecked Sendable {
    let engine: LiveRemuxEngine
    /// The same channel can be served on 127.0.0.1 and on the Wi-Fi address (for AirPlay): only the first ends it.
    private let closesEngine: Bool

    init(engine: LiveRemuxEngine, closesEngine: Bool = true) {
        self.engine = engine
        self.closesEngine = closesEngine
    }

    private func bytes(_ name: String) throws -> (Data, String) {
        if name == "index.m3u8" { return (Data(engine.playlist().utf8), "application/vnd.apple.mpegurl") }
        if name == "init.mp4", let data = engine.initSegment() { return (data, "video/mp4") }
        if name.hasPrefix("seg-"), name.hasSuffix(".m4s"), let number = Int(name.dropFirst(4).dropLast(4)), let data = engine.piece(number) {
            return (data, "video/mp4")
        }
        throw RelayError.notFound
    }

    func resource(named leaf: String) async throws -> RelayResource {
        let (data, type) = try bytes(leaf)
        return RelayResource(contentType: type, length: Int64(data.count), acceptsRanges: true)
    }

    func open(_ leaf: String, range: ClosedRange<Int64>?) async throws -> RelayBodyReader {
        let (data, _) = try bytes(leaf)
        let total = Int64(data.count)
        let bounds = range ?? (total > 0 ? 0...(total - 1) : nil)
        if let bounds = bounds, bounds.lowerBound < 0 || bounds.upperBound >= total { throw RelayError.rangeNotSatisfiable(total: total) }
        return LiveBodyReader(data: data, range: bounds)
    }

    func close() {
        if closesEngine { engine.close() }
    }
}

/// A piece in memory, handed over in blocks.
final class LiveBodyReader: RelayBodyReader, @unchecked Sendable {
    private let data: Data
    private let last: Int
    private var position: Int
    private let lock = NSLock()
    private var cancelled = false

    init(data: Data, range: ClosedRange<Int64>?) {
        self.data = data
        self.position = Int(range?.lowerBound ?? 0)
        self.last = range.map { Int($0.upperBound) } ?? -1
    }

    func next() async throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || position > last { return nil }
        let end = min(position + 256 * 1024 - 1, last)
        let chunk = data.subdata(in: (data.startIndex + position)..<(data.startIndex + end + 1))
        position = end + 1
        return chunk
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
