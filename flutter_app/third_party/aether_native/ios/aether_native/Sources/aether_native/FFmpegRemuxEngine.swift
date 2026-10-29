import Foundation
import AetherCore

#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
import Libavformat
import Libavcodec
import Libavutil

// MARK: - Numbers FFmpeg defines with macros Swift cannot import

private let ffEOF: Int32 = -541478725         // AVERROR_EOF
private let ffExit: Int32 = -1414092869       // AVERROR_EXIT
private let ffNoPTS = Int64.min               // AV_NOPTS_VALUE
private let ffSeekSize: Int32 = 0x10000       // AVSEEK_SIZE
private let ffSeekForce: Int32 = 0x20000      // AVSEEK_FORCE
private let ffKeyFlag: Int32 = 1              // AV_PKT_FLAG_KEY
private let ffIndexKeyframe: Int32 = 1        // AVINDEX_KEYFRAME
private let ffDispositionDefault: Int32 = 1   // AV_DISPOSITION_DEFAULT
private let ffSeekBackward: Int32 = 1         // AVSEEK_FLAG_BACKWARD
private let ffCustomIO: Int32 = 0x0080        // AVFMT_FLAG_CUSTOM_IO

private func ffTag(_ text: String) -> UInt32 {
    var value: UInt32 = 0
    for (index, byte) in text.utf8.prefix(4).enumerated() { value |= UInt32(byte) << UInt32(8 * index) }
    return value
}

// MARK: - The file, read through ranged fetches

/// The bytes FFmpeg's demuxer reads, fetched from the real source one window at a time. FFmpeg calls it from the engine's own thread, so
/// the fetch (which is async) is waited for here.
private final class RangeInput {
    private let fetcher: RelayRangeFetcher
    let total: Int64
    private let windowSize: Int64
    private var position: Int64 = 0
    private var window = Data()
    private var windowStart: Int64 = 0
    private let lock = NSLock()
    private var cancelled = false
    private var currentFetch: Task<Void, Never>?
    private(set) var failure: Error?

    init(fetcher: RelayRangeFetcher, total: Int64, windowSize: Int64 = 4 << 20) {
        self.fetcher = fetcher
        self.total = total
        self.windowSize = windowSize
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = currentFetch
        lock.unlock()
        task?.cancel()
    }

    private final class Outcome: @unchecked Sendable {
        var result: Result<Data, Error>?
    }

    private func fetchBlocking(_ range: ClosedRange<Int64>) -> Result<Data, Error> {
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let fetcher = self.fetcher
        let task = Task {
            do {
                outcome.result = .success(try await fetcher.fetch(range))
            } catch {
                outcome.result = .failure(error)
            }
            done.signal()
        }
        lock.lock()
        currentFetch = task
        let alreadyCancelled = cancelled
        lock.unlock()
        // A cancel() that came before the task was stored could not reach it.
        if alreadyCancelled { task.cancel() }
        done.wait()
        lock.lock()
        currentFetch = nil
        lock.unlock()
        return outcome.result ?? .failure(RemuxError.closed)
    }

    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        if isCancelled { return ffExit }
        guard position < total, count > 0 else { return ffEOF }
        if position < windowStart || position >= windowStart + Int64(window.count) {
            let end = min(position + windowSize, total) - 1
            switch fetchBlocking(position...end) {
            case .success(let data):
                guard !data.isEmpty else { return ffEOF }
                window = data
                windowStart = position
            case .failure(let error):
                failure = error
                return isCancelled ? ffExit : ffEOF - 1
            }
        }
        let offset = Int(position - windowStart)
        let available = window.count - offset
        let n = min(count, available)
        window.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer, base.advanced(by: offset), n) }
        }
        position += Int64(n)
        return Int32(n)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        let mode = whence & ~ffSeekForce
        if mode == ffSeekSize { return total }
        var target: Int64
        switch mode {
        case 0: target = offset                 // SEEK_SET
        case 1: target = position + offset      // SEEK_CUR
        case 2: target = total + offset         // SEEK_END
        default: return -1
        }
        if target < 0 { return -1 }
        if target > total { target = total }
        position = target
        return target
    }
}

