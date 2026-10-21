import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one thing the windowed source needs from the network: facts about the real file and ranged reads of it. The URLSession version
/// lives in `URLSessionRangeFetcher`; tests use a fake. Credentials, redirects, TLS and the cap on parallel requests stay on the other
/// side of this protocol, so nothing here can print or forward the real address.
public protocol RelayRangeFetcher: Sendable {
    /// Asks for the first byte. Returns the total size from `Content-Range`; throws `RelayError.upstreamNoRanges` when the source does not
    /// answer a range with 206 and a total.
    func probe() async throws -> RelayResource
    /// Exactly the bytes of `range`, or a thrown `RelayError`.
    func fetch(_ range: ClosedRange<Int64>) async throws -> Data
    /// Cancels whatever is in flight and refuses new requests.
    func invalidate()
}

public extension RelayRangeFetcher {
    func invalidate() {}
}

extension RelayError {
    /// Reduces any error to one of the relay's own, which hold integers only. The description and `userInfo` of the original are never
    /// read, because a URL error carries the failing address.
    public static func mapping(_ error: Error) -> RelayError {
        if let relay = error as? RelayError { return relay }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .upstreamUnreachable(code: ns.code) }
        return .upstreamUnreachable(code: -1)
    }
}

/// Serves a file that lives behind a link by reading it from the real source in windows. Seeking is a new `open` with a range.
public final class HTTPRangeSource: RelaySource, @unchecked Sendable {
    public let leaf: String
    private let contentType: String
    private let fetcher: RelayRangeFetcher
    private let limits: RelayLimits
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onUpstreamRejected: (@Sendable (Int) -> Void)?

    private let lock = NSLock()
    private var facts: RelayResource?
    private var closed = false
    private var readers: [ObjectIdentifier: WindowedBodyReader] = [:]

