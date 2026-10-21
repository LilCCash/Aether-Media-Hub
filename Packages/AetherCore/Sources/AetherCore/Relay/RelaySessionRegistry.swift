import Foundation

/// What the server gets when a request is allowed. It names the source to read from and nothing else.
public struct RelayGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: RelaySessionID
    public let leaf: String
    public let source: RelaySource

    public var description: String { return "RelayGrant" }
    public var debugDescription: String { return "RelayGrant" }
    public var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
}

/// The only outcomes of asking whether a request may be served. There is no reason attached to a denial: an unknown token, a revoked or
/// expired session, a wrong file name and a wrong peer all look the same to the caller (and so on the wire).
public enum RelayAuthorization: Sendable {
    case granted(RelayGrant)
    case denied
}

/// The sessions the relay serves. A session is a secret address (`/r/<token>/<leaf>`) bound to one source and one owner.
///
/// Only the SHA-256 of a token is kept, so nothing that can be dumped from here is an address that works. A session ends when its owner
/// asks, when a newer session of the same owner replaces it, when nobody ever used it within the armed window, or at the lifetime cap.
public final class RelaySessionRegistry: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let systemRandomBytes: @Sendable (Int) -> [UInt8] = { count in
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    private struct Session {
        let id: RelaySessionID
        let tokenHash: String
        /// The file name the session serves; nil when the source decides which names exist (HLS pieces).
        let leaf: String?
        let source: RelaySource
        let owner: RelayOwner
        let peerRule: RelayPeerRule
        let created: Date
        var firstRequest: Date?
        var requests = 0
        var bytes: Int64 = 0
    }

    private let limits: RelayLimits
    private let clock: @Sendable () -> Date
    private let randomBytes: @Sendable (Int) -> [UInt8]
    private let lock = NSLock()
    private var sessions: [Session] = []
    private var observers: [@Sendable (RelaySessionID, RelayEndReason) -> Void] = []
    private var _ownAddress: String?

    public init(limits: RelayLimits = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                randomBytes: @escaping @Sendable (Int) -> [UInt8] = RelaySessionRegistry.systemRandomBytes) {
        self.limits = limits
        self.clock = now
        self.randomBytes = randomBytes
    }

    // MARK: Redaction

