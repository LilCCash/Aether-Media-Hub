import Foundation
#if canImport(Darwin)
#if canImport(Security)
import Security
#endif

/// Reads the real file behind a link, a window at a time, over URLSession.
///
/// Everything that could carry the secret stays in here: the address and the headers live in `upstream`, the session is ephemeral (no
/// cache, no cookies, no credentials), every redirect is checked again by the `UpstreamGuard`, the headers an addon asked for are not
/// sent to another host, and a failure is reduced to a status or an error code before it leaves.
public final class URLSessionRangeFetcher: RelayRangeFetcher, @unchecked Sendable {
    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 3
        #if os(iOS)
        configuration.multipathServiceType = .none
        #endif
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    private let upstream: RelayUpstream
    private let guardian: UpstreamGuard
    private let delegate: RangeFetchDelegate
    private let session: URLSession
    private let gate: AsyncGate
    private let stateLock = NSLock()
    private var invalidated = false

    public init(upstream: RelayUpstream, guardian: UpstreamGuard, limits: RelayLimits = .standard,
                configuration: URLSessionConfiguration = URLSessionRangeFetcher.makeConfiguration()) {
        self.upstream = upstream
        self.guardian = guardian
        self.gate = AsyncGate(permits: limits.maxUpstreamPerSession)
        self.delegate = RangeFetchDelegate(upstream: upstream, guardian: guardian)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    /// For the test that checks no authentication challenge is ever answered.
    var sessionDelegateForTesting: NSObject { return delegate }

    public func probe() async throws -> RelayResource {
        let outcome = try await run(range: 0...0, kind: .probe)
        guard case .probed(let total) = outcome else { throw RelayError.upstreamBadRange }
        return RelayResource(contentType: "application/octet-stream", length: total, acceptsRanges: true)
    }

    public func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        guard range.lowerBound >= 0 else { throw RelayError.upstreamBadRange }
        let outcome = try await run(range: range, kind: .window)
        guard case .window(let data) = outcome else { throw RelayError.upstreamBadRange }
        return data
    }

    public func invalidate() {
        stateLock.lock()
        invalidated = true
        stateLock.unlock()
        session.invalidateAndCancel()
    }

    private var isInvalidated: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return invalidated
    }

    private func run(range: ClosedRange<Int64>, kind: FetchKind) async throws -> FetchOutcome {
        if isInvalidated { throw RelayError.upstreamUnreachable(code: NSURLErrorCancelled) }

        try await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()

        do {
            // Checked on every request, so a name that starts resolving to the home network is caught.
            try await guardian.validateOrigin(upstream.url)
        } catch is UpstreamBlock {
            throw RelayError.blockedTarget
        }

        var request = URLRequest(url: upstream.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = RelayHeaderPolicy.upstreamRequestHeaders(session: upstream.headers, range: range, includeSession: true)
        return try await delegate.perform(session: session, request: request, range: range, kind: kind)
    }
}

enum FetchKind {
    case probe, window
}

enum FetchOutcome {
    case probed(total: Int64)
    case window(Data)
}

/// What a response head means for a request of a given kind.
enum RangeEvaluation: Equatable {
    case probed(total: Int64)
    case proceed
    case failure(RelayError)
}

enum RangeResponseEvaluator {
    /// Judges a response head. `contentType`, `contentEncoding` and `contentRange` are the raw header values.
    static func evaluate(status: Int, contentType: String?, contentEncoding: String?, contentRange: String?, expectedLength: Int64,
                         kind: FetchKind, range: ClosedRange<Int64>) -> RangeEvaluation {
        switch status {
        case 206:
            break
        case 200:
            return .failure(.upstreamNoRanges)
        case 416:
            // An empty file answers a request for its first byte with `bytes */0`.
            if kind == .probe, let parsed = RelayContentRange.parse(contentRange), parsed.range == nil, parsed.total == 0 { return .probed(total: 0) }
            return .failure(.upstreamBadRange)
        default:
            return .failure(.upstreamRejected(status: status))
        }
        if !RelayHeaderPolicy.isAcceptableUpstreamContentType(contentType) { return .failure(.upstreamNotMedia) }
        if let encoding = contentEncoding?.trimmingCharacters(in: .whitespaces).lowercased(), !encoding.isEmpty, encoding != "identity" {
            return .failure(.upstreamBadRange)
        }
        guard let parsed = RelayContentRange.parse(contentRange), let served = parsed.range else { return .failure(.upstreamBadRange) }
        switch kind {
        case .probe:
            guard served.lowerBound == 0, let total = parsed.total, total > 0 else { return .failure(parsed.total == nil ? .upstreamNoRanges : .upstreamBadRange) }
            return .probed(total: total)
        case .window:
            guard served == range else { return .failure(.upstreamBadRange) }
            if expectedLength >= 0 && expectedLength != Int64(range.count) { return .failure(.upstreamBadRange) }
            return .proceed
        }
    }
}

