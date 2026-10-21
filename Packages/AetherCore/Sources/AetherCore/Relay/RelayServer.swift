import Foundation
#if canImport(Network)
import Network

public enum RelayServerError: Error, Equatable, Sendable {
    case couldNotStart
    case stoppedWhileStarting
}

/// The listener of the relay: a small HTTP server that answers GET, HEAD and OPTIONS for the sessions in a `RelaySessionRegistry`.
///
/// It listens on one IPv4 address of the phone's Wi-Fi, only accepts peers of that network, and answers everything that is not a
/// granted request with the same 404. Bodies are read from the session's `RelaySource` one chunk at a time and handed to the network in
/// 128 KiB blocks, the next one only after the previous was processed, so a slow receiver slows the source down instead of filling memory.
public final class RelayServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// The address to listen on (the phone's Wi-Fi address, or 127.0.0.1 in tests).
        public var bindAddress: String
        /// The network the receivers live on. Peers outside it are dropped without an answer.
        public var lan: LANInterface?
        /// Tests connect from 127.0.0.1.
        public var allowLoopbackPeers: Bool
        public var limits: RelayLimits
        public var now: @Sendable () -> Date

        public init(bindAddress: String, lan: LANInterface? = nil, allowLoopbackPeers: Bool = false, limits: RelayLimits = .standard,
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.bindAddress = bindAddress
            self.lan = lan
            self.allowLoopbackPeers = allowLoopbackPeers
            self.limits = limits
            self.now = now
        }
    }

    static let blockSize = 128 * 1024

    private let registry: RelaySessionRegistry
    private var configuration: Configuration
    private let emit: @Sendable (RelayLogEvent) -> Void
    fileprivate let queue = DispatchQueue(label: "app.aether.relay")

    private let stateLock = NSLock()
    private var _port: UInt16?

    // Confined to `queue`.
    private var listener: NWListener?
    private var starting = false
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var startTimeout: DispatchWorkItem?
    private var sweepTimer: DispatchSourceTimer?
    private var connections: [ObjectIdentifier: RelayConnection] = [:]
    private var announceAsRestart = false

    /// Called (on a global queue) when a listener that was running stops by itself (the network went away, the app was suspended).
    public var onFailure: (@Sendable () -> Void)?

    public init(registry: RelaySessionRegistry, configuration: Configuration, log: @escaping @Sendable (RelayLogEvent) -> Void) {
        self.registry = registry
        self.configuration = configuration
        self.emit = log
        registry.observeRevocations { [weak self] id, _ in self?.sessionEnded(id) }
    }

    // MARK: Public

    public var port: UInt16? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _port
    }

    public var isRunning: Bool { return port != nil }

    /// Starts listening (idempotent) and returns the port. Waits for the listener to be ready, at most five seconds.
    @discardableResult
    public func start(preferredPort: UInt16? = nil) async throws -> UInt16 {
        if let port = port { return port }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            queue.async {
                if let port = self.port {
                    continuation.resume(returning: port)
                    return
                }
                self.waiters.append(continuation)
                if !self.starting { self.beginListening(preferred: preferredPort, wildcard: false) }
            }
        }
    }

    /// Stops and starts again on the same port, so the addresses already handed out stay valid.
    public func restart() async throws {
        let previous = port
        queue.sync {
            self.announceAsRestart = true
            self.stopOnQueue(announce: false)
        }
        _ = try await start(preferredPort: previous)
    }

    public func stop() {
        queue.sync { self.stopOnQueue(announce: true) }
    }

    /// The network the phone is on changed.
    public func update(lan: LANInterface?) {
        queue.async { self.configuration.lan = lan }
    }

    /// The address a receiver is given for a session: `http://<host>:<port>/r/<token>/<leaf>`. Nil when the server is not running or an
    /// argument is not of the expected shape.
    public func url(host: String, token: String, leaf: String) -> URL? {
        guard let port = port, IPAddress.parse(host) != nil, !host.contains(":") else { return nil }
        guard token.utf8.count == 64, token.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else { return nil }
        guard !leaf.isEmpty, leaf.utf8.count <= 64, leaf.utf8.allSatisfy({
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }) else { return nil }
        return URL(string: "http://\(host):\(port)/r/\(token)/\(leaf)")
    }

    // MARK: Listener (on the queue)

    private func setPort(_ value: UInt16?) {
        stateLock.lock()
        _port = value
        stateLock.unlock()
    }

    private func makeParameters(preferred: UInt16?, wildcard: Bool) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        if !wildcard {
            let port = preferred.flatMap { NWEndpoint.Port(rawValue: $0) } ?? NWEndpoint.Port.any
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(configuration.bindAddress), port: port)
        }
        return parameters
    }

    /// Binds to the Wi-Fi address; if the system refuses that, listens on every interface instead. Either way the peers are checked
    /// against the Wi-Fi subnet before anything is read from them.
    private func beginListening(preferred: UInt16?, wildcard: Bool) {
        starting = true
        discardListener()
        let created: NWListener
        do {
            let parameters = makeParameters(preferred: preferred, wildcard: wildcard)
            if wildcard {
                created = try NWListener(using: parameters, on: preferred.flatMap { NWEndpoint.Port(rawValue: $0) } ?? NWEndpoint.Port.any)
            } else {
                created = try NWListener(using: parameters)
            }
        } catch {
            if wildcard { failStart() } else { beginListening(preferred: preferred, wildcard: true) }
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self = self, let created = created else { return }
            self.listenerChanged(state, created, preferred: preferred, wildcard: wildcard)
        }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        created.start(queue: queue)

        startTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, self.starting else { return }
            self.failStart()
        }
        startTimeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func listenerChanged(_ state: NWListener.State, _ created: NWListener, preferred: UInt16?, wildcard: Bool) {
        guard listener === created else { return }
        switch state {
        case .ready:
            guard let value = created.port?.rawValue else {
                if wildcard { failStart() } else { beginListening(preferred: preferred, wildcard: true) }
                return
            }
            starting = false
            startTimeout?.cancel()
            setPort(value)
            startSweeping()
            emit(.listener(announceAsRestart ? .restarted(port: value) : .started(port: value)))
            announceAsRestart = false
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: value) }
        case .failed:
            if starting {
                if wildcard { failStart() } else { beginListening(preferred: preferred, wildcard: true) }
            } else {
                emit(.listener(.failed))
                stopOnQueue(announce: false)
                if let callback = onFailure { DispatchQueue.global().async { callback() } }
            }
        default:
            break
        }
    }

    private func failStart() {
        starting = false
        startTimeout?.cancel()
        discardListener()
        emit(.listener(.failed))
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: RelayServerError.couldNotStart) }
    }

    private func discardListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func stopOnQueue(announce: Bool) {
        let wasRunning = port != nil
        startTimeout?.cancel()
        sweepTimer?.cancel()
        sweepTimer = nil
        discardListener()
        setPort(nil)
        let open = Array(connections.values)
        connections.removeAll()
        for connection in open { connection.abort() }
        starting = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: RelayServerError.stoppedWhileStarting) }
        if announce && wasRunning { emit(.listener(.stopped)) }
    }

    private func startSweeping() {
        sweepTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.registry.sweep() }
        sweepTimer = timer
        timer.resume()
    }

    private func sessionEnded(_ id: RelaySessionID) {
        queue.async {
            for connection in self.connections.values where connection.sessionID == id { connection.abort() }
        }
    }

    // MARK: Connections (on the queue)

    private static func dotted(_ data: Data) -> String? {
        guard data.count == 4 else { return nil }
        return data.map { String($0) }.joined(separator: ".")
    }

    /// The peer as dotted IPv4, or nil for anything else (names, real IPv6).
    static func peerAddress(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            return dotted(address.rawValue)
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff else { return nil }
            return dotted(Data(bytes[12..<16]))
        default:
            return nil
        }
    }

    private func accept(_ nw: NWConnection) {
        guard let peer = RelayServer.peerAddress(of: nw.endpoint) else {
            drop(nw)
            return
        }
        let allowed = peer.hasPrefix("127.") ? configuration.allowLoopbackPeers : (configuration.lan?.contains(peer: peer) ?? false)
        guard allowed else {
            drop(nw)
            return
        }
        let limits = configuration.limits
        if connections.count >= limits.maxConnections {
            emit(.limitHit(.connections))
            drop(nw)
            return
        }
        if connections.values.filter({ $0.peer == peer }).count >= limits.maxConnectionsPerPeer {
            emit(.limitHit(.perPeer))
            drop(nw)
            return
        }
        let connection = RelayConnection(connection: nw, peer: peer, server: self, writeStall: limits.writeStallTimeout)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        nw.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                if let connection = connection { connection.markClosed() }
                self?.connections[key] = nil
            default:
                break
            }
        }
        nw.start(queue: queue)

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self = self, let connection = connection, !connection.headReceived else { return }
            self.emit(.limitHit(.headTimeout))
            connection.abort()
        }
        connection.headTimer = timeout
        queue.asyncAfter(deadline: .now() + limits.headTimeout, execute: timeout)
        receive(on: connection)
    }

    /// Closes a connection that was never served. It is started first so the system really closes the socket.
    private func drop(_ nw: NWConnection) {
        nw.start(queue: queue)
        nw.cancel()
    }

    fileprivate func forget(_ connection: RelayConnection) {
        queue.async { self.connections[ObjectIdentifier(connection)] = nil }
    }

    fileprivate func stalled(_ connection: RelayConnection) {
        emit(.limitHit(.writeStall))
        connection.abort()
    }

    private func receive(on connection: RelayConnection) {
        connection.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection, !connection.isClosed else { return }
            if let data = data, !data.isEmpty {
                connection.buffer.append(data)
                self.process(connection)
            } else if error != nil || isComplete {
                connection.abort()
            }
        }
    }

    private func process(_ connection: RelayConnection) {
        switch RelayRequestParser.parse(connection.buffer, limits: configuration.limits) {
        case .needMoreData:
            receive(on: connection)
        case .reject(let status):
            connection.headReceived = true
            connection.headTimer?.cancel()
            if status != 404 { emit(.limitHit(.malformedRequest)) }
            let bytes = status == 404 ? RelayHeaderPolicy.notFoundBytes : RelayHeaderPolicy.errorHead(status: status).serialized()
            connection.respondAndClose(bytes)
        case .request(let head, _):
            connection.headReceived = true
            connection.headTimer?.cancel()
            handle(head, on: connection)
        }
    }

    private func handle(_ head: RelayRequestHead, on connection: RelayConnection) {
        guard case .granted(let grant) = registry.authorize(token: head.token, leaf: head.leaf, peer: connection.peer) else {
            connection.respondAndClose(RelayHeaderPolicy.notFoundBytes)
            return
        }
        registry.noteRequest(grant.id)
        connection.sessionID = grant.id
        // The session may have ended between the check and now.
        guard registry.isActive(grant.id) else {
            connection.abort()
            return
        }
        if head.method == .options {
            connection.respondAndClose(RelayHeaderPolicy.optionsHead().serialized())
            emit(.served(grant.id, method: "OPTIONS", status: 204, ranged: false, bytes: 0))
            return
        }
        let now = configuration.now()
        connection.setTask(Task { [weak self] in
            await self?.serve(head, grant: grant, on: connection, date: now)
        })
    }

    // MARK: Serving (off the queue)

    private static func failure(for error: RelayError) -> RelayUpstreamFailure? {
        switch error {
        case .upstreamRejected(let status): return .rejected(status: status)
        case .upstreamUnreachable(let code): return .unreachable(code: code)
        case .upstreamNoRanges: return .noRanges
        case .upstreamBadRange: return .badRange
        case .upstreamNotMedia: return .notMedia
        case .blockedTarget: return .blocked
        default: return nil
        }
    }

    private func serve(_ head: RelayRequestHead, grant: RelayGrant, on connection: RelayConnection, date: Date) async {
        let id = grant.id
        let methodName = head.method == .head ? "HEAD" : "GET"
        var headSent = false
        do {
            let resource = try await grant.source.resource(named: head.leaf)

            var status = 200
            var bounds: ClosedRange<Int64>?
            var contentRange: String?
            var length = resource.length
            if let total = resource.length {
                if resource.acceptsRanges, case .single(let wanted) = head.range {
                    guard let resolved = wanted.resolve(total: total) else {
                        connection.respondAndClose(RelayHeaderPolicy.errorHead(status: 416, total: total).serialized())
                        emit(.served(id, method: methodName, status: 416, ranged: true, bytes: 0))
                        return
                    }
                    status = 206
                    bounds = resolved
                    contentRange = RelayHeaderPolicy.contentRange(resolved, total: total)
                    length = Int64(resolved.count)
                }
            }
            let responseHead = RelayHeaderPolicy.receiverHead(
                status: status, contentType: resource.contentType, contentLength: length, contentRange: contentRange,
                acceptsRanges: resource.acceptsRanges && resource.length != nil, wantsDLNAFeatures: head.wantsDLNAFeatures, date: date)

            if head.method == .head {
                connection.respondAndClose(responseHead.serialized())
                emit(.served(id, method: "HEAD", status: status, ranged: status == 206, bytes: 0))
                return
            }

            let reader = try await grant.source.open(head.leaf, range: bounds)
            guard connection.attach(reader) else { return }
            try await connection.send(responseHead.serialized(), final: false)
            headSent = true

            var sent: Int64 = 0
            while let chunk = try await reader.next() {
                var data = chunk
                if let declared = length {
                    let remaining = declared - sent
                    if remaining <= 0 { break }
                    if Int64(data.count) > remaining { data = Data(data.prefix(Int(remaining))) }
                }
                var offset = 0
                while offset < data.count {
                    let end = min(offset + RelayServer.blockSize, data.count)
                    try await connection.send(Data(data[(data.startIndex + offset)..<(data.startIndex + end)]), final: false)
                    offset = end
                }
                sent += Int64(data.count)
                registry.noteServed(id, bytes: Int64(data.count))
            }
            if let declared = length, sent != declared {
                // Never present a short body as a complete one.
                emit(.upstreamFailure(id, .badRange))
                connection.abort()
                return
            }
            try await connection.send(Data(), final: true)
            connection.markFinished()
            emit(.served(id, method: "GET", status: status, ranged: status == 206, bytes: sent))
        } catch {
            if connection.isClosed { return }
            let relayError = error as? RelayError
            if let relayError = relayError, let reason = RelayServer.failure(for: relayError) { emit(.upstreamFailure(id, reason)) }
            if headSent {
                connection.abort()
            } else if relayError == .notFound {
                connection.respondAndClose(RelayHeaderPolicy.notFoundBytes)
            } else {
                connection.respondAndClose(RelayHeaderPolicy.errorHead(status: 502).serialized())
            }
        }
    }
}

