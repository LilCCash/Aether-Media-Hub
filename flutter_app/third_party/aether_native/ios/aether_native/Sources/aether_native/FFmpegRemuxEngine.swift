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
    private let note: (String) -> Void
    private var windows = 0

    init(fetcher: RelayRangeFetcher, total: Int64, windowSize: Int64 = 4 << 20, note: @escaping (String) -> Void = { _ in }) {
        self.fetcher = fetcher
        self.total = total
        self.windowSize = windowSize
        self.note = note
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
            var outcome = fetchBlocking(position...end)
            // A window that fails is asked again (twice) before the file is given up on: a debrid link can refuse one request and
            // accept the next.
            var attempt = 1
            while case .failure(let error) = outcome, attempt < 3, !isCancelled {
                note("finestra a \(position >> 20) MB: errore (\(RelayError.mapping(error))), riprovo")
                Thread.sleep(forTimeInterval: 0.6 * Double(attempt))
                attempt += 1
                outcome = fetchBlocking(position...end)
            }
            switch outcome {
            case .success(let data):
                windows += 1
                if windows <= 6 || data.count != Int(end - position + 1) {
                    note("finestra a \(position >> 20) MB: \(data.count / 1024) KB (chiesti \((end - position + 1) / 1024))")
                }
                guard !data.isEmpty else { return ffEOF }
                window = data
                windowStart = position
            case .failure(let error):
                failure = error
                note("finestra a \(position >> 20) MB: persa (\(RelayError.mapping(error)))")
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

    private let note: (String) -> Void

    init(fetcher: RelayRangeFetcher, totalBytes: Int64, minimumSegment: Double = 6, audio: RemuxAudioChoice = .standard,
         note: @escaping (String) -> Void = { _ in }) {
        self.note = note
        self.input = RangeInput(fetcher: fetcher, total: totalBytes, note: note)
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
        if let vs = ic.pointee.streams[videoIndex], let vp = vs.pointee.codecpar {
            let pixel = vp.pointee.format >= 0 ? (av_get_pix_fmt_name(AVPixelFormat(vp.pointee.format)).map { String(cString: $0) } ?? "?") : "sconosciuto"
            let profile = avcodec_profile_name(vp.pointee.codec_id, vp.pointee.profile).map { String(cString: $0) } ?? "?"
            note("video: \(plan.video.codec) \(profile) (\(vp.pointee.profile)), livello \(vp.pointee.level), pixel \(pixel), bit \(vp.pointee.bits_per_raw_sample), \(vp.pointee.width)x\(vp.pointee.height)")
        }
        guard let videoStream = ic.pointee.streams[videoIndex], let videoPar = videoStream.pointee.codecpar else { throw RemuxError.unreadable }

        // Keyframes: Matroska loads its Cues index on the first seek.
        _ = av_seek_frame(ic, Int32(videoIndex), 0, ffSeekBackward)
        var entryCount = Int(avformat_index_get_entries_count(videoStream))
        note("indice: \(entryCount) fotogrammi chiave, durata dichiarata \(ic.pointee.duration > 0 ? Int(ic.pointee.duration / 1_000_000) : 0) s")
        // A file with no Cues (and often no Duration) would become ONE piece holding the whole film: read it once from end to end, so
        // the demuxer learns where the keyframes are and the real length, then go back to the start.
        var scannedDuration = 0.0
        if entryCount < 2 && totalBytes > 32 << 20 {
            var scratch = av_packet_alloc()
            defer { av_packet_free(&scratch) }
            if let scan = scratch {
                let scanBase = av_q2d(videoStream.pointee.time_base)
                while true {
                    if input.isCancelled || isClosed { throw RemuxError.closed }
                    if av_read_frame(ic, scan) < 0 { break }
                    if Int(scan.pointee.stream_index) == videoIndex, scan.pointee.pts != ffNoPTS {
                        let end = Double(scan.pointee.pts + max(scan.pointee.duration, 0)) * scanBase
                        if end > scannedDuration { scannedDuration = end }
                    }
                    av_packet_unref(scan)
                }
            }
            _ = av_seek_frame(ic, Int32(videoIndex), 0, ffSeekBackward)
            entryCount = Int(avformat_index_get_entries_count(videoStream))
            note("lettura completa: \(entryCount) fotogrammi chiave, \(Int(scannedDuration)) s")
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
        // The declared length can be nonsense (5 s for a file whose index runs for an hour): the real end is read from the last pieces.
        if let last = keyframes.last, duration < last.time + 1 {
            var end = last.time + 10
            if av_seek_frame(ic, Int32(videoIndex), last.timestamp, ffSeekBackward) >= 0 {
                var tailPacket = av_packet_alloc()
                defer { av_packet_free(&tailPacket) }
                if let tail = tailPacket {
                    while !(input.isCancelled || isClosed), av_read_frame(ic, tail) >= 0 {
                        if Int(tail.pointee.stream_index) == videoIndex, tail.pointee.pts != ffNoPTS {
                            let finish = Double(tail.pointee.pts + max(tail.pointee.duration, 0)) * timeBase
                            if finish > end { end = finish }
                        }
                        av_packet_unref(tail)
                    }
                }
            }
            note("durata dichiarata \(Int(duration)) s, reale \(Int(end)) s")
            duration = end
        }
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
        // The profile says what the bit depth field may not: High 10, 4:2:2 and 4:4:4 H.264 cannot be decoded by iOS at all.
        if kind == .video, par.pointee.codec_id == AV_CODEC_ID_H264, [110, 122, 244, 44].contains(Int(par.pointee.profile)) {
            depth = max(depth ?? 0, 10)
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

    // MARK: MP4 sample entries

    private func trackScale(_ par: UnsafeMutablePointer<AVCodecParameters>, isVideo: Bool) -> UInt32 {
        if isVideo { return 90000 }
        return par.pointee.sample_rate > 0 ? UInt32(par.pointee.sample_rate) : 48000
    }

    /// Samples in one audio frame, which is the length of every audio sample in the pieces.
    private func audioFrameSamples(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Int64 {
        switch par.pointee.codec_id {
        case AV_CODEC_ID_AAC: return par.pointee.frame_size > 0 ? Int64(par.pointee.frame_size) : 1024
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: return 1536
        case AV_CODEC_ID_MP3: return par.pointee.sample_rate < 32000 ? 576 : 1152
        default: return par.pointee.frame_size > 0 ? Int64(par.pointee.frame_size) : 1024
        }
    }

    private func videoEntry(_ par: UnsafeMutablePointer<AVCodecParameters>) -> Data? {
        let fourcc: String
        let config: String
        switch par.pointee.codec_id {
        case AV_CODEC_ID_H264: fourcc = "avc1"; config = "avcC"
        case AV_CODEC_ID_HEVC: fourcc = "hvc1"; config = "hvcC"
        default: return nil
        }
        let extra = bytes(of: par)
        guard !extra.isEmpty else { return nil }
        var body = Data(count: 6)
        body.append(MP4Writer.u16(1))
        body.append(Data(count: 16))
        body.append(MP4Writer.u16(Int(par.pointee.width)))
        body.append(MP4Writer.u16(Int(par.pointee.height)))
        body.append(MP4Writer.u32(0x00480000))
        body.append(MP4Writer.u32(0x00480000))
        body.append(MP4Writer.u32(0))
        body.append(MP4Writer.u16(1))
        body.append(Data(count: 32))
        body.append(MP4Writer.u16(0x0018))
        body.append(MP4Writer.u16(0xFFFF))
        body.append(MP4Writer.box(config, Data(extra)))
        body.append(MP4Writer.box("pasp", MP4Writer.u32(1) + MP4Writer.u32(1)))
        let primaries = Int(par.pointee.color_primaries.rawValue)
        let transfer = Int(par.pointee.color_trc.rawValue)
        let matrix = Int(par.pointee.color_space.rawValue)
        // Only HDR carries its colour description (PQ or HLG); an SDR file is read as BT.709 without it, and a half-filled or odd
        // description made AVFoundation drop the whole video track.
        if (transfer == 16 || transfer == 18) && primaries == 9 && (matrix == 9 || matrix == 10) {
            var colr = Data("nclx".utf8)
            colr.append(MP4Writer.u16(primaries))
            colr.append(MP4Writer.u16(transfer))
            colr.append(MP4Writer.u16(matrix))
            colr.append(par.pointee.color_range == AVCOL_RANGE_JPEG ? UInt8(0x80) : UInt8(0x00))
            body.append(MP4Writer.box("colr", colr))
        }
        return MP4Writer.box(fourcc, body)
    }

    private func audioEntry(_ par: UnsafeMutablePointer<AVCodecParameters>, trackID: Int, firstPacket: Data?) -> Data? {
        let channels = max(1, Int(par.pointee.ch_layout.nb_channels))
        let rate = par.pointee.sample_rate > 0 ? Int(par.pointee.sample_rate) : 48000
        var body = Data(count: 6)
        body.append(MP4Writer.u16(1))
        body.append(Data(count: 8))
        body.append(MP4Writer.u16(channels))
        body.append(MP4Writer.u16(16))
        body.append(MP4Writer.u16(0))
        body.append(MP4Writer.u16(0))
        body.append(MP4Writer.u32(UInt32(min(rate, 65535)) << 16))
        switch par.pointee.codec_id {
        case AV_CODEC_ID_AAC:
            body.append(AudioConfigBoxes.esds(objectType: 0x40, config: bytes(of: par), trackID: trackID))
            return MP4Writer.box("mp4a", body)
        case AV_CODEC_ID_MP3:
            body.append(AudioConfigBoxes.esds(objectType: 0x6B, config: [], trackID: trackID))
            return MP4Writer.box("mp4a", body)
        case AV_CODEC_ID_AC3:
            guard let packet = firstPacket, let box = AudioConfigBoxes.dac3(packet) else { return nil }
            body.append(box)
            return MP4Writer.box("ac-3", body)
        case AV_CODEC_ID_EAC3:
            guard let packet = firstPacket, let box = AudioConfigBoxes.dec3(packet) else { return nil }
            body.append(box)
            return MP4Writer.box("ec-3", body)
        default:
            return nil
        }
    }

    // MARK: Making a piece

    /// Muxes one segment. Also keeps the init segment (the part of the output before the first fragment) and the first fragment.
    @discardableResult
    /// An FFmpeg error with a line in the log saying where it happened (the code alone says nothing).
    private func fail(_ what: String, _ code: Int32) -> RemuxError {
        note("pezzo: errore \(code) in \(what)")
        return ffError(code)
    }

    private func produce(segment index: Int) throws -> Data {
        guard let ic = context, let layout = layout else { throw RemuxError.closed }
        guard index >= 0, index < layout.segments.count else { throw RemuxError.segmentOutOfRange(index) }
        let span = layout.segments[index]
        let isLast = index == layout.segments.count - 1

        let copiedInputs = Set(layout.copied)
        // Read the packets of this piece.
        guard let videoStream = ic.pointee.streams[layout.videoIndex] else { throw RemuxError.unreadable }
        var status = av_seek_frame(ic, Int32(layout.videoIndex), layout.startTimestamps[index], ffSeekBackward)
        if status < 0 { throw fail("posizionamento", status) }
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
                throw fail("lettura", result)
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



        // The samples of every track, in its own time scale (video 90 kHz, audio its sample rate).
        let videoBase = av_q2d(videoStream.pointee.time_base)
        let sortedPTS = kept.filter { Int($0.pointee.stream_index) == layout.videoIndex }.map { $0.pointee.pts }.sorted()
        // How far a frame's decode time can be after its presentation time (frame reordering): the file says it in `video_delay`, but
        // when it does not, the first piece shows it. Presentation times are moved later by that much, for every piece, so a frame is
        // never shown before it is decoded.
        var shiftSeconds = layout.shiftSeconds
        var reorder = 0.0
        for (position, frame) in kept.filter({ Int($0.pointee.stream_index) == layout.videoIndex && $0.pointee.pts != ffNoPTS }).enumerated()
        where position < sortedPTS.count {
            reorder = max(reorder, Double(sortedPTS[position] - frame.pointee.pts) * videoBase)
        }
        if reorder > shiftSeconds + 1e-6 {
            shiftSeconds = (reorder * 1000).rounded(.up) / 1000
            if index == 0 { self.layout?.shiftSeconds = shiftSeconds }
            note("riordino dei fotogrammi: \(Int(reorder * 1000)) ms (il file dichiarava \(Int(layout.shiftSeconds * 1000)) ms)")
        }
        let shiftTicks = Int64((shiftSeconds / videoBase).rounded())
        var videoOrdinal = 0
        var previousDTS = ffNoPTS
        var starts: [Int: [Int64]] = [:]
        var offsets: [Int: [Int64]] = [:]
        var payloads: [Int: [Data]] = [:]
        var syncs: [Int: [Bool]] = [:]
        var lastHint: [Int: Int64] = [:]
        var firstPacket: [Int: Data] = [:]
        for item in kept {
            let inputIndex = Int(item.pointee.stream_index)
            guard muxedInputs.contains(inputIndex), let source = ic.pointee.streams[inputIndex], let par = source.pointee.codecpar,
                  let raw = item.pointee.data, item.pointee.size > 0 else { continue }
            let base = av_q2d(source.pointee.time_base)
            let isVideo = inputIndex == layout.videoIndex
            let scale = Double(trackScale(par, isVideo: isVideo))
            let data = Data(bytes: raw, count: Int(item.pointee.size))
            var start: Int64
            var offset: Int64 = 0
            var hint: Int64
            if isVideo {
                var dts = sortedPTS[videoOrdinal]
                videoOrdinal += 1
                if dts - item.pointee.pts > shiftTicks { dts = item.pointee.pts + shiftTicks }
                if previousDTS != ffNoPTS && dts <= previousDTS { dts = previousDTS + 1 }
                previousDTS = dts
                let presentation = item.pointee.pts + shiftTicks
                start = Int64((Double(dts) * base * scale).rounded())
                offset = max(0, Int64((Double(presentation) * base * scale).rounded()) - start)
                hint = Int64((Double(max(item.pointee.duration, 0)) * base * scale).rounded())
            } else {
                let ticks = Int64((shiftSeconds / base).rounded())
                let presentation = (item.pointee.pts == ffNoPTS ? item.pointee.dts : item.pointee.pts) + ticks
                start = Int64((Double(presentation) * base * scale).rounded())
                hint = audioFrameSamples(par)
                if firstPacket[inputIndex] == nil { firstPacket[inputIndex] = data }
            }
            starts[inputIndex, default: []].append(start)
            offsets[inputIndex, default: []].append(offset)
            payloads[inputIndex, default: []].append(data)
            syncs[inputIndex, default: []].append(isVideo ? (item.pointee.flags & ffKeyFlag != 0) : true)
            lastHint[inputIndex] = hint
        }

        if index == 0 && initData == nil {
            var tracks: [MP4Writer.Track] = []
            for (position, input) in layout.copied.enumerated() {
                guard let source = ic.pointee.streams[input], let par = source.pointee.codecpar else { throw RemuxError.unreadable }
                if input == layout.videoIndex {
                    guard let entry = videoEntry(par) else { throw RemuxError.unreadable }
                    tracks.append(MP4Writer.Track(id: UInt32(position + 1), kind: .video, timescale: trackScale(par, isVideo: true),
                                                  width: Int(par.pointee.width), height: Int(par.pointee.height), entry: entry))
                } else {
                    guard let entry = audioEntry(par, trackID: position + 1, firstPacket: firstPacket[input]) else {
                        note("audio: configurazione non ricavabile per il codec \(String(cString: avcodec_get_name(par.pointee.codec_id)))")
                        throw RemuxError.unreadable
                    }
                    tracks.append(MP4Writer.Track(id: UInt32(position + 1), kind: .audio, timescale: trackScale(par, isVideo: false),
                                                  width: 0, height: 0, entry: entry))
                }
            }
            initData = MP4Writer.initSegment(tracks)
            let names = layout.copied.compactMap { input -> String? in
                guard let source = ic.pointee.streams[input], let par = source.pointee.codecpar else { return nil }
                return String(cString: avcodec_get_name(par.pointee.codec_id))
            }
            note("flussi copiati: \(names.joined(separator: ", ")); init \(initData?.count ?? 0) byte")
        }

        var runs: [MP4Writer.Run] = []
        for (position, input) in layout.copied.enumerated() {
            guard let s = starts[input], !s.isEmpty, let data = payloads[input], let flags = syncs[input], let shifts = offsets[input],
                  let source = ic.pointee.streams[input], let par = source.pointee.codecpar else { continue }
            let isVideo = input == layout.videoIndex
            var samples: [MP4Writer.Sample] = []
            for i in 0..<s.count {
                var duration: Int64
                if isVideo {
                    if i + 1 < s.count {
                        duration = s[i + 1] - s[i]
                    } else {
                        let last = lastHint[input] ?? 0
                        duration = last > 0 ? last : (samples.last.map { Int64($0.duration) } ?? 3750)
                    }
                } else {
                    duration = audioFrameSamples(par)
                }
                duration = max(1, duration)
                samples.append(MP4Writer.Sample(data: data[i], duration: UInt32(truncatingIfNeeded: duration), sync: flags[i],
                                                offset: Int32(truncatingIfNeeded: shifts[i])))
            }
            runs.append(MP4Writer.Run(trackID: UInt32(position + 1), baseDecodeTime: UInt64(max(0, s[0])), samples: samples))
        }
        guard !runs.isEmpty else { throw RemuxError.unreadable }
        let fragment = MP4Writer.fragment(sequence: index + 1, runs: runs)
        if index == 0, let video = runs.first(where: { $0.trackID == 1 }) {
            let head = video.samples.prefix(6).map { "\($0.duration)/\($0.offset)/\($0.sync ? "K" : "-")" }.joined(separator: " ")
            note("video: ritardo \(videoStream.pointee.codecpar?.pointee.video_delay ?? -1), spostamento \(Int(shiftSeconds * 1000)) ms, primi campioni (durata/offset/chiave) \(head)")
        }
        if index == 0 {
            let summary = runs.map { "traccia \($0.trackID): \($0.samples.count) campioni da \($0.baseDecodeTime)" }.joined(separator: "; ")
            note("pezzo 0: \(summary), \(fragment.count) byte")
        }
        if index == 0 { firstFragment = fragment }
        return fragment

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
