import Foundation

/// Serves a file the system player cannot read (MKV) as HLS with fragmented MP4 pieces:
/// `index.m3u8` (master), `media.m3u8`, `init.mp4` and `seg-<n>.m4s`. The pieces are made on demand by a `RemuxEngine` and the last few
/// are kept in memory.
public final class RemuxSource: RelaySource, @unchecked Sendable {
    public enum Leaf: Equatable, Sendable {
        case master, media, initSegment
        case segment(Int)

        public static let masterName = "index.m3u8"
        public static let mediaName = "media.m3u8"
        public static let initName = "init.mp4"

        public static func parse(_ name: String) -> Leaf? {
            switch name {
            case masterName: return .master
            case mediaName: return .media
            case initName: return .initSegment
            default:
                guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return nil }
                let digits = name.dropFirst(4).dropLast(4)
                guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      digits == "0" || digits.first != "0", let index = Int(digits) else { return nil }
                return .segment(index)
            }
        }

        var contentType: String {
            switch self {
            case .master, .media: return "application/vnd.apple.mpegurl"
            case .initSegment, .segment: return "video/mp4"
            }
        }

        var key: String {
            switch self {
            case .master: return Leaf.masterName
            case .media: return Leaf.mediaName
            case .initSegment: return Leaf.initName
            case .segment(let index): return "seg-\(index).m4s"
            }
        }
    }

    private enum Lookup {
        case hit(Data)
        case pending(Task<Data, Error>)
    }

    private let engine: RemuxEngine
    private let maxCacheBytes: Int
    private let lock = NSLock()
    private var preparedInfo: RemuxPrepared?
    private var masterText = Data()
    private var mediaText = Data()
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var cachedBytes = 0
    private var inflight: [String: Task<Data, Error>] = [:]
    private var closed = false

    public init(engine: RemuxEngine, maxCacheBytes: Int = 160 << 20) {
        self.engine = engine
        self.maxCacheBytes = maxCacheBytes
    }

    public var prepared: RemuxPrepared? { return locked { preparedInfo } }

    /// Opens the file and builds the playlists. Throws `RemuxError` (a refusal carries the reason to show the viewer).
    @discardableResult
    public func prepare() async throws -> RemuxPrepared {
        let info = try await engine.prepare()
        guard !info.segments.isEmpty else { throw RemuxError.noKeyframeIndex }
        let master = HLSPlaylistBuilder.master(info.master)
        let media = HLSPlaylistBuilder.media(segments: info.segments)
        locked {
            preparedInfo = info
            masterText = Data(master.utf8)
            mediaText = Data(media.utf8)
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
        if case .segment(let index) = leaf, index >= known.segments.count { return nil }
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

    static func relayError(from error: Error) -> Error {
        if error is CancellationError { return error }
        if let relay = error as? RelayError { return relay }
        guard let remux = error as? RemuxError else { return RelayError.mapping(error) }
        switch remux {
        case .closed, .segmentOutOfRange: return RelayError.notFound
        case .refused: return RelayError.upstreamNotMedia
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