private enum ConnectionClosed: Error {
    case closed
}

/// One accepted connection. The fields marked "queue" are only touched on the server's queue; the rest is guarded by `lock`.
fileprivate final class RelayConnection: @unchecked Sendable {
    let connection: NWConnection
    let peer: String
    private weak var server: RelayServer?

    // queue
    var buffer = Data()
    var headTimer: DispatchWorkItem?
    var headReceived = false

    private let lock = NSLock()
    private var closed = false
    private var reader: RelayBodyReader?
    private var task: Task<Void, Never>?
    private var _sessionID: RelaySessionID?

    private let writeStall: TimeInterval

    init(connection: NWConnection, peer: String, server: RelayServer, writeStall: TimeInterval) {
        self.connection = connection
        self.peer = peer
        self.server = server
        self.writeStall = writeStall
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var sessionID: RelaySessionID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sessionID
        }
        set {
            lock.lock()
            _sessionID = newValue
            lock.unlock()
        }
    }

    /// Hands the body reader to the connection. False (and the reader is cancelled) when the connection is already closed.
    func attach(_ reader: RelayBodyReader) -> Bool {
        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed { self.reader = reader }
        lock.unlock()
        if alreadyClosed { reader.cancel() }
        return !alreadyClosed
    }

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyClosed = closed
        if !alreadyClosed { self.task = task }
        lock.unlock()
        if alreadyClosed { task.cancel() }
    }

    /// Records that the connection is gone (called when the system reports it failed or cancelled).
    func markClosed() {
        let (reader, task) = takeResources()
        reader?.cancel()
        task?.cancel()
    }

    private func takeResources() -> (RelayBodyReader?, Task<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        let current = (reader, task)
        reader = nil
        task = nil
        return current
    }

    /// Ends the connection at once, dropping whatever was not sent.
    func abort() {
        markClosed()
        headTimer?.cancel()
        connection.forceCancel()
        server?.forget(self)
    }

    /// The body was sent completely and the final message went out.
    func markFinished() {
        markClosed()
        connection.cancel()
        server?.forget(self)
    }

    /// Sends a complete answer and closes after it is processed.
    func respondAndClose(_ bytes: Data) {
        guard !isClosed else { return }
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.markFinished()
        })
    }

    func send(_ data: Data, final: Bool) async throws {
        guard !isClosed else { throw ConnectionClosed.closed }
        let timeout = server?.queue
        let limit = writeStall
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let stall = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.server?.stalled(self)
            }
            timeout?.asyncAfter(deadline: .now() + limit, execute: stall)
            let context: NWConnection.ContentContext = final ? .finalMessage : .defaultMessage
            connection.send(content: data.isEmpty ? nil : data, contentContext: context, isComplete: final, completion: .contentProcessed { error in
                stall.cancel()
                if error == nil { continuation.resume() } else { continuation.resume(throwing: ConnectionClosed.closed) }
            })
        }
    }
}
#endif