private let ffReadCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32 = { opaque, buffer, size in
    guard let opaque = opaque, let buffer = buffer else { return ffEOF }
    return Unmanaged<RangeInput>.fromOpaque(opaque).takeUnretainedValue().read(into: buffer, count: Int(size))
}

private let ffSeekCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int32) -> Int64 = { opaque, offset, whence in
    guard let opaque = opaque else { return -1 }
    return Unmanaged<RangeInput>.fromOpaque(opaque).takeUnretainedValue().seek(offset: offset, whence: whence)
}

private let ffInterruptCallback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { opaque in
    guard let opaque = opaque else { return 0 }
    return Unmanaged<RangeInput>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
}

// MARK: - The engine

/// Copies an MKV (or any container the system player cannot read) into fragmented MP4 pieces with FFmpeg's demuxer and MP4 muxer. No
/// video or audio is decoded or encoded. The pieces are cut at the file's own keyframes, so a player can start at any of them.
///
/// Every piece is made by a fresh muxer: the muxer writes it with its first sample at time zero, so the real decode time is put back
/// into the fragment afterwards, and the picture's reordering delay is handled by giving every video packet a decode time taken from the
/// sorted presentation times (Matroska stores no decode times).
final class FFmpegRemuxEngine: RemuxEngine, @unchecked Sendable {
    private struct Layout {
        var videoIndex: Int
        /// Input stream indexes that are copied, video first. Their position is the output stream index.
        var copied: [Int]
        var plan: RemuxPlan
        var segments: [RemuxSegmentSpan]
        /// The keyframe each segment starts at, in the video stream's time base.
        var startTimestamps: [Int64]
        /// Added to every presentation time, so decode times can be zero-based.
        var shiftSeconds: Double
    }

    private let queue = DispatchQueue(label: "app.aether.remux")
    private let input: RangeInput
    private let minimumSegment: Double
    private let totalBytes: Int64

    // Only touched on `queue`.
    private var context: UnsafeMutablePointer<AVFormatContext>?
    private var io: UnsafeMutablePointer<AVIOContext>?
    private var layout: Layout?
    private var initData: Data?
    private var firstFragment: Data?
    private var released = false

    private let stateLock = NSLock()
    private var closed = false

    private let audioChoice: RemuxAudioChoice

    init(fetcher: RelayRangeFetcher, totalBytes: Int64, minimumSegment: Double = 6, audio: RemuxAudioChoice = .standard) {
        self.input = RangeInput(fetcher: fetcher, total: totalBytes)
        self.totalBytes = totalBytes
        self.minimumSegment = minimumSegment
        self.audioChoice = audio
    }

    deinit {
        releaseResources()
    }

    // MARK: RemuxEngine

    func prepare() async throws -> RemuxPrepared {
        return try await run { try self.prepareOnQueue() }
    }

    func initSegment() async throws -> Data {
        return try await run {
            if let data = self.initData { return data }
            _ = try self.produce(segment: 0)
            guard let data = self.initData else { throw RemuxError.unreadable }
            return data
        }
    }

    func mediaSegment(_ index: Int) async throws -> Data {
        return try await run {
            if index == 0, let cached = self.firstFragment { return cached }
            return try self.produce(segment: index)
        }
    }

