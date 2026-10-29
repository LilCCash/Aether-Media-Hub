import Foundation

public enum UpstreamBlock: Error, Equatable, Sendable {
    case scheme, credentialsInURL, loopback, privateAddress, selfAddress, tooManyRedirects, downgrade, emptyHost, dnsFailure
}

/// Decides which addresses the relay may fetch from. The relay is a server on the phone that makes requests on behalf of whatever
/// address it was given, so it must never be turned against the phone itself or the home network.
///
///  * Only `https`, except a source that already lives on the local network (and only if the viewer allowed local network access).
///  * Never loopback, link-local, multicast, reserved, or the relay's own address.
///  * A name must resolve entirely to public addresses (checked again on every request, so a name that changes its answer is caught).
///  * A redirect is checked like a new origin, never leads from https to http, and a source on the local network may only redirect to
///    the same host.
public struct UpstreamGuard: Sendable {
    public let allowPrivateOrigin: Bool
    public let allowLoopback: Bool
    public let maxRedirects: Int
    private let selfHosts: Set<String>
    private let selfIPs: Set<IPAddress>
    private let resolver: HostResolving

    public init(allowPrivateOrigin: Bool, allowLoopback: Bool = false, selfAddresses: Set<String> = [],
                resolver: HostResolving = SystemHostResolver(), maxRedirects: Int = RelayLimits.standard.maxRedirects) {
        self.allowPrivateOrigin = allowPrivateOrigin
        self.allowLoopback = allowLoopback
        self.maxRedirects = maxRedirects
        self.resolver = resolver
        self.selfHosts = Set(selfAddresses.map { UpstreamGuard.normalize(host: $0) })
        self.selfIPs = Set(selfAddresses.compactMap { IPAddress.parse($0).map(UpstreamGuard.canonical) })
    }

    // MARK: Checks

    /// The first address the relay is asked to read from.
    public func validateOrigin(_ url: URL) async throws {
        try await validate(url, allowPrivate: allowPrivateOrigin)
    }

    /// A redirect from `from` to `to`. `hop` counts redirects of this one request, starting at 1.
    public func validateRedirect(from: URL, to: URL, hop: Int, origin: URL) async throws {
        if hop > maxRedirects { throw UpstreamBlock.tooManyRedirects }
        if from.scheme?.lowercased() == "https" && to.scheme?.lowercased() == "http" { throw UpstreamBlock.downgrade }
        // Another host never gets the privileges of a source on the local network.
        let sameHost = UpstreamGuard.host(of: to) != nil && UpstreamGuard.host(of: to) == UpstreamGuard.host(of: origin)
        try await validate(to, allowPrivate: sameHost && allowPrivateOrigin)
    }

    /// Request headers an addon asked for are only sent to the exact origin they were meant for.
    public func mayCarrySessionHeaders(to url: URL, origin: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == origin.scheme?.lowercased(),
              let host = UpstreamGuard.host(of: url), host == UpstreamGuard.host(of: origin) else { return false }
        return UpstreamGuard.port(of: url, scheme: scheme) == UpstreamGuard.port(of: origin, scheme: scheme)
    }

    // MARK: Implementation

    private func validate(_ url: URL, allowPrivate: Bool) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { throw UpstreamBlock.scheme }
        // Plain http is only for a source on the local network; ATS refuses it for anything else anyway.
        if scheme == "http" && !allowPrivate { throw UpstreamBlock.scheme }
        if url.user != nil || url.password != nil { throw UpstreamBlock.credentialsInURL }
        guard let host = UpstreamGuard.host(of: url) else { throw UpstreamBlock.emptyHost }
        if selfHosts.contains(host) { throw UpstreamBlock.selfAddress }

        var sawPublic = false
        if let literal = IPAddress.parse(host) {
            try check(literal, allowPrivate: allowPrivate, sawPublic: &sawPublic)
        } else if host == "localhost" || host.hasSuffix(".localhost") {
            if !allowLoopback { throw UpstreamBlock.loopback }
        } else {
            let addresses: [IPAddress]
            do {
                addresses = try await resolver.resolve(host: host)
            } catch {
                throw UpstreamBlock.dnsFailure
            }
            guard !addresses.isEmpty else { throw UpstreamBlock.dnsFailure }
            for address in addresses {
                try check(address, allowPrivate: allowPrivate, sawPublic: &sawPublic)
            }
        }
        if scheme == "http" && sawPublic { throw UpstreamBlock.scheme }
    }

    private func check(_ address: IPAddress, allowPrivate: Bool, sawPublic: inout Bool) throws {
        if selfIPs.contains(UpstreamGuard.canonical(address)) { throw UpstreamBlock.selfAddress }
        switch address.addressClass {
        case .publicInternet:
            sawPublic = true
        case .privateNetwork:
            if !allowPrivate { throw UpstreamBlock.privateAddress }
        case .loopback:
            if !allowLoopback { throw UpstreamBlock.loopback }
        case .unspecified:
            // 0.0.0.0 and :: reach this very device on most systems.
            throw UpstreamBlock.loopback
        case .linkLocal, .multicast, .reserved:
            throw UpstreamBlock.privateAddress
        }
    }

    // MARK: Helpers

    static func normalize(host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if value.hasSuffix(".") { value = String(value.dropLast()) }
        return value
    }

    static func host(of url: URL) -> String? {
        guard let raw = url.host else { return nil }
        let value = normalize(host: raw)
        return value.isEmpty ? nil : value
    }

    static func port(of url: URL, scheme: String) -> Int {
        return url.port ?? (scheme == "https" ? 443 : 80)
    }

    /// An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is the same device as the IPv4 address.
    static func canonical(_ address: IPAddress) -> IPAddress {
        if case .v6(let bytes) = address, bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return .v4(bytes[12], bytes[13], bytes[14], bytes[15])
        }
        return address
    }
}
