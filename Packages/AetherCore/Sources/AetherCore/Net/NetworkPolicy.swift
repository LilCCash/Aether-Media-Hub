import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - IP addresses

public enum AddressClass: Equatable, Sendable {
    case publicInternet
    case loopback
    case privateNetwork
    case linkLocal
    case multicast
    case unspecified
    case reserved
}

public enum IPAddress: Hashable, Sendable {
    case v4(UInt8, UInt8, UInt8, UInt8)
    case v6([UInt8])

    /// Parses dotted-quad IPv4 or any textual IPv6. Other numeric spellings (`2130706433`, `0x7f.1`) return nil:
    /// they are handled by the system resolver, which normalises them.
    public static func parse(_ text: String) -> IPAddress? {
        var host = text
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // Drop IPv6 zone id (fe80::1%en0).
        if let percent = host.firstIndex(of: "%") {
            host = String(host[host.startIndex..<percent])
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            var bytes: [UInt8] = []
            for part in parts {
                guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = UInt8(part) else {
                    return nil
                }
                bytes.append(value)
            }
            return .v4(bytes[0], bytes[1], bytes[2], bytes[3])
        }
        if host.contains(":") {
            var buffer = [UInt8](repeating: 0, count: 16)
            let ok = host.withCString { pointer -> Bool in
                return inet_pton(AF_INET6, pointer, &buffer) == 1
            }
            return ok ? .v6(buffer) : nil
        }
        return nil
    }

    public var addressClass: AddressClass {
        switch self {
        case .v4(let a, let b, let c, _):
            if a == 0 { return .unspecified }
            if a == 127 { return .loopback }
            if a == 10 { return .privateNetwork }
            if a == 172 && (16...31).contains(b) { return .privateNetwork }
            if a == 192 && b == 168 { return .privateNetwork }
            if a == 100 && (64...127).contains(b) { return .privateNetwork }
            if a == 169 && b == 254 { return .linkLocal }
            if (224...239).contains(a) { return .multicast }
            if a >= 240 { return .reserved }
            if a == 192 && b == 0 && (c == 0 || c == 2) { return .reserved }
            if a == 198 && (b == 18 || b == 19) { return .reserved }
            if a == 198 && b == 51 && c == 100 { return .reserved }
            if a == 203 && b == 0 && c == 113 { return .reserved }
            return .publicInternet
        case .v6(let bytes):
            guard bytes.count == 16 else { return .reserved }
            if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
            if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .loopback }
            // IPv4-mapped ::ffff:a.b.c.d
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
                return IPAddress.v4(bytes[12], bytes[13], bytes[14], bytes[15]).addressClass
            }
            // NAT64 64:ff9b::/96
            if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b
                && bytes[4..<12].allSatisfy({ $0 == 0 }) {
                return IPAddress.v4(bytes[12], bytes[13], bytes[14], bytes[15]).addressClass
            }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return .linkLocal }
            if (bytes[0] & 0xfe) == 0xfc { return .privateNetwork }
            if bytes[0] == 0xff { return .multicast }
            if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8 { return .reserved }
            return .publicInternet
        }
    }
}

// MARK: - Resolution

public protocol HostResolving: Sendable {
    func resolve(host: String) async throws -> [IPAddress]
}

/// Resolves names with `getaddrinfo` on a background queue.
public struct SystemHostResolver: HostResolving {
    public init() {}

    public func resolve(host: String) async throws -> [IPAddress] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try SystemHostResolver.resolveBlocking(host) })
            }
        }
    }

    struct ResolutionFailure: Error {}

    static func resolveBlocking(_ host: String) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { throw ResolutionFailure() }
        defer { freeaddrinfo(first) }

        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            let info = node.pointee
            if info.ai_family == AF_INET, let address = info.ai_addr {
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                    let raw = pointer.pointee.sin_addr.s_addr
                    let bytes = withUnsafeBytes(of: raw) { Array($0) }
                    if bytes.count == 4 {
                        addresses.append(.v4(bytes[0], bytes[1], bytes[2], bytes[3]))
                    }
                }
            } else if info.ai_family == AF_INET6, let address = info.ai_addr {
                address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    let raw = pointer.pointee.sin6_addr
                    let bytes = withUnsafeBytes(of: raw) { Array($0) }
                    if bytes.count == 16 {
                        addresses.append(.v6(bytes))
                    }
                }
            }
            cursor = info.ai_next
        }
        return addresses
    }
}

/// Deterministic resolver for tests.
public struct StaticHostResolver: HostResolving {
    public var table: [String: [IPAddress]]

    public init(_ table: [String: [IPAddress]]) {
        self.table = table
    }

    public func resolve(host: String) async throws -> [IPAddress] {
        if let addresses = table[host.lowercased()] { return addresses }
        throw SystemHostResolver.ResolutionFailure()
    }
}

// MARK: - Policy

/// Decides whether the app may talk to a URL. Addons are untrusted third-party services, so by default we
/// refuse anything that is not plain `http(s)` to a public host: no credentials in the URL, no loopback,
/// no private/link-local ranges (SSRF protection), no `.local` names. Every redirect hop is re-validated.
public struct NetworkPolicy: Sendable {
    public enum Purpose: Sendable {
        /// `URLSession` request made by the app (manifest, catalog, meta, subtitles). Subject to ATS.
        case addonRequest
        /// URL handed to AVFoundation / Cast. ATS media exception applies, so plain http is allowed.
        case mediaPlayback
    }

