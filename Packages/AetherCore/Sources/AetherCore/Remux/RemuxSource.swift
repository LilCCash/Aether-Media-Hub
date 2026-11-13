import Foundation

/// Serves a file the system player cannot read (MKV) as HLS with fragmented MP4 pieces:
/// `index.m3u8` (master), `media.m3u8`, `init.mp4` and `seg-<n>.m4s`. The pieces are made on demand by a `RemuxEngine` and the last few
/// are kept in memory.
public final class RemuxSource: RelaySource, @unchecked Sendable {
    public enum Leaf: Equatable, Sendable {
        case master, media, initSegment
        case segment(Int)
        /// `subs-<track>.m3u8`: the playlist of one text subtitle track (its stream index in the file).
        case subtitlePlaylist(Int)
        /// `sub-<track>-<segment>.vtt`
        case subtitleSegment(track: Int, segment: Int)

        public static let masterName = "index.m3u8"
        public static let mediaName = "media.m3u8"
        public static let initName = "init.mp4"

        public static func parse(_ name: String) -> Leaf? {
            switch name {
            case masterName: return .master
            case mediaName: return .media
            case initName: return .initSegment
            default:
                if name.hasPrefix("subs-"), name.hasSuffix(".m3u8") {
                    guard let track = number(name.dropFirst(5).dropLast(5)) else { return nil }
                    return .subtitlePlaylist(track)
                }
                if name.hasPrefix("sub-"), name.hasSuffix(".vtt") {
                    let parts = name.dropFirst(4).dropLast(4).split(separator: "-", omittingEmptySubsequences: false)
                    guard parts.count == 2, let track = number(parts[0]), let segment = number(parts[1]) else { return nil }
                    return .subtitleSegment(track: track, segment: segment)
                }
                guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return nil }
                let digits = name.dropFirst(4).dropLast(4)
                guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      digits == "0" || digits.first != "0", let index = Int(digits) else { return nil }
                return .segment(index)
            }
        }

        /// A short run of digits without a leading zero.
        static func number<S: StringProtocol>(_ digits: S) -> Int? {
            guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  digits == "0" || digits.first != "0" else { return nil }
            return Int(digits)
        }

        var contentType: String {
            switch self {
            case .master, .media, .subtitlePlaylist: return "application/vnd.apple.mpegurl"
            case .initSegment, .segment: return "video/mp4"
            case .subtitleSegment: return "text/vtt"
            }
        }

