import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var maxBytes: Int
    public var purpose: NetworkPolicy.Purpose

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
                timeout: TimeInterval = 15, maxBytes: Int = HTTPLimits.resource,
                purpose: NetworkPolicy.Purpose = .addonRequest) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.maxBytes = maxBytes
        self.purpose = purpose
    }
}

public enum HTTPLimits {
    public static let manifest = 1 * 1024 * 1024
    public static let resource = 8 * 1024 * 1024
    public static let subtitle = 4 * 1024 * 1024
    public static let maxRedirects = 5
}

public struct HTTPResponse: Sendable {
    public var data: Data
    public var statusCode: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var url: URL

    public init(data: Data, statusCode: Int, headers: [String: String] = [:], url: URL) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
    }

    public var isSuccess: Bool { return (200..<300).contains(statusCode) }
}

public protocol HTTPClient: Sendable {
    /// Performs the request. Non-2xx statuses are returned, not thrown; policy / transport failures throw `AddonError`.
    /// The call honours Swift task cancellation.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Runs `operation` and fails with `AddonError.timeout` if it does not finish within `seconds`.
public func withDeadline<T: Sendable>(seconds: TimeInterval,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw AddonError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw AddonError.timeout }
        return first
    }
}

/// `URLSession` backed client with: per-request validation (`NetworkPolicy`), streaming size cap,
/// re-validated redirects (max 5, no https→http downgrade), no cookies, no disk cache, cancellation.
public final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionDataDelegate, @unchecked Sendable {
    private final class RequestState {
        let maxBytes: Int
        let policy: NetworkPolicy
        let purpose: NetworkPolicy.Purpose
        let originalURL: URL
        var data = Data()
        var response: HTTPURLResponse?
        var continuation: CheckedContinuation<HTTPResponse, Error>?
        var failure: Error?
        var redirects = 0
        var task: URLSessionDataTask?
        var cancelled = false

        init(request: HTTPRequest, policy: NetworkPolicy) {
            self.maxBytes = request.maxBytes
            self.policy = policy
            self.purpose = request.purpose
            self.originalURL = request.url
        }
    }

    private let policyProvider: @Sendable () -> NetworkPolicy
    private let userAgent: String
    private let lock = NSLock()
    private var states: [Int: RequestState] = [:]
    private var session: URLSession!

    public init(policyProvider: @escaping @Sendable () -> NetworkPolicy,
                userAgent: String = "Aether/1.0 (iOS; Stremio-addon-client)",
                configuration: URLSessionConfiguration? = nil) {
        self.policyProvider = policyProvider
        self.userAgent = userAgent
        super.init()
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForResource = 60
        let queue = OperationQueue()
        queue.name = "app.aether.http"
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    public convenience init(policy: NetworkPolicy) {
        self.init(policyProvider: { policy })
    }

    public func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: HTTPClient

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let policy = policyProvider()
        try await policy.validate(request.url, purpose: request.purpose)
        let state = RequestState(request: request, policy: policy)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                var urlRequest = URLRequest(url: request.url,
                                            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                            timeoutInterval: request.timeout)
                urlRequest.httpMethod = request.method
                urlRequest.httpBody = request.body
                for (name, value) in request.headers {
                    urlRequest.setValue(value, forHTTPHeaderField: name)
                }
                if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
                    urlRequest.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
                }
                if urlRequest.value(forHTTPHeaderField: "Accept") == nil {
                    urlRequest.setValue("application/json, */*;q=0.5", forHTTPHeaderField: "Accept")
                }

                let task = self.session.dataTask(with: urlRequest)
                self.lock.lock()
                let alreadyCancelled = state.cancelled
                if !alreadyCancelled {
                    state.continuation = continuation
                    state.task = task
                    self.states[task.taskIdentifier] = state
                }
                self.lock.unlock()

                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        }, onCancel: {
            self.lock.lock()
            state.cancelled = true
            let task = state.task
            self.lock.unlock()
            task?.cancel()
        })
    }

    // MARK: URLSessionDataDelegate

    private func state(for task: URLSessionTask) -> RequestState? {
        lock.lock()
        defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    private func setFailure(_ failure: Error, on state: RequestState) {
        lock.lock()
        if state.failure == nil { state.failure = failure }
        lock.unlock()
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse {
            state.response = http
            if http.expectedContentLength > 0 && http.expectedContentLength > Int64(state.maxBytes) {
                setFailure(AddonError.responseTooLarge(limit: state.maxBytes), on: state)
                completionHandler(.cancel)
                return
            }
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else { return }
        state.data.append(data)
        if state.data.count > state.maxBytes {
            setFailure(AddonError.responseTooLarge(limit: state.maxBytes), on: state)
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        guard let state = state(for: task), let newURL = request.url else {
            completionHandler(nil)
            return
        }
        state.redirects += 1
        if state.redirects > HTTPLimits.maxRedirects {
            setFailure(AddonError.tooManyRedirects, on: state)
            completionHandler(nil)
            return
        }
        let previousScheme = response.url?.scheme?.lowercased()
        if previousScheme == "https" && newURL.scheme?.lowercased() == "http" {
            setFailure(AddonError.redirectBlocked(.scheme("http (declassamento da https)")), on: state)
            completionHandler(nil)
            return
        }
        let policy = state.policy
        let purpose = state.purpose
        Task {
            do {
                try await policy.validate(newURL, purpose: purpose)
                completionHandler(request)
            } catch let error as AddonError {
                if case .blockedURL(let reason) = error {
                    self.setFailure(AddonError.redirectBlocked(reason), on: state)
                } else {
                    self.setFailure(error, on: state)
                }
                completionHandler(nil)
            } catch {
                self.setFailure(error, on: state)
                completionHandler(nil)
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        let continuation = state?.continuation
        state?.continuation = nil
        lock.unlock()
        guard let state = state, let continuation = continuation else { return }

        if state.cancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let failure = state.failure {
            continuation.resume(throwing: failure)
            return
        }
        if let error = error {
            continuation.resume(throwing: URLSessionHTTPClient.map(error, url: state.originalURL))
            return
        }
        guard let http = state.response ?? (task.response as? HTTPURLResponse) else {
            continuation.resume(throwing: AddonError.malformedResponse("nessuna risposta HTTP"))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        continuation.resume(returning: HTTPResponse(data: state.data, statusCode: http.statusCode,
                                                    headers: headers, url: http.url ?? state.originalURL))
    }

    // MARK: Error mapping

    static func map(_ error: Error, url: URL) -> Error {
        let host = url.host ?? url.absoluteString
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return AddonError.timeout
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return AddonError.offline
            case .cancelled:
                return CancellationError()
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .clientCertificateRejected, .secureConnectionFailed:
                return AddonError.tlsFailure
            default:
                #if canImport(Darwin)
                if urlError.code == .appTransportSecurityRequiresSecureConnection {
                    return AddonError.atsBlocked
                }
                #endif
                return AddonError.unreachable(host)
            }
        }
        if error is CancellationError { return error }
        if error is AddonError { return error }
        return AddonError.unreachable(host)
    }
}