    /// `leaf` is the file name the receiver asks for (`video.<ext>`), and `contentType` the type the app decided for it.
    public init(leaf: String, contentType: String, fetcher: RelayRangeFetcher, limits: RelayLimits = .standard,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
                    _ = try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                },
                onUpstreamRejected: (@Sendable (Int) -> Void)? = nil) {
        self.leaf = leaf
        self.contentType = contentType
        self.fetcher = fetcher
        self.limits = limits
        self.sleep = sleep
        self.onUpstreamRejected = onUpstreamRejected
    }

    /// Learns the size of the file. Must succeed before the source is published: a link that cannot be read in ranges is refused here.
    @discardableResult
    public func prepare() async throws -> RelayResource {
        let probed = try await fetcher.probe()
        guard let length = probed.length, length >= 0 else { throw RelayError.upstreamNoRanges }
        let resource = RelayResource(contentType: contentType, length: length, acceptsRanges: true)
        locked { facts = resource }
        return resource
    }

    public func resource(named name: String) async throws -> RelayResource {
        guard name == leaf, let resource = locked({ facts }), !locked({ closed }) else { throw RelayError.notFound }
        return resource
    }

    public func open(_ name: String, range: ClosedRange<Int64>?) async throws -> RelayBodyReader {
        guard name == leaf, let resource = locked({ facts }), let total = resource.length, !locked({ closed }) else { throw RelayError.notFound }
        let bounds: ClosedRange<Int64>?
        if let range = range {
            guard range.lowerBound >= 0, range.upperBound < total else { throw RelayError.rangeNotSatisfiable(total: total) }
            bounds = range
        } else {
            bounds = total > 0 ? 0...(total - 1) : nil
        }
        let reader = WindowedBodyReader(fetcher: fetcher, bounds: bounds, windowSize: Int64(max(1, limits.windowSize)),
                                        retryDelay: limits.retryDelay, sleep: sleep,
                                        onRejected: { [weak self] status in self?.onUpstreamRejected?(status) })
        let key = ObjectIdentifier(reader)
        locked { readers[key] = reader }
        reader.onFinish = { [weak self] in self?.locked { self?.readers[key] = nil } }
        do {
            // The first window is read before anything is promised to the receiver, so a dead link is a real error status.
            try await reader.prime()
        } catch {
            locked { readers[key] = nil }
            throw error
        }
        if locked({ closed }) {
            reader.cancel()
            throw RelayError.notFound
        }
        return reader
    }

    public func close() {
        let active: [WindowedBodyReader] = locked {
            closed = true
            let current = Array(readers.values)
            readers.removeAll()
            return current
        }
        for reader in active { reader.cancel() }
        fetcher.invalidate()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Reads one range of the file window by window, always keeping the next window in flight while the current one is being sent. At most
/// two windows (about 8 MiB) are in memory per reader.
final class WindowedBodyReader: RelayBodyReader, @unchecked Sendable {
    private enum Step {
        case data(Data)
        case wait(Task<Data, Error>)
        case end
    }

    private let fetcher: RelayRangeFetcher
    private let last: Int64
    private let windowSize: Int64
    private let retryDelay: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onRejected: @Sendable (Int) -> Void
    var onFinish: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var nextStart: Int64
    private var queue: [Task<Data, Error>] = []
    private var first: Data?
    private var cancelled = false
    private var finished = false

    /// `bounds == nil` is an empty body.
    init(fetcher: RelayRangeFetcher, bounds: ClosedRange<Int64>?, windowSize: Int64, retryDelay: TimeInterval,
         sleep: @escaping @Sendable (TimeInterval) async -> Void, onRejected: @escaping @Sendable (Int) -> Void) {
        self.fetcher = fetcher
        self.nextStart = bounds?.lowerBound ?? 0
        self.last = bounds?.upperBound ?? -1
        self.windowSize = windowSize
        self.retryDelay = retryDelay
        self.sleep = sleep
        self.onRejected = onRejected
    }

    // MARK: Reading

    /// Reads the first window and starts the second.
    func prime() async throws {
        let task: Task<Data, Error>? = locked {
            launchNextLocked()
            return queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let firstTask = task else { return }
        do {
            let data = try await firstTask.value
            locked {
                first = data
                launchNextLocked()
            }
        } catch {
            cancel()
            if error is CancellationError { throw error }
            throw RelayError.mapping(error)
        }
    }

    func next() async throws -> Data? {
        let step: Step = locked {
            if cancelled || finished { return .end }
            if let data = first {
                first = nil
                return .data(data)
            }
            if queue.isEmpty {
                finished = true
                return .end
            }
            return .wait(queue.removeFirst())
        }
        switch step {
        case .data(let data):
            return data
        case .end:
            finish()
            return nil
        case .wait(let task):
            do {
                let data = try await task.value
                locked { launchNextLocked() }
                return data
            } catch {
                if locked({ cancelled }) || error is CancellationError {
                    finish()
                    return nil
                }
                cancel()
                throw RelayError.mapping(error)
            }
        }
    }

    func cancel() {
        let pending: [Task<Data, Error>] = locked {
            cancelled = true
            first = nil
            let current = queue
            queue.removeAll()
            return current
        }
        for task in pending { task.cancel() }
        finish()
    }

    // MARK: Windows

    /// Starts the next window unless one is already waiting or the range is covered. Call with the lock held.
    private func launchNextLocked() {
        guard !cancelled, nextStart <= last, queue.isEmpty else { return }
        let start = nextStart
        let end = min(start + windowSize - 1, last)
        nextStart = end + 1
        let window = start...end
        queue.append(Task { try await self.fetchWindow(window) })
    }

    /// One window, with one more try after a short pause when the failure looks temporary. A refusal (401, 403, 404, 410) is final: the
    /// link has expired or was revoked, and asking again would only repeat it.
    private func fetchWindow(_ window: ClosedRange<Int64>) async throws -> Data {
        var retried = false
        while true {
            do {
                let data = try await fetcher.fetch(window)
                guard data.count == window.count else { throw RelayError.upstreamBadRange }
                return data
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                let mapped = RelayError.mapping(error)
                if Task.isCancelled { throw CancellationError() }
                if case .upstreamRejected(let status) = mapped, [401, 403, 404, 410].contains(status) {
                    onRejected(status)
                    throw mapped
                }
                guard !retried, WindowedBodyReader.isTemporary(mapped) else { throw mapped }
                retried = true
                await sleep(retryDelay)
                if Task.isCancelled { throw CancellationError() }
            }
        }
    }

    private static func isTemporary(_ error: RelayError) -> Bool {
        switch error {
        case .upstreamUnreachable: return true
        case .upstreamRejected(let status): return (500...599).contains(status)
        default: return false
        }
    }

    // MARK: Plumbing

    private func finish() {
        let handler: (@Sendable () -> Void)? = locked {
            let handler = onFinish
            onFinish = nil
            return handler
        }
        handler?()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