        var key: String {
            switch self {
            case .master: return Leaf.masterName
            case .media: return Leaf.mediaName
            case .initSegment: return Leaf.initName
            case .segment(let index): return "seg-\(index).m4s"
            case .subtitlePlaylist(let track): return "subs-\(track).m3u8"
            case .subtitleSegment(let track, let segment): return "sub-\(track)-\(segment).vtt"
            }
        }
    }

    private enum Lookup {
        case hit(Data)
        case pending(Task<Data, Error>)
    }

    private let engine: RemuxEngine
    private let defaultSubtitleLanguage: String?
    private let defaultSubtitleTitle: String?
    private let maxCacheBytes: Int
    private let lock = NSLock()
    private var preparedInfo: RemuxPrepared?
    private var masterText = Data()
    private var mediaText = Data()
    private var subtitlePlaylists: [Int: Data] = [:]
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var cachedBytes = 0
    private var inflight: [String: Task<Data, Error>] = [:]
    private var closed = false

    public init(engine: RemuxEngine, maxCacheBytes: Int = 160 << 20, defaultSubtitleLanguage: String? = nil, defaultSubtitleTitle: String? = nil) {
        self.engine = engine
        self.maxCacheBytes = maxCacheBytes
        self.defaultSubtitleLanguage = defaultSubtitleLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.defaultSubtitleTitle = defaultSubtitleTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var prepared: RemuxPrepared? { return locked { preparedInfo } }

    /// Opens the file and builds the playlists. Throws `RemuxError` (a refusal carries the reason to show the viewer).
    @discardableResult
    public func prepare() async throws -> RemuxPrepared {
        let info = try await engine.prepare()
        guard !info.segments.isEmpty else { throw RemuxError.noKeyframeIndex }
        let renditions = info.plan.textSubtitles.map { track -> HLSSubtitleRendition in
            let language = track.language.map { LanguageCodes.displayName($0) }
            let name = [language, track.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return HLSSubtitleRendition(name: name.isEmpty ? "Sottotitoli \(track.index)" : name,
                                        language: track.language.flatMap { RemuxSource.bcp47($0) },
                                        uri: Leaf.subtitlePlaylist(track.index).key,
                                        isDefault: (defaultSubtitleLanguage.map { language in
                                            track.language?.caseInsensitiveCompare(language) == .orderedSame ||
                                            RemuxSource.bcp47(track.language ?? "") == RemuxSource.bcp47(language)
                                        } ?? false) || (defaultSubtitleTitle.map { title in
                                            track.title?.caseInsensitiveCompare(title) == .orderedSame
                                        } ?? false),
                                        isForced: (track.title ?? "").lowercased().contains("forced"))
        }
        let master = HLSPlaylistBuilder.master(info.master, subtitles: renditions)
        let media = HLSPlaylistBuilder.media(segments: info.segments)
        var subtitleTexts: [Int: Data] = [:]
        for track in info.plan.textSubtitles {
            subtitleTexts[track.index] = Data(HLSPlaylistBuilder.subtitles(segments: info.segments, track: track.index).utf8)
        }
        locked {
            preparedInfo = info
            masterText = Data(master.utf8)
            mediaText = Data(media.utf8)
            subtitlePlaylists = subtitleTexts
        }
        return info
    }

    // MARK: RelaySource

    public func resource(named name: String) async throws -> RelayResource {
        guard let leaf = validated(name) else { throw RelayError.notFound }
        let data = try await bytes(for: leaf)
        if case .segment(let index) = leaf { prefetch(index + 1) }
        return RelayResource(contentType: leaf.contentType, length: Int64(data.count), acceptsRanges: true)
    }

    public func open(_ name: String, range: ClosedRange<Int64>?) async throws -> RelayBodyReader {
        guard let leaf = validated(name) else { throw RelayError.notFound }
        let data = try await bytes(for: leaf)
        let total = Int64(data.count)
        let bounds = range ?? (total > 0 ? 0...(total - 1) : nil)
        if let bounds = bounds, bounds.lowerBound < 0 || bounds.upperBound >= total { throw RelayError.rangeNotSatisfiable(total: total) }
        return DataBodyReader(data: data, range: bounds)
    }

    public func close() {
        let (tasks, wasClosed): ([Task<Data, Error>], Bool) = locked {
            let already = closed
            closed = true
            let running = Array(inflight.values)
            inflight.removeAll()
            cache.removeAll()
            order.removeAll()
            cachedBytes = 0
            return (running, already)
        }
        for task in tasks { task.cancel() }
        if !wasClosed { engine.close() }
    }

    // MARK: Pieces

    /// The leaf if it names something this file has.
    private func validated(_ name: String) -> Leaf? {
        guard let leaf = Leaf.parse(name) else { return nil }
        let info: RemuxPrepared? = locked { closed ? nil : preparedInfo }
        guard let known = info else { return nil }
        switch leaf {
        case .segment(let index):
            if index >= known.segments.count { return nil }
        case .subtitlePlaylist(let track):
            if !known.plan.textSubtitles.contains(where: { $0.index == track }) { return nil }
        case .subtitleSegment(let track, let segment):
            if segment >= known.segments.count || !known.plan.textSubtitles.contains(where: { $0.index == track }) { return nil }
        default:
            break
        }
        return leaf
    }

    private func bytes(for leaf: Leaf) async throws -> Data {
        switch leaf {
        case .master: return locked { masterText }
        case .media: return locked { mediaText }
        case .initSegment:
            return try await cached(leaf.key) { [engine] in try await engine.initSegment() }
        case .segment(let index):
            return try await cached(leaf.key) { [engine] in try await engine.mediaSegment(index) }
        case .subtitlePlaylist(let track):
            return locked { subtitlePlaylists[track] ?? Data() }
        case .subtitleSegment(let track, let segment):
            return try await cached(leaf.key) { [engine] in try await engine.subtitleSegment(track: track, index: segment) }
        }
    }

    private func cached(_ key: String, produce: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let lookup: Lookup = try locked {
            if closed { throw RelayError.notFound }
            if let data = cache[key] {
                touch(key)
                return .hit(data)
            }
            if let running = inflight[key] { return .pending(running) }
            let created = Task { try await produce() }
            inflight[key] = created
            return .pending(created)
        }
        switch lookup {
        case .hit(let data):
            return data
        case .pending(let task):
            do {
                let data = try await task.value
                store(key, data)
                return data
            } catch {
                locked { if inflight[key] != nil { inflight[key] = nil } }
                throw RemuxSource.relayError(from: error)
            }
        }
    }

    private func store(_ key: String, _ data: Data) {
        locked {
            inflight[key] = nil
            guard !closed, cache[key] == nil else { return }
            cache[key] = data
            order.append(key)
            cachedBytes += data.count
            // The newest piece and the init segment always stay; the oldest others go first.
            var index = 0
            while cachedBytes > maxCacheBytes && index < order.count - 1 {
                let candidate = order[index]
                if candidate == Leaf.initName { index += 1; continue }
                cachedBytes -= cache[candidate]?.count ?? 0
                cache[candidate] = nil
                order.remove(at: index)
            }
        }
    }

    private func touch(_ key: String) {
        if let position = order.firstIndex(of: key) {
            order.remove(at: position)
            order.append(key)
        }
    }

    /// Starts making the next piece while the current one is being sent.
    private func prefetch(_ index: Int) {
        let known = locked { closed ? 0 : (preparedInfo?.segments.count ?? 0) }
        guard index < known else { return }
        Task { [weak self] in
            _ = try? await self?.bytes(for: .segment(index))
        }
    }

    // MARK: Plumbing

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// An ISO 639-2 code as BCP 47, which HLS wants ("ita" → "it"); nil for "und" and unknown text.
    static func bcp47(_ code: String) -> String? {
        let lowered = code.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.isEmpty || lowered == "und" { return nil }
        let map = ["ita": "it", "eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "spa": "es", "por": "pt", "jpn": "ja",
                   "kor": "ko", "chi": "zh", "zho": "zh", "rus": "ru", "nld": "nl", "dut": "nl", "pol": "pl", "tur": "tr", "ara": "ar",
                   "swe": "sv", "nor": "no", "dan": "da", "fin": "fi", "ces": "cs", "cze": "cs", "ell": "el", "gre": "el", "heb": "he",
                   "hin": "hi", "hun": "hu", "ron": "ro", "rum": "ro", "ukr": "uk", "tha": "th", "vie": "vi", "ind": "id"]
        if let mapped = map[lowered] { return mapped }
        if lowered.count == 2, lowered.allSatisfy({ $0.isLetter }) { return lowered }
        return nil
    }

    static func relayError(from error: Error) -> Error {
        if error is CancellationError { return error }
        if let relay = error as? RelayError { return relay }
        guard let remux = error as? RemuxError else { return RelayError.mapping(error) }
        switch remux {
        case .closed, .segmentOutOfRange: return RelayError.notFound
        case .refused, .encoderUnavailable: return RelayError.upstreamNotMedia
        case .noKeyframeIndex, .unreadable: return RelayError.upstreamBadRange
        case .engine(let code): return RelayError.upstreamUnreachable(code: code)
        }
    }
}

/// Reads a piece that is already in memory, a block at a time.
final class DataBodyReader: RelayBodyReader, @unchecked Sendable {
    private let data: Data
    private let last: Int
    private var position: Int
    private let lock = NSLock()
    private var cancelled = false
    static let blockSize = 256 * 1024

    init(data: Data, range: ClosedRange<Int64>?) {
        self.data = data
        self.position = Int(range?.lowerBound ?? 0)
        self.last = range.map { Int($0.upperBound) } ?? -1
    }

    func next() async throws -> Data? {
        return nextChunk()
    }

    private func nextChunk() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if cancelled || position > last { return nil }
        let end = min(position + DataBodyReader.blockSize - 1, last)
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
