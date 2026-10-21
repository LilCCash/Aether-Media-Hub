import XCTest
@testable import AetherCore
#if canImport(Network)
import Network

// Shared by the tests that talk to the real relay server on 127.0.0.1: a raw TCP client, a reply parser and a log recorder.

final class RelayOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

func relayPollUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        _ = try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

struct RelayTestReply {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func parse(_ data: Data) -> RelayTestReply? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let pieces = statusLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard pieces.count >= 2, let status = Int(pieces[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return RelayTestReply(status: status, headers: headers, body: Data(data[end.upperBound...]))
    }
}

final class RelayRawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.rawclient")
    private let lock = NSLock()
    private var received = Data()
    private var receivedCount = 0
    private var _finished = false
    private var readLimit: Int?
    private let retainBytes: Bool

    init(host: String = "127.0.0.1", port: UInt16, readLimit: Int? = nil, retainBytes: Bool = true) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.readLimit = readLimit
        self.retainBytes = retainBytes
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedCount
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    filefunc markFinished() {
        lock.lock()
        _finished = true
        lock.unlock()
    }

    func connect(timeout: TimeInterval = 3) async -> Bool {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = RelayOnce()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: true) }
                    self?.beginReading()
                case .waiting, .failed, .cancelled:
                    self?.markFinished()
                    if once.take() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.take() { continuation.resume(returning: false) }
            }
        }
    }

    private func beginReading() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.lock.lock()
                self.receivedCount += data.count
                if self.retainBytes { self.received.append(data) }
                let reachedLimit = self.readLimit.map { self.receivedCount >= $0 } ?? false
                self.lock.unlock()
                if reachedLimit { return }      // stop reading: the sender is left to the kernel's buffers
            }
            if isComplete || error != nil {
                self.markFinished()
            } else {
                self.beginReading()
            }
        }
    }

    /// Starts reading again without a limit (to notice the connection being closed).
    func resumeReading() {
        lock.lock()
        readLimit = nil
        lock.unlock()
        beginReading()
    }

    func send(_ bytes: Data) {
        connection.send(content: bytes, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }
}

final class RelayLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ event: RelayLogEvent) {
        lock.lock()
        items.append(event.message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

#endif