    func close() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        input.cancel()
        queue.async { self.releaseResources() }
    }

    private var isClosed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return closed
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async {
                if self.isClosed {
                    continuation.resume(throwing: RemuxError.closed)
                    return
                }
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ffError(_ code: Int32) -> RemuxError {
        if isClosed || input.isCancelled { return .closed }
        return .engine(code: Int(code))
    }

    // MARK: Opening and planning

    private func prepareOnQueue() throws -> RemuxPrepared {
        guard totalBytes > 0 else { throw RemuxError.unreadable }
        guard let allocated = avformat_alloc_context() else { throw RemuxError.unreadable }
        let bufferSize = 64 * 1024
        guard let buffer = av_malloc(bufferSize)?.assumingMemoryBound(to: UInt8.self) else {
            avformat_free_context(allocated)
            throw RemuxError.unreadable
        }
        let opaque = Unmanaged.passUnretained(input).toOpaque()
        guard let reader = avio_alloc_context(buffer, Int32(bufferSize), 0, opaque, ffReadCallback, nil, ffSeekCallback) else {
            var raw: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(buffer)
            av_freep(&raw)
            avformat_free_context(allocated)
            throw RemuxError.unreadable
        }
        reader.pointee.seekable = 1
        io = reader
        allocated.pointee.pb = reader
        allocated.pointee.flags |= ffCustomIO
        allocated.pointee.interrupt_callback.callback = ffInterruptCallback
        allocated.pointee.interrupt_callback.opaque = opaque

        var opened: UnsafeMutablePointer<AVFormatContext>? = allocated
        var openStatus = avformat_open_input(&opened, nil, nil, nil)
        if openStatus < 0 {
            // avformat_open_input has already freed the context it was given.
            context = nil
            releaseResources()
            throw ffError(openStatus)
        }
        context = opened
        guard let ic = context else { throw RemuxError.unreadable }
        openStatus = avformat_find_stream_info(ic, nil)
        if openStatus < 0 { throw ffError(openStatus) }

        // Tracks.
        var infos: [RemuxStreamInfo] = []
        let streamCount = Int(ic.pointee.nb_streams)
        for index in 0..<streamCount {
            guard let stream = ic.pointee.streams[index], let par = stream.pointee.codecpar else { continue }
            infos.append(describe(stream: stream, parameters: par, index: index))
        }
        let plan: RemuxPlan
        switch RemuxPlanner.plan(infos, audio: audioChoice) {
        case .success(let decided): plan = decided
        case .failure(let refusal): throw RemuxError.refused(refusal)
        }
        let videoIndex = plan.video.index
        guard let videoStream = ic.pointee.streams[videoIndex], let videoPar = videoStream.pointee.codecpar else { throw RemuxError.unreadable }

        // Keyframes: Matroska loads its Cues index on the first seek.
        _ = av_seek_frame(ic, Int32(videoIndex), 0, ffSeekBackward)
        var entryCount = Int(avformat_index_get_entries_count(videoStream))
        // A file with no Cues (and often no Duration) would become ONE piece holding the whole film: read it once from end to end, so
        // the demuxer learns where the keyframes are and the real length, then go back to the start.
        var scannedDuration = 0.0
        if entryCount < 2 && totalBytes > 32 << 20 {
            if var scan = av_packet_alloc() {
                let scanBase = av_q2d(videoStream.pointee.time_base)
                while true {
                    if input.isCancelled || isClosed { av_packet_free(&scan); throw RemuxError.closed }
                    if av_read_frame(ic, scan) < 0 { break }
                    if Int(scan.pointee.stream_index) == videoIndex, scan.pointee.pts != ffNoPTS {
                        let end = Double(scan.pointee.pts + max(scan.pointee.duration, 0)) * scanBase
                        if end > scannedDuration { scannedDuration = end }
                    }
                    av_packet_unref(scan)
                }
                av_packet_free(&scan)
            }
            _ = av_seek_frame(ic, Int32(videoIndex), 0, ffSeekBackward)
            entryCount = Int(avformat_index_get_entries_count(videoStream))
        }
        let timeBase = av_q2d(videoStream.pointee.time_base)
        var keyframes: [(timestamp: Int64, time: Double)] = []
        for entryIndex in 0..<max(0, entryCount) {
            guard let entry = avformat_index_get_entry(videoStream, Int32(entryIndex)), entry.pointee.flags & ffIndexKeyframe != 0 else { continue }
            keyframes.append((entry.pointee.timestamp, Double(entry.pointee.timestamp) * timeBase))
        }
        keyframes.sort { $0.time < $1.time }
        var duration = ic.pointee.duration > 0 ? Double(ic.pointee.duration) / 1_000_000.0 : 0
        if scannedDuration > duration { duration = scannedDuration }
        if duration <= 0, let last = keyframes.last { duration = last.time + 10 }
        guard duration > 0 else { throw RemuxError.unreadable }
        let spans = SegmentPlanner.plan(keyframes: keyframes.map { $0.time }, duration: duration, minimum: minimumSegment)
        guard !spans.isEmpty, keyframes.count >= 2 || duration < 30 else { throw RemuxError.noKeyframeIndex }
        // One piece for a big file would be the whole film in memory: better to refuse than to hang.
        if spans.count == 1 && totalBytes > 64 << 20 { throw RemuxError.noKeyframeIndex }
        var starts: [Int64] = []
        for span in spans {
            let match = keyframes.first(where: { $0.time >= span.start - 1e-6 }) ?? keyframes[0]
            starts.append(match.timestamp)
        }

        // Timing and strings for the master playlist.
        // A frame rate of 0/0 is NaN, which no comparison with 0 catches: it has to be asked for with a positive test.
        var frameRate = av_q2d(videoStream.pointee.avg_frame_rate)
        if !(frameRate > 0) { frameRate = av_q2d(videoStream.pointee.r_frame_rate) }
        if !(frameRate > 0) { frameRate = 0 }
        let frameDuration = frameRate > 0 ? 1.0 / frameRate : 1.0 / 24.0
        let delay = Int(videoPar.pointee.video_delay)
        let shift = delay > 0 ? Double(delay + 1) * frameDuration : 0

        var copied = [videoIndex]
        copied.append(contentsOf: plan.audio.map { $0.index })
        layout = Layout(videoIndex: videoIndex, copied: copied, plan: plan, segments: spans, startTimestamps: starts, shiftSeconds: shift)

        let videoCodec = plan.video.codec.lowercased()
        let extradata = bytes(of: videoPar)
        let videoString: String
        if videoCodec == "h264" {
            videoString = CodecStrings.avc1(avcC: extradata) ?? "avc1.640028"
        } else {
            videoString = CodecStrings.hvc1(hvcC: extradata) ?? "hvc1.1.6.L120.90"
        }
        var codecs = [videoString]
        for track in plan.audio {
            guard let stream = ic.pointee.streams[track.index], let par = stream.pointee.codecpar else { continue }
            var objectType: Int?
            if track.codec.lowercased() == "aac" {
                let config = bytes(of: par)
                if let first = config.first { objectType = Int(first >> 3) }
            }
            if let text = CodecStrings.audio(codec: track.codec, aacObjectType: objectType), !codecs.contains(text) { codecs.append(text) }
        }
        let averageBandwidth = Int(Double(totalBytes) * 8.0 / duration)
        var range = HLSVideoRange.sdr
        if videoPar.pointee.color_trc == AVCOL_TRC_SMPTE2084 { range = .pq }
        if videoPar.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 { range = .hlg }
        let master = HLSMasterInfo(bandwidth: Int(Double(averageBandwidth) * 1.25), averageBandwidth: averageBandwidth,
                                   width: Int(videoPar.pointee.width), height: Int(videoPar.pointee.height),
                                   frameRate: frameRate > 0 ? frameRate : nil, codecs: codecs, range: range)
        return RemuxPrepared(plan: plan, segments: spans, duration: duration, master: master)
    }

    private func bytes(of parameters: UnsafeMutablePointer<AVCodecParameters>) -> [UInt8] {
        guard let data = parameters.pointee.extradata, parameters.pointee.extradata_size > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(parameters.pointee.extradata_size)))
    }

    private func describe(stream: UnsafeMutablePointer<AVStream>, parameters par: UnsafeMutablePointer<AVCodecParameters>, index: Int) -> RemuxStreamInfo {
        let kind: RemuxStreamInfo.Kind
        switch par.pointee.codec_type {
        case AVMEDIA_TYPE_VIDEO: kind = .video
        case AVMEDIA_TYPE_AUDIO: kind = .audio
        case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
        default: kind = .other
        }
        let codec = String(cString: avcodec_get_name(par.pointee.codec_id))
        var profile: String?
        if let name = avcodec_profile_name(par.pointee.codec_id, par.pointee.profile) { profile = String(cString: name) }
        var depth: Int?
        // Some files carry a nonsense value here (a 1080p H.264 reported as "1080 bit"): only 8…16 are believed, else the pixel format
        // says it, else it is unknown (and not refused).
        if (8...16).contains(Int(par.pointee.bits_per_raw_sample)) {
            depth = Int(par.pointee.bits_per_raw_sample)
        } else if kind == .video, par.pointee.format >= 0, let descriptor = av_pix_fmt_desc_get(AVPixelFormat(par.pointee.format)) {
            depth = Int(descriptor.pointee.comp.0.depth)
        }
        var language: String?
        if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0) { language = String(cString: entry.pointee.value) }
        var title: String?
        if let entry = av_dict_get(stream.pointee.metadata, "title", nil, 0) { title = String(cString: entry.pointee.value) }
        return RemuxStreamInfo(index: index, kind: kind, codec: codec, profile: profile, bitDepth: depth,
                               width: kind == .video ? Int(par.pointee.width) : nil, height: kind == .video ? Int(par.pointee.height) : nil,
                               channels: kind == .audio ? Int(par.pointee.ch_layout.nb_channels) : nil, language: language, title: title,
                               isDefault: stream.pointee.disposition & ffDispositionDefault != 0,
                               dolbyVisionProfile: kind == .video ? dolbyVisionProfile(of: par) : nil)
    }

    /// The Dolby Vision profile the stream's configuration record states (5, 7, 8…), nil when it has none.
    private func dolbyVisionProfile(of par: UnsafeMutablePointer<AVCodecParameters>) -> Int? {
        guard par.pointee.nb_coded_side_data > 0, let list = par.pointee.coded_side_data,
              let side = av_packet_side_data_get(list, par.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF),
              let data = side.pointee.data, side.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size else { return nil }
        let record = data.withMemoryRebound(to: AVDOVIDecoderConfigurationRecord.self, capacity: 1) { $0.pointee }
        let profile = Int(record.dv_profile)
        return profile > 0 ? profile : nil
    }

    // MARK: Making a piece

    /// Muxes one segment. Also keeps the init segment (the part of the output before the first fragment) and the first fragment.
    @discardableResult
    private func produce(segment index: Int) throws -> Data {
        guard let ic = context, let layout = layout else { throw RemuxError.closed }
        guard index >= 0, index < layout.segments.count else { throw RemuxError.segmentOutOfRange(index) }
        let span = layout.segments[index]
        let isLast = index == layout.segments.count - 1

        let copiedInputs = Set(layout.copied)
        // Read the packets of this piece.
        guard let videoStream = ic.pointee.streams[layout.videoIndex] else { throw RemuxError.unreadable }
        var status = av_seek_frame(ic, Int32(layout.videoIndex), layout.startTimestamps[index], ffSeekBackward)
        if status < 0 { throw ffError(status) }
        var scratch = av_packet_alloc()
        defer { av_packet_free(&scratch) }
        guard let packet = scratch else { throw RemuxError.unreadable }
        var kept: [UnsafeMutablePointer<AVPacket>] = []
        defer {
            for var leftover in kept.map({ Optional($0) }) { av_packet_free(&leftover) }
        }
        var videoDone = false
        var audioDone = Set<Int>()
        var packetsAfterVideoEnded = 0
        let audioInputs = layout.copied.filter { $0 != layout.videoIndex }
        while true {
            if input.isCancelled || isClosed { throw RemuxError.closed }
            let result = av_read_frame(ic, packet)
            if result < 0 {
                if result == ffEOF { break }
                throw ffError(result)
            }
            defer { av_packet_unref(packet) }
            let inputIndex = Int(packet.pointee.stream_index)
            guard copiedInputs.contains(inputIndex), let stream = ic.pointee.streams[inputIndex] else { continue }
            guard packet.pointee.pts != ffNoPTS || packet.pointee.dts != ffNoPTS else { continue }
            let seconds = Double(packet.pointee.pts != ffNoPTS ? packet.pointee.pts : packet.pointee.dts) * av_q2d(stream.pointee.time_base)
            var keep = true
            if inputIndex == layout.videoIndex {
                if packet.pointee.pts == ffNoPTS { continue }
                if !videoDone && !isLast && packet.pointee.flags & ffKeyFlag != 0 && seconds >= span.end - 1e-6 { videoDone = true }
                if videoDone { keep = false }
            } else {
                if !isLast && seconds >= span.end - 1e-6 { audioDone.insert(inputIndex) }
                if (!isLast && seconds >= span.end - 1e-6) || seconds < span.start - 1e-6 { keep = false }
            }
            if keep, let copy = av_packet_clone(packet) { kept.append(copy) }
            if videoDone {
                // An audio track that ends early would otherwise make this read the rest of the file.
                packetsAfterVideoEnded += 1
                if audioInputs.allSatisfy({ audioDone.contains($0) }) || packetsAfterVideoEnded > 3000 { break }
            }
        }
        guard !kept.isEmpty else { throw RemuxError.unreadable }

        // The tracks this piece has samples for. A track with none (an audio track that ended before the picture did) is left out of
        // this piece's muxer: declaring it would stop the muxer from writing the fragment. The first piece makes the init segment, which
        // must have every track, so it is never allowed to be missing one.
        let present = Set(kept.map { Int($0.pointee.stream_index) })
        guard present.contains(layout.videoIndex) else { throw RemuxError.unreadable }
        let muxedInputs = index == 0 ? layout.copied : layout.copied.filter { present.contains($0) }



        // The muxer.
        var created: UnsafeMutablePointer<AVFormatContext>?
        status = avformat_alloc_output_context2(&created, nil, "mp4", nil)
        guard status >= 0, let oc = created else { throw ffError(status) }
        var muxerPB = false
        defer {
            if muxerPB, oc.pointee.pb != nil {
                var scrap: UnsafeMutablePointer<UInt8>?
                _ = avio_close_dyn_buf(oc.pointee.pb, &scrap)
                av_free(scrap)
                oc.pointee.pb = nil
            }
            avformat_free_context(oc)
        }
        status = avio_open_dyn_buf(&oc.pointee.pb)
        guard status >= 0 else { throw ffError(status) }
        muxerPB = true

        for inputIndex in muxedInputs {
            guard let source = ic.pointee.streams[inputIndex], let sourcePar = source.pointee.codecpar,
                  let target = avformat_new_stream(oc, nil), let targetPar = target.pointee.codecpar else { throw RemuxError.unreadable }
            status = avcodec_parameters_copy(targetPar, sourcePar)
            if status < 0 { throw ffError(status) }
            targetPar.pointee.codec_tag = 0
            if targetPar.pointee.codec_id == AV_CODEC_ID_HEVC { targetPar.pointee.codec_tag = ffTag("hvc1") }
            if targetPar.pointee.codec_type == AVMEDIA_TYPE_AUDIO && targetPar.pointee.frame_size == 0 {
                switch targetPar.pointee.codec_id {
                case AV_CODEC_ID_AAC: targetPar.pointee.frame_size = 1024
                case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: targetPar.pointee.frame_size = 1536
                case AV_CODEC_ID_MP3: targetPar.pointee.frame_size = 1152
                default: break
                }
            }
            if targetPar.pointee.codec_type == AVMEDIA_TYPE_VIDEO, layout.plan.video.dolbyVisionProfile == 7 {
                // The second layer of a profile 7 file is not decodable by Apple's players: the base layer plays as HDR10 and the
                // Dolby Vision record is left out, or the player would look for what it cannot read.
                av_packet_side_data_remove(targetPar.pointee.coded_side_data, &targetPar.pointee.nb_coded_side_data, AV_PKT_DATA_DOVI_CONF)
            }
            target.pointee.time_base = source.pointee.time_base
            if let language = av_dict_get(source.pointee.metadata, "language", nil, 0) {
                av_dict_set(&target.pointee.metadata, "language", language.pointee.value, 0)
            }
        }
        var options: OpaquePointer?
        av_dict_set(&options, "movflags", "frag_custom+empty_moov+delay_moov+default_base_moof+skip_trailer", 0)
        // No edit lists: the fragments carry the real decode times, and an edit list that offsets one track by the picture's reordering
        // delay would put the sound late.
        av_dict_set(&options, "use_editlist", "0", 0)
        oc.pointee.avoid_negative_ts = 0       // AVFMT_AVOID_NEG_TS_DISABLED: times are already consistent across pieces
        status = avformat_write_header(oc, &options)
        av_dict_free(&options)
        if status < 0 { throw ffError(status) }

        var outputIndexOf: [Int: Int] = [:]
        for (position, inputIndex) in muxedInputs.enumerated() { outputIndexOf[inputIndex] = position }

        // Decode times for the video: the i-th smallest presentation time, all presentation times moved later by `shift`.
        let videoBase = av_q2d(videoStream.pointee.time_base)
        let shiftTicks = Int64((layout.shiftSeconds / videoBase).rounded())
        let sortedPTS = kept.filter { Int($0.pointee.stream_index) == layout.videoIndex }.map { $0.pointee.pts }.sorted()
        var videoOrdinal = 0
        var previousDTS = ffNoPTS
        var firstDecodeTimes: [Int: Int64] = [:]
        for item in kept {
            let inputIndex = Int(item.pointee.stream_index)
            guard let source = ic.pointee.streams[inputIndex], let outputIndex = outputIndexOf[inputIndex],
                  let target = oc.pointee.streams[outputIndex] else { continue }
            if inputIndex == layout.videoIndex {
                var dts = sortedPTS[videoOrdinal]
                videoOrdinal += 1
                if dts - item.pointee.pts > shiftTicks { dts = item.pointee.pts + shiftTicks }
                if previousDTS != ffNoPTS && dts <= previousDTS { dts = previousDTS + 1 }
                previousDTS = dts
                item.pointee.pts += shiftTicks
                item.pointee.dts = dts
            } else {
                let ticks = Int64((layout.shiftSeconds / av_q2d(source.pointee.time_base)).rounded())
                if item.pointee.pts == ffNoPTS { item.pointee.pts = item.pointee.dts }
                item.pointee.pts += ticks
                item.pointee.dts = item.pointee.pts
            }
            item.pointee.stream_index = Int32(outputIndex)
            av_packet_rescale_ts(item, source.pointee.time_base, target.pointee.time_base)
            if let known = firstDecodeTimes[outputIndex] {
                if item.pointee.dts < known { firstDecodeTimes[outputIndex] = item.pointee.dts }
            } else {
                firstDecodeTimes[outputIndex] = item.pointee.dts
            }
            status = av_interleaved_write_frame(oc, item)
            if status < 0 { throw ffError(status) }
        }
        status = av_write_trailer(oc)
        if status < 0 { throw ffError(status) }

        var raw: UnsafeMutablePointer<UInt8>?
        let size = avio_close_dyn_buf(oc.pointee.pb, &raw)
        oc.pointee.pb = nil
        muxerPB = false
        defer { av_free(raw) }
        guard size > 0, let memory = raw else { throw RemuxError.unreadable }
        let muxed = Data(bytes: memory, count: Int(size))
        guard var parts = MP4Fragment.split(muxed) else { throw RemuxError.unreadable }

        // Put the real decode times back: track IDs are the output stream positions plus one.
        var times: [UInt32: UInt64] = [:]
        for (outputIndex, first) in firstDecodeTimes { times[UInt32(outputIndex + 1)] = UInt64(max(0, first)) }
        guard MP4Fragment.setDecodeTimes(in: &parts.fragment, times) else { throw RemuxError.unreadable }

        // Only the first piece is made to declare every track; a later piece may lack one (an audio track that has ended), so its
        // `moov` must never become the initialization segment even when it happens to be requested first.
        if index == 0 && initData == nil { initData = parts.initPart }
        if index == 0 { firstFragment = parts.fragment }
        return parts.fragment
    }

    // MARK: Cleanup

    private func releaseResources() {
        if released { return }
        released = true
        if context != nil {
            var doomed = context
            avformat_close_input(&doomed)
            context = nil
        }
        if let reader = io {
            var raw: UnsafeMutableRawPointer? = UnsafeMutableRawPointer(reader.pointee.buffer)
            av_freep(&raw)
            var doomed: UnsafeMutablePointer<AVIOContext>? = reader
            avio_context_free(&doomed)
            io = nil
        }
        initData = nil
        firstFragment = nil
    }
}

#endif
