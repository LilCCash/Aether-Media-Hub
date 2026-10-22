import Foundation

// The "ponte" (relay): a small HTTP server on the phone that hands a television a keyless address for a video whose real link carries
// the viewer's account key (or needs request headers only the phone can send). The phone fetches the video from the real source and
// passes it on. Nothing in these types ever holds a URL that could be printed by mistake: see `RelayUpstream`.

/// Every bound of the relay in one place, so tests can shrink them.
public struct RelayLimits: Sendable {
    public static let standard = RelayLimits()

    public var maxConnections = 8
    public var maxConnectionsPerPeer = 4
    public var maxHeadBytes = 8192
    public var maxHeaders = 48
    /// Seconds a receiver has to send its request head.
    public var headTimeout: TimeInterval = 10
    /// Seconds a receiver may stop reading before the connection is closed.
    public var writeStallTimeout: TimeInterval = 300
    /// A session nobody has asked for after this long is revoked.
    public var armedWindow: TimeInterval = 180
    /// No session lives longer than this, used or not.
    public var maxLifetime: TimeInterval = 43200
    /// Size of one ranged request to the real source.
    public var windowSize = 4 << 20
    public var maxUpstreamPerSession = 3
    public var maxRedirects = 3
    public var maxSessions = 2
    public var retryDelay: TimeInterval = 0.4

    public init() {}
}

/// Who a session belongs to. A new session of the same owner replaces the old one.
public enum RelayOwner: Hashable, Sendable {
    case cast(CastTarget)
    case airPlay
}

/// Which peers may fetch a session.
public enum RelayPeerRule: Equatable, Sendable {
    case any
    case expected(Set<String>)
}

public enum RelayEndReason: String, Sendable {
    case userStopped, receiverEnded, loadFailed, replaced, neverUsed, expiredLifetime
    case addressChanged, upstreamRejected, appClosing, directLinkDisabled
}

/// A short random label for the logs. It is NOT derived from the token.
public struct RelaySessionID: Hashable, Sendable {
    public let label: String

    public init(label: String) {
        self.label = label
    }
}

/// Failures of the relay. Integers only: never a URL, a host or a system message that could carry one.
public enum RelayError: Error, Equatable, Sendable {
    case notFound
    case upstreamNoRanges
    case upstreamRejected(status: Int)
    case upstreamNotMedia
    case upstreamUnreachable(code: Int)
    case upstreamBadRange
    case blockedTarget
    case rangeNotSatisfiable(total: Int64?)
    case tooManySessions
}