    public var allowLocalNetwork: Bool
    /// Only for tests / UI tests / simulator development.
    public var allowLoopback: Bool
    /// Refuse `http://` to public hosts for `URLSession` traffic because ATS would block it anyway.
    public var requireHTTPSForPublicHosts: Bool
    public var checkDNS: Bool
    public var maxURLLength: Int
    public var resolver: HostResolving

    public init(allowLocalNetwork: Bool = false,
                allowLoopback: Bool = false,
                requireHTTPSForPublicHosts: Bool = true,
                checkDNS: Bool = true,
                maxURLLength: Int = 4096,
                resolver: HostResolving = SystemHostResolver()) {
        self.allowLocalNetwork = allowLocalNetwork
        self.allowLoopback = allowLoopback
        self.requireHTTPSForPublicHosts = requireHTTPSForPublicHosts
        self.checkDNS = checkDNS
        self.maxURLLength = maxURLLength
        self.resolver = resolver
    }

    /// Offline-only checks (scheme, credentials, host shape, IP literals, local host names).
    /// Returns the address class when the host is an IP literal, so the caller can skip DNS.
    func validateSyntax(_ url: URL) throws -> AddressClass? {
        if url.absoluteString.count > maxURLLength { throw AddonError.blockedURL(.tooLong) }
        guard let scheme = url.scheme?.lowercased() else { throw AddonError.invalidURL("manca lo schema") }
        guard scheme == "http" || scheme == "https" else { throw AddonError.blockedURL(.scheme(scheme)) }
        if url.user != nil || url.password != nil { throw AddonError.blockedURL(.credentialsInURL) }
        guard var host = url.host?.lowercased(), !host.isEmpty else { throw AddonError.blockedURL(.emptyHost) }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        if host.isEmpty { throw AddonError.blockedURL(.emptyHost) }

        if let literal = IPAddress.parse(host) {
            let addressClass = literal.addressClass
            try check(addressClass, host: host)
            return addressClass
        }

        if host == "localhost" || host.hasSuffix(".localhost") {
            try check(.loopback, host: host)
            return .loopback
        }
        let localSuffixes = [".local", ".internal", ".lan", ".home", ".home.arpa", ".intranet", ".corp"]
        let isSingleLabel = !host.contains(".")
        // Alternative numeric spellings of an IP (`2130706433`, `0x7f000001`) are never valid names: refuse them
        // even when local-network access is enabled, since they can smuggle loopback.
        if isSingleLabel && host.allSatisfy({ $0.isNumber || $0.isHexDigit || $0 == "x" }) && host.contains(where: { $0.isNumber }) {
            throw AddonError.blockedURL(.privateAddress(host))
        }
        if isSingleLabel || localSuffixes.contains(where: { host.hasSuffix($0) }) {
            if !allowLocalNetwork { throw AddonError.blockedURL(.localHostname(host)) }
            return .privateNetwork
        }
        return nil
    }

    private func check(_ addressClass: AddressClass, host: String) throws {
        switch addressClass {
        case .publicInternet:
            return
        case .loopback:
            if allowLoopback { return }
            throw AddonError.blockedURL(.loopback)
        case .privateNetwork, .linkLocal:
            if allowLocalNetwork { return }
            throw AddonError.blockedURL(.privateAddress(host))
        case .multicast, .unspecified, .reserved:
            throw AddonError.blockedURL(.privateAddress(host))
        }
    }

    /// Full validation including DNS (anti-rebinding, best effort: the connection may re-resolve later).
    public func validate(_ url: URL, purpose: Purpose = .addonRequest) async throws {
        let literalClass = try validateSyntax(url)
        var resolvedClasses: [AddressClass] = []
        if let literalClass = literalClass {
            resolvedClasses = [literalClass]
        } else if checkDNS, let host = url.host?.lowercased() {
            if let addresses = try? await resolver.resolve(host: host) {
                for address in addresses {
                    let addressClass = address.addressClass
                    try check(addressClass, host: host)
                    resolvedClasses.append(addressClass)
                }
            }
            // Resolution failure is not a policy violation: the request itself will fail with a network error.
        }
        if purpose == .addonRequest,
           requireHTTPSForPublicHosts,
           url.scheme?.lowercased() == "http",
           resolvedClasses.isEmpty || resolvedClasses.contains(.publicInternet) {
            throw AddonError.insecureTransport
        }
    }

    /// True when the URL's host is a local-network address or name (used to prompt before enabling local access).
    public func isLocalNetwork(_ url: URL) async -> Bool {
        let strict = NetworkPolicy(allowLocalNetwork: true, allowLoopback: true,
                                   requireHTTPSForPublicHosts: false, checkDNS: checkDNS,
                                   maxURLLength: maxURLLength, resolver: resolver)
        let syntaxClass: AddressClass?
        do {
            syntaxClass = try strict.validateSyntax(url)
        } catch {
            return false
        }
        if let syntaxClass = syntaxClass {
            return syntaxClass != .publicInternet
        }
        guard checkDNS, let host = url.host?.lowercased(),
              let addresses = try? await resolver.resolve(host: host) else { return false }
        return addresses.contains(where: { $0.addressClass != .publicInternet })
    }
}