    public var description: String { return "RelaySessionRegistry" }
    public var debugDescription: String { return "RelaySessionRegistry" }
    public var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .class) }

    // MARK: Queries

    /// The phone's own address on the network the relay listens on. The AirPlay session's local player reads from it.
    public var ownAddress: String? {
        get { return locked { _ownAddress } }
        set { locked { _ownAddress = newValue } }
    }

    public var sessionCount: Int { return locked { sessions.count } }

    public func isActive(_ id: RelaySessionID) -> Bool {
        return locked { sessions.contains { $0.id == id } }
    }

    public func sessionID(for owner: RelayOwner) -> RelaySessionID? {
        return locked { sessions.first { $0.owner == owner }?.id }
    }

    public func requestsServed(_ id: RelaySessionID) -> Int {
        return locked { sessions.first { $0.id == id }?.requests ?? 0 }
    }

    public func bytesServed(_ id: RelaySessionID) -> Int64 {
        return locked { sessions.first { $0.id == id }?.bytes ?? 0 }
    }

    /// Called (on whatever thread ended the session, never under the registry's lock) every time a session ends.
    public func observeRevocations(_ observer: @escaping @Sendable (RelaySessionID, RelayEndReason) -> Void) {
        locked { observers.append(observer) }
    }

    // MARK: Lifecycle

    /// Creates a session for `owner`. A session the same owner already has is revoked with `.replaced`. Throws `tooManySessions` when
    /// that would leave more than `limits.maxSessions`; nothing is changed then.
    public func create(source: RelaySource, leaf: String?, owner: RelayOwner, peerRule: RelayPeerRule) throws -> (id: RelaySessionID, token: String) {
        var replaced: Session?
        var created: (id: RelaySessionID, token: String)?
        try locked {
            let existing = sessions.firstIndex { $0.owner == owner }
            let remaining = sessions.count - (existing == nil ? 0 : 1)
            if remaining >= limits.maxSessions { throw RelayError.tooManySessions }
            if let index = existing { replaced = sessions.remove(at: index) }

            var token = makeToken(using: randomBytes)
            var attempts = 0
            while sessions.contains(where: { $0.tokenHash == Hashing.sha256Hex(token) }) {
                attempts += 1
                if attempts > 4 {
                    token = makeToken(using: RelaySessionRegistry.systemRandomBytes)
                } else {
                    token = makeToken(using: randomBytes)
                }
            }
            var label = makeLabel()
            var labelAttempts = 0
            while sessions.contains(where: { $0.id.label == label }) && labelAttempts < 8 {
                labelAttempts += 1
                label = makeLabel()
            }
            let id = RelaySessionID(label: label)
            sessions.append(Session(id: id, tokenHash: Hashing.sha256Hex(token), leaf: leaf, source: source, owner: owner,
                                    peerRule: peerRule, created: clock()))
            created = (id, token)
        }
        if let old = replaced { finish([(old, .replaced)]) }
        guard let result = created else { throw RelayError.tooManySessions }
        return result
    }

    private func makeToken(using bytesSource: @Sendable (Int) -> [UInt8]) -> String {
        var bytes = bytesSource(32)
        if bytes.count != 32 { bytes = RelaySessionRegistry.systemRandomBytes(32) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func makeLabel() -> String {
        var bytes = RelaySessionRegistry.systemRandomBytes(3)
        if bytes.count != 3 { bytes = [0, 0, 0] }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isWellFormed(_ token: String) -> Bool {
        return token.utf8.count == 64 && token.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    public func authorize(token: String, leaf: String, peer: String) -> RelayAuthorization {
        guard RelaySessionRegistry.isWellFormed(token) else { return .denied }
        let hash = Hashing.sha256Hex(token)
        var ended: (Session, RelayEndReason)?
        var result = RelayAuthorization.denied
        locked {
            guard let index = sessions.firstIndex(where: { $0.tokenHash == hash }) else { return }
            let session = sessions[index]
            if let reason = endReason(of: session, at: clock()) {
                sessions.remove(at: index)
                ended = (session, reason)
            } else if (session.leaf == nil || session.leaf == leaf) && allows(peer, for: session) {
                result = .granted(RelayGrant(id: session.id, leaf: leaf, source: session.source))
            }
        }
        if let ended = ended { finish([ended]) }
        return result
    }

    private func allows(_ peer: String, for session: Session) -> Bool {
        if session.owner == .airPlay, let own = _ownAddress, peer == own { return true }
        switch session.peerRule {
        case .any: return true
        case .expected(let peers): return peers.contains(peer)
        }
    }

    private func endReason(of session: Session, at now: Date) -> RelayEndReason? {
        let age = now.timeIntervalSince(session.created)
        if age >= limits.maxLifetime { return .expiredLifetime }
        if session.firstRequest == nil && age >= limits.armedWindow { return .neverUsed }
        return nil
    }

    /// A request for the session was granted and is being served.
    public func noteRequest(_ id: RelaySessionID) {
        locked {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            if sessions[index].firstRequest == nil { sessions[index].firstRequest = clock() }
            sessions[index].requests += 1
        }
    }

    public func noteServed(_ id: RelaySessionID, bytes: Int64) {
        locked {
            guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
            sessions[index].bytes += max(0, bytes)
        }
    }

    public func revoke(_ id: RelaySessionID, reason: RelayEndReason) {
        var ended: [(Session, RelayEndReason)] = []
        locked {
            if let index = sessions.firstIndex(where: { $0.id == id }) { ended = [(sessions.remove(at: index), reason)] }
        }
        finish(ended)
    }

    public func revoke(owner: RelayOwner, reason: RelayEndReason) {
        var ended: [(Session, RelayEndReason)] = []
        locked {
            if let index = sessions.firstIndex(where: { $0.owner == owner }) { ended = [(sessions.remove(at: index), reason)] }
        }
        finish(ended)
    }

    public func revokeAll(reason: RelayEndReason) {
        var ended: [(Session, RelayEndReason)] = []
        locked {
            ended = sessions.map { ($0, reason) }
            sessions.removeAll()
        }
        finish(ended)
    }

    /// Ends the sessions nobody used in time and the ones past the lifetime cap. The server calls it every few seconds.
    public func sweep() {
        var ended: [(Session, RelayEndReason)] = []
        locked {
            let now = clock()
            var kept: [Session] = []
            for session in sessions {
                if let reason = endReason(of: session, at: now) { ended.append((session, reason)) } else { kept.append(session) }
            }
            sessions = kept
        }
        finish(ended)
    }

    // MARK: Plumbing

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Closes the sources and tells the observers, outside the lock (an observer may call back into the registry).
    private func finish(_ ended: [(Session, RelayEndReason)]) {
        guard !ended.isEmpty else { return }
        let current = locked { observers }
        for (session, reason) in ended {
            session.source.close()
            for observer in current { observer(session.id, reason) }
        }
    }
}