/// Owns the URLSession callbacks. One entry per request in flight, looked up by the task identifier.
final class RangeFetchDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Entry {
        let kind: FetchKind
        let range: ClosedRange<Int64>
        let continuation: CheckedContinuation<FetchOutcome, Error>
        var data = Data()
        var hops = 0
        var refusedRedirect = false

        init(kind: FetchKind, range: ClosedRange<Int64>, continuation: CheckedContinuation<FetchOutcome, Error>) {
            self.kind = kind
            self.range = range
            self.continuation = continuation
        }
    }

    private let upstream: RelayUpstream
    private let guardian: UpstreamGuard
    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]

    init(upstream: RelayUpstream, guardian: UpstreamGuard) {
        self.upstream = upstream
        self.guardian = guardian
    }

    // MARK: Requests

    func perform(session: URLSession, request: URLRequest, range: ClosedRange<Int64>, kind: FetchKind) async throws -> FetchOutcome {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<FetchOutcome, Error>) in
                lock.lock()
                entries[task.taskIdentifier] = Entry(kind: kind, range: range, continuation: continuation)
                lock.unlock()
                if Task.isCancelled {
                    finish(task.taskIdentifier, .failure(CancellationError()))
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Ends a request exactly once.
    private func finish(_ id: Int, _ result: Result<FetchOutcome, Error>) {
        lock.lock()
        let entry = entries.removeValue(forKey: id)
        lock.unlock()
        entry?.continuation.resume(with: result)
    }

    private func withEntry<T>(_ id: Int, _ body: (Entry) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else { return nil }
        return body(entry)
    }

    // MARK: Delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let id = task.taskIdentifier
        guard let target = request.url, let from = response.url ?? task.currentRequest?.url,
              let state = withEntry(id, { entry -> (Int, ClosedRange<Int64>) in
                  entry.hops += 1
                  return (entry.hops, entry.range)
              }) else {
            completionHandler(nil)
            return
        }
        let (hop, range) = state
        let upstream = self.upstream
        let guardian = self.guardian
        Task {
            do {
                try await guardian.validateRedirect(from: from, to: target, hop: hop, origin: upstream.url)
                var next = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                next.httpMethod = "GET"
                next.httpShouldHandleCookies = false
                // Headers the addon asked for go to the origin it named, never to wherever it redirects.
                let carry = guardian.mayCarrySessionHeaders(to: target, origin: upstream.url)
                next.allHTTPHeaderFields = RelayHeaderPolicy.upstreamRequestHeaders(session: upstream.headers, range: range, includeSession: carry)
                completionHandler(next)
            } catch {
                // Answer the request with the refusal now; do not wait for the system to deliver the redirect response.
                self.finish(id, .failure(RelayError.blockedTarget))
                task.cancel()
                completionHandler(nil)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let id = dataTask.taskIdentifier
        guard let http = response as? HTTPURLResponse, let info = withEntry(id, { ($0.kind, $0.range, $0.refusedRedirect) }) else {
            finish(id, .failure(RelayError.upstreamUnreachable(code: -1)))
            completionHandler(.cancel)
            return
        }
        if info.2 {
            finish(id, .failure(RelayError.blockedTarget))
            completionHandler(.cancel)
            return
        }
        let evaluation = RangeResponseEvaluator.evaluate(
            status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"),
            contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding"), contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            expectedLength: http.expectedContentLength, kind: info.0, range: info.1)
        switch evaluation {
        case .probed(let total):
            finish(id, .success(.probed(total: total)))
            completionHandler(.cancel)
        case .proceed:
            completionHandler(.allow)
        case .failure(let error):
            finish(id, .failure(error))
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let id = dataTask.taskIdentifier
        let overflow: Bool? = withEntry(id) { entry in
            entry.data.append(data)
            return Int64(entry.data.count) > Int64(entry.range.count)
        }
        if overflow == true {
            finish(id, .failure(RelayError.upstreamBadRange))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        guard let outcome = withEntry(id, { entry -> (FetchKind, Data, Int) in (entry.kind, entry.data, entry.range.count) }) else { return }
        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                finish(id, .failure(CancellationError()))
            } else {
                finish(id, .failure(RelayError.mapping(error)))
            }
            return
        }
        if outcome.0 == .window && outcome.1.count == outcome.2 {
            finish(id, .success(.window(outcome.1)))
        } else {
            finish(id, .failure(RelayError.upstreamBadRange))
        }
    }
}

/// Lets at most `permits` requests run at once; the others wait their turn. A waiting request that is cancelled gives up its place.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: Int
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    private var nextID: UInt64 = 0

    init(permits: Int) {
        self.permits = max(1, permits)
    }

    private func takeTicket() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return nextID
    }

    func acquire() async throws {
        try Task.checkCancellation()
        let id = takeTicket()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if permits > 0 {
                    permits -= 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            permits += 1
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        lock.lock()
        let index = waiters.firstIndex { $0.id == id }
        let waiter = index.map { waiters.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }
}
#endif
