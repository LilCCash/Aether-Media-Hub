import Foundation
import AetherCore

#if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil) && canImport(Libswscale) && canImport(Libswresample)
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
        /// Full conversion: how the picture is encoded again (nil when it is copied).
        var video: VideoEncoderSettings? = nil
        /// Full conversion: the sound is encoded again as AAC.
        var audioTranscoded = false
        /// Text subtitle tracks: input stream index → codec name.
        var textSubtitles: [Int: String] = [:]
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
    private var prepared: RemuxPrepared?
    /// The parameter sets the encoder wrote for each piece (full conversion): every piece must use those of the init segment.
    private(set) var encodedVideoConfigs: [Int: [UInt8]] = [:]

    private let stateLock = NSLock()
    private var closed = false
    /// The init segment once made, also readable off the queue (under `stateLock`): the player asks for it again at times, and it
    /// must not wait behind a piece being encoded (the system player gives up after 4 s).
    private var readyInit: Data?

    private let audioChoice: RemuxAudioChoice
    private let full: Bool

    // Only touched on `queue`: the subtitle cues found while making each piece (piece → track → cues), the pieces whose cues are
    // known, pieces made for a subtitle request before the player asked for them, and the end of the sound of the last piece made
    // (the start of the next one's encoder warm-up).
    private var cues: [Int: [Int: [WebVTTWriter.Cue]]] = [:]
    private var scanned = Set<Int>()
    private var stashed: [Int: Data] = [:]
    /// The last piece the player asked for: a piece made ahead is only the one after it (after a seek, the old one is skipped).
    private var lastRequested = 0
    private var audioCarry: (index: Int, packets: [UnsafeMutablePointer<AVPacket>])?

    init(fetcher: RelayRangeFetcher, totalBytes: Int64, minimumSegment: Double = 6, audio: RemuxAudioChoice = .standard, full: Bool = false) {
        self.input = RangeInput(fetcher: fetcher, total: totalBytes)
        self.totalBytes = totalBytes
        // Re-encoded pieces take longer to make: shorter ones keep the start and the seeks quick.
        self.minimumSegment = full ? min(minimumSegment, 4) : minimumSegment
        self.audioChoice = audio
        self.full = full
    }

    deinit {
        releaseResources()
    }

    // MARK: RemuxEngine

    func prepare() async throws -> RemuxPrepared {
        let made: RemuxPrepared = try await run {
            // Asked again: the file is already open and planned.
            if let done = self.prepared { return done }
            let made = try self.prepareOnQueue()
            self.prepared = made
            return made
        }
        warmFirstPiece()
        return made
    }

    /// Full conversion: the first piece (and with it the init segment) is encoded as soon as the file is planned, before the
    /// player asks for it. The system player waits only 4 s for the init segment; encoding started at its request could take
    /// longer (a slow phone, the simulator), and playback then did not start at all.
    private func warmFirstPiece() {
        guard full else { return }
        queue.async {
            guard !self.isClosed, self.layout != nil, self.initData == nil else { return }
            _ = try? self.produce(segment: 0)
        }
    }

    func initSegment() async throws -> Data {
        stateLock.lock()
        let ready = readyInit
        stateLock.unlock()
        if let ready, !isClosed { return ready }
        let data: Data = try await run {
            if let data = self.initData { return data }
            _ = try self.produce(segment: 0)
            guard let data = self.initData else { throw RemuxError.unreadable }
            return data
        }
        prefetch(1)
        return data
    }

    func mediaSegment(_ index: Int) async throws -> Data {
        let data: Data = try await run {
            self.lastRequested = index
            if index == 0, let cached = self.firstFragment { return cached }
            if let ready = self.stashed.removeValue(forKey: index) { return ready }
            return try self.produce(segment: index)
        }
        prefetch(index + 1)
        return data
    }

    /// Full conversion: the next piece is encoded while the player plays this one, so it is ready (or nearly) when asked for. A piece
    /// that takes longer than the player waits would otherwise stop playback. Copied pieces are quick and are made on demand.
    private func prefetch(_ index: Int) {
        guard full else { return }
        queue.async {
            guard !self.isClosed, let layout = self.layout, index > 0, index < layout.segments.count,
                  self.stashed[index] == nil, self.lastRequested == index - 1 else { return }
            guard let fragment = try? self.produce(segment: index) else { return }
            self.keep(fragment, for: index)
        }
    }

    /// A piece made before the player asked for it (only on `queue`).
    private func keep(_ fragment: Data, for index: Int) {
        if stashed.count >= 4, let oldest = stashed.keys.min() { stashed.removeValue(forKey: oldest) }
        stashed[index] = fragment
    }

    func subtitleSegment(track: Int, index: Int) async throws -> Data {
        return try await run {
            guard let layout = self.layout, layout.textSubtitles[track] != nil, index >= 0, index < layout.segments.count else {
                return Data(WebVTTWriter.document([]).utf8)
            }
            if !self.scanned.contains(index) {
                // The cues are found while the piece is read: the piece is made now and kept for when the player asks for it.
                do {
                    let fragment = try self.produce(segment: index)
                    if index != 0 { self.keep(fragment, for: index) }
                } catch RemuxError.closed {
                    throw RemuxError.closed
                } catch {
                    // A piece that cannot be made has no subtitles either; an empty one keeps the player going.
                    return Data(WebVTTWriter.document([]).utf8)
                }
            }
            return Data(WebVTTWriter.document(self.cues[index]?[track] ?? []).utf8)
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
        switch RemuxPlanner.plan(infos, audio: audioChoice, full: full) {
        case .success(let decided): plan = decided
        case .failure(let refusal): throw RemuxError.refused(refusal)
        }
        let videoIndex = plan.video.index
        guard let videoStream = ic.pointee.streams[videoIndex], let videoPar = videoStream.pointee.codecpar else { throw RemuxError.unreadable }

        // Keyframes: Matroska loads its Cues index on the first seek.
        _ = av_seek_frame(ic, Int32(videoIndex), 0, ffSeekBackward)
        let entryCount = Int(avformat_index_get_entries_count(videoStream))
        let timeBase = av_q2d(videoStream.pointee.time_base)
        var keyframes: [(timestamp: Int64, time: Double)] = []
        for entryIndex in 0..<max(0, entryCount) {
            guard let entry = avformat_index_get_entry(videoStream, Int32(entryIndex)), entry.pointee.flags & ffIndexKeyframe != 0 else { continue }
            keyframes.append((entry.pointee.timestamp, Double(entry.pointee.timestamp) * timeBase))
        }
        keyframes.sort { $0.time < $1.time }
        var duration = ic.pointee.duration > 0 ? Double(ic.pointee.duration) / 1_000_000.0 : 0
        if duration <= 0, let last = keyframes.last { duration = last.time + 10 }
        guard duration > 0 else { throw RemuxError.unreadable }
        let spans = SegmentPlanner.plan(keyframes: keyframes.map { $0.time }, duration: duration, minimum: minimumSegment)
        guard !spans.isEmpty, keyframes.count >= 2 || duration < 30 else { throw RemuxError.noKeyframeIndex }
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
        var shift = delay > 0 ? Double(delay + 1) * frameDuration : 0

        // Full conversion: the encoder is tried once now, so a phone that cannot encode says so before anything plays.
        var encoderSettings: VideoEncoderSettings?
        var videoString: String?
        if plan.videoTranscoded {
            let settings = VideoEncoderSettings.choose(for: videoPar, stream: videoStream, bitDepth: plan.video.bitDepth)
            guard let text = FFmpegCodecs.codecString(settings: settings) else { throw RemuxError.encoderUnavailable }
            encoderSettings = settings
            videoString = text
            // The new pictures have no reordering, so nothing needs to be moved later.
            shift = 0
        }

        var copied = [videoIndex]
        copied.append(contentsOf: plan.audio.map { $0.index })
        var subtitleCodecs: [Int: String] = [:]
        for track in plan.textSubtitles { subtitleCodecs[track.index] = track.codec }
        layout = Layout(videoIndex: videoIndex, copied: copied, plan: plan, segments: spans, startTimestamps: starts, shiftSeconds: shift,
                        video: encoderSettings, audioTranscoded: plan.audioTranscoded, textSubtitles: subtitleCodecs)

        let videoCodec = plan.video.codec.lowercased()
        let extradata = bytes(of: videoPar)
        if videoString == nil {
            if videoCodec == "h264" {
                videoString = CodecStrings.avc1(avcC: extradata) ?? "avc1.640028"
            } else {
                videoString = CodecStrings.hvc1(hvcC: extradata) ?? "hvc1.1.6.L120.90"
            }
        }
        var codecs = [videoString ?? "avc1.640028"]
        if plan.audioTranscoded, !plan.audio.isEmpty {
            codecs.append("mp4a.40.2")
        }
        for track in plan.audio where !plan.audioTranscoded {
            guard let stream = ic.pointee.streams[track.index], let par = stream.pointee.codecpar else { continue }
            var objectType: Int?
            if track.codec.lowercased() == "aac" {
                let config = bytes(of: par)
                if let first = config.first { objectType = Int(first >> 3) }
            }
            if let text = CodecStrings.audio(codec: track.codec, aacObjectType: objectType), !codecs.contains(text) { codecs.append(text) }
        }
        var averageBandwidth = Int(Double(totalBytes) * 8.0 / duration)
        if let settings = encoderSettings { averageBandwidth = Int(settings.bitRate) + 500_000 }
        var range = HLSVideoRange.sdr
        if videoPar.pointee.color_trc == AVCOL_TRC_SMPTE2084 { range = .pq }
        if videoPar.pointee.color_trc == AVCOL_TRC_ARIB_STD_B67 { range = .hlg }
        let master = HLSMasterInfo(bandwidth: Int(Double(averageBandwidth) * 1.25), averageBandwidth: averageBandwidth,
                                   width: Int(encoderSettings?.width ?? videoPar.pointee.width),
                                   height: Int(encoderSettings?.height ?? videoPar.pointee.height),
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
        if par.pointee.bits_per_raw_sample > 0 {
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
        let transcodeVideo = layout.video != nil
        let transcodeAudio = layout.audioTranscoded
        // Re-encoded sound is read a little past the end of the piece: the AAC frame that straddles the end is made by this piece.
        let audioTail = transcodeAudio ? 0.25 : 0
        // Re-encoded picture: the pictures shown before the next keyframe but stored after it (open GOP) belong to this piece.
        var leadingDone = !transcodeVideo
        var pieceCues: [Int: [WebVTTWriter.Cue]] = [:]
        let collectCues = !layout.textSubtitles.isEmpty && !scanned.contains(index)
        while true {
            if input.isCancelled || isClosed { throw RemuxError.closed }
            let result = av_read_frame(ic, packet)
            if result < 0 {
                if result == ffEOF { break }
                throw ffError(result)
            }
            defer { av_packet_unref(packet) }
            let inputIndex = Int(packet.pointee.stream_index)
            if collectCues, let codec = layout.textSubtitles[inputIndex], let stream = ic.pointee.streams[inputIndex] {
                collectCue(packet, codec: codec, stream: stream, span: span, isFirst: index == 0, isLast: isLast, shift: layout.shiftSeconds,
                           into: &pieceCues[inputIndex, default: []])
                continue
            }
            guard copiedInputs.contains(inputIndex), let stream = ic.pointee.streams[inputIndex] else { continue }
            guard packet.pointee.pts != ffNoPTS || packet.pointee.dts != ffNoPTS else { continue }
            let seconds = Double(packet.pointee.pts != ffNoPTS ? packet.pointee.pts : packet.pointee.dts) * av_q2d(stream.pointee.time_base)
            var keep = true
            if inputIndex == layout.videoIndex {
                if packet.pointee.pts == ffNoPTS && !transcodeVideo { continue }
                let isKey = packet.pointee.flags & ffKeyFlag != 0
                if !videoDone && !isLast && isKey && seconds >= span.end - 1e-6 {
                    videoDone = true
                    if transcodeVideo {
                        // The keyframe itself is only decoded, as the reference of the pictures after it.
                        if let copy = av_packet_clone(packet) { kept.append(copy) }
                        continue
                    }
                }
                if videoDone {
                    keep = false
                    if !leadingDone {
                        if !isKey && seconds < span.end - 1e-6 { keep = true } else { leadingDone = true }
                    }
                }
            } else if transcodeAudio {
                if !isLast && seconds >= span.end + audioTail { audioDone.insert(inputIndex) }
                if !isLast && seconds >= span.end + audioTail { keep = false }
            } else {
                if !isLast && seconds >= span.end - 1e-6 { audioDone.insert(inputIndex) }
                if (!isLast && seconds >= span.end - 1e-6) || seconds < span.start - 1e-6 { keep = false }
            }
            if keep, let copy = av_packet_clone(packet) { kept.append(copy) }
            if videoDone && leadingDone {
                // An audio track that ends early would otherwise make this read the rest of the file.
                packetsAfterVideoEnded += 1
                if audioInputs.allSatisfy({ audioDone.contains($0) }) || packetsAfterVideoEnded > 3000 { break }
            }
        }
        guard !kept.isEmpty else { throw RemuxError.unreadable }

        // Full conversion: the tracks made again.
        var encodedVideo: EncodedTrack?
        var encodedAudio: EncodedTrack?
        let audioInput = layout.plan.audio.first?.index
        if let settings = layout.video {
            let packets = kept.filter { Int($0.pointee.stream_index) == layout.videoIndex }
            encodedVideo = try VideoSegmentTranscoder.transcode(packets: packets, stream: videoStream, settings: settings,
                                                               start: span.start, end: span.end, isLast: isLast,
                                                               cancelled: { self.input.isCancelled || self.isClosed })
            if let par = encodedVideo?.parameters, let data = par.pointee.extradata, par.pointee.extradata_size > 0 {
                encodedVideoConfigs[index] = Array(UnsafeBufferPointer(start: data, count: Int(par.pointee.extradata_size)))
            }
        }
        if transcodeAudio, let audioIndex = audioInput, let audioStream = ic.pointee.streams[audioIndex] {
            var packets = kept.filter { Int($0.pointee.stream_index) == audioIndex }
            // The end of the previous piece's sound warms the encoder up, so the two pieces join without a click.
            if let carry = audioCarry, carry.index == index {
                let firstPTS = packets.first?.pointee.pts ?? Int64.max
                packets = carry.packets.filter { $0.pointee.pts < firstPTS } + packets
            }
            let made = try AudioSegmentTranscoder.transcode(packets: packets, stream: audioStream, start: span.start, end: span.end,
                                                            isLast: isLast, cancelled: { self.input.isCancelled || self.isClosed })
            if !made.packets.isEmpty { encodedAudio = made }
            // What the next piece needs: this piece's last third of a second of sound.
            let base = av_q2d(audioStream.pointee.time_base)
            let tail = kept.filter { item in
                Int(item.pointee.stream_index) == audioIndex && item.pointee.pts != ffNoPTS
                    && Double(item.pointee.pts) * base >= span.end - 0.35 && Double(item.pointee.pts) * base < span.end
            }.compactMap { av_packet_clone($0) }
            releaseCarry()
            if isLast {
                for var leftover in tail.map({ Optional($0) }) { av_packet_free(&leftover) }
            } else {
                audioCarry = (index + 1, tail)
            }
        }
        var transcodedInputs = Set<Int>()
        if encodedVideo != nil { transcodedInputs.insert(layout.videoIndex) }
        if transcodeAudio, let audioIndex = audioInput { transcodedInputs.insert(audioIndex) }

        // The tracks this piece has samples for. A track with none (an audio track that ended before the picture did) is left out of
        // this piece's muxer: declaring it would stop the muxer from writing the fragment. The first piece makes the init segment, which
        // must have every track, so it is never allowed to be missing one.
        var present = Set(kept.map { Int($0.pointee.stream_index) }).subtracting(transcodedInputs)
        if encodedVideo != nil { present.insert(layout.videoIndex) }
        if encodedAudio != nil, let audioIndex = audioInput { present.insert(audioIndex) }
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

        func encoded(_ inputIndex: Int) -> EncodedTrack? {
            if inputIndex == layout.videoIndex { return encodedVideo }
            if inputIndex == audioInput { return encodedAudio }
            return nil
        }
        for inputIndex in muxedInputs {
            guard let source = ic.pointee.streams[inputIndex], let sourcePar = source.pointee.codecpar,
                  let target = avformat_new_stream(oc, nil), let targetPar = target.pointee.codecpar else { throw RemuxError.unreadable }
            if let made = encoded(inputIndex) {
                // A track made again: the encoder's parameters, in the encoder's time base.
                guard let madePar = made.parameters else { throw RemuxError.unreadable }
                status = avcodec_parameters_copy(targetPar, madePar)
                if status < 0 { throw ffError(status) }
                if targetPar.pointee.codec_id == AV_CODEC_ID_HEVC { targetPar.pointee.codec_tag = ffTag("hvc1") } else { targetPar.pointee.codec_tag = 0 }
                if targetPar.pointee.codec_type == AVMEDIA_TYPE_VIDEO { target.pointee.sample_aspect_ratio = targetPar.pointee.sample_aspect_ratio }
                target.pointee.time_base = made.timeBase
                if let language = av_dict_get(source.pointee.metadata, "language", nil, 0) {
                    av_dict_set(&target.pointee.metadata, "language", language.pointee.value, 0)
                }
                continue
            }
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
        let sortedPTS = transcodedInputs.contains(layout.videoIndex) ? []
            : kept.filter { Int($0.pointee.stream_index) == layout.videoIndex }.map { $0.pointee.pts }.sorted()
        var videoOrdinal = 0
        var previousDTS = ffNoPTS
        var firstDecodeTimes: [Int: Int64] = [:]
        for item in kept {
            let inputIndex = Int(item.pointee.stream_index)
            if transcodedInputs.contains(inputIndex) { continue }
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
        // The tracks made again: their times are the film's (plus the same shift), in the encoder's time base.
        for inputIndex in muxedInputs {
            guard let made = encoded(inputIndex), let outputIndex = outputIndexOf[inputIndex], let target = oc.pointee.streams[outputIndex] else { continue }
            let ticks = Int64((layout.shiftSeconds / av_q2d(made.timeBase)).rounded())
            for item in made.packets {
                item.pointee.pts += ticks
                item.pointee.dts = inputIndex == layout.videoIndex ? item.pointee.dts + ticks : item.pointee.pts
                item.pointee.stream_index = Int32(outputIndex)
                av_packet_rescale_ts(item, made.timeBase, target.pointee.time_base)
                if let known = firstDecodeTimes[outputIndex] {
                    if item.pointee.dts < known { firstDecodeTimes[outputIndex] = item.pointee.dts }
                } else {
                    firstDecodeTimes[outputIndex] = item.pointee.dts
                }
                // The muxer takes the packet's data over: a reference is handed to it, the track keeps its own.
                guard let handed = av_packet_clone(item) else { throw RemuxError.unreadable }
                var handedOptional: UnsafeMutablePointer<AVPacket>? = handed
                status = av_interleaved_write_frame(oc, handed)
                av_packet_free(&handedOptional)
                if status < 0 { throw ffError(status) }
            }
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
        if index == 0 && initData == nil {
            initData = parts.initPart
            stateLock.lock()
            readyInit = parts.initPart
            stateLock.unlock()
        }
        if index == 0 { firstFragment = parts.fragment }
        if collectCues {
            cues[index] = pieceCues
            scanned.insert(index)
        }
        return parts.fragment
    }

    /// One subtitle event of the piece, as a cue on the video's timeline. An event belongs to the piece it starts in.
    private func collectCue(_ packet: UnsafeMutablePointer<AVPacket>, codec: String, stream: UnsafeMutablePointer<AVStream>, span: RemuxSegmentSpan,
                            isFirst: Bool, isLast: Bool, shift: Double, into list: inout [WebVTTWriter.Cue]) {
        let stamp = packet.pointee.pts != ffNoPTS ? packet.pointee.pts : packet.pointee.dts
        guard stamp != ffNoPTS else { return }
        let base = av_q2d(stream.pointee.time_base)
        let start = Double(stamp) * base
        if start < span.start - 1e-6 && !isFirst { return }
        if start >= span.end - 1e-6 && !isLast { return }
        var length = Double(packet.pointee.duration) * base
        if !(length > 0) { length = 4 }
        guard let text = SubtitleTextReader.text(of: packet, codec: codec), !text.isEmpty else { return }
        list.append(WebVTTWriter.Cue(start: start + shift, end: start + length + shift, text: text))
    }

    private func releaseCarry() {
        guard let carry = audioCarry else { return }
        for var leftover in carry.packets.map({ Optional($0) }) { av_packet_free(&leftover) }
        audioCarry = nil
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
        stateLock.lock()
        readyInit = nil
        stateLock.unlock()
        firstFragment = nil
        stashed.removeAll()
        releaseCarry()
    }
}

#endif
