import Foundation

/// Shared plumbing of the TMDB and TheTVDB clients: host trust, status-to-error mapping and the single polite retry.
enum MetadataHTTP {
    /// Production hosts are https only; loopback / private-network hosts are accepted for UI-test fixtures. Any other
    /// base URL is refused so that a key can never be sent to an unexpected server.
    static func isTrusted(_ url: URL, productionHost: String) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty, let scheme = url.scheme?.lowercased() else { return false }
        if host == productionHost { return scheme == "https" }
        guard scheme == "http" || scheme == "https" else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        guard let address = IPAddress.parse(host) else { return false }
        switch address.addressClass {
        case .loopback, .privateNetwork, .linkLocal: return true
        case .publicInternet, .multicast, .unspecified, .reserved: return false
        }
    }

    static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.headers["retry-after"], let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(0, seconds)
    }

    /// Maps transport errors (never carrying a URL we control) and HTTP statuses to `MetadataError`.
    static func map(status: Int, response: HTTPResponse) -> MetadataError {
        switch status {
        case 401, 403: return .invalidCredentials
        case 404: return .notFound
        case 429: return .rateLimited(retryAfter: retryAfter(response))
        case 500...599: return .unavailable("HTTP \(status)")
        default: return .malformed
        }
    }

    static func map(error: Error) -> MetadataError {
        if error is CancellationError { return .unavailable("annullato") }
        if let addon = error as? AddonError {
            switch addon {
            case .offline, .timeout, .unreachable, .tlsFailure, .atsBlocked: return .unavailable(String(describing: addon))
            case .cancelled: return .unavailable("annullato")
            case .responseTooLarge, .malformedResponse: return .malformed
            default: return .unavailable(String(describing: addon))
            }
        }
        return .unavailable("errore di rete")
    }

    /// Performs the request, waiting once (at most 5 s) when the service asks for it with `Retry-After`.
    static func send(_ request: HTTPRequest, using http: HTTPClient) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let response: HTTPResponse
            do {
                response = try await http.send(request)
            } catch {
                throw map(error: error)
            }
            if response.statusCode == 429, attempt == 0, let wait = retryAfter(response), wait > 0, wait <= 5 {
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if Task.isCancelled { throw MetadataError.unavailable("annullato") }
                continue
            }
            return response
        }
    }
}
