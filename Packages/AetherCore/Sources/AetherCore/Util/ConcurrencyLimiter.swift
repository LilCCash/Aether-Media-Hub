import Foundation

/// Counting semaphore for async code: bounds the number of simultaneous addon requests.
///
/// A task cancelled while it waits leaves the queue at once (it never runs its operation and never holds a permit),
/// and a wait can be bounded with `maxWait`, so a congested limiter cannot keep a caller past its own deadline.
public actor ConcurrencyLimiter {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        var timer: Task<Void, Never>?
    }

    private let limit: Int
    private var running = 0
    private var nextID: UInt64 = 0
    private var order: [UInt64] = []
    private var waiters: [UInt64: Waiter] = [:]

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var activeCount: Int { return running }
    public var waitingCount: Int { return waiters.count }

    private func acquire(id: UInt64, maxWait: TimeInterval?) async throws {
        try Task.checkCancellation()
        if running < limit && order.isEmpty {
            running += 1
            return
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Runs synchronously on the actor: a cancellation hop scheduled meanwhile finds the waiter registered.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                var waiter = Waiter(continuation: continuation, timer: nil)
                if let maxWait = maxWait {
                    waiter.timer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(max(0, maxWait) * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        await self?.abandon(id, with: AddonError.timeout)
                    }
                }
                waiters[id] = waiter
                order.append(id)
            }
        }, onCancel: {
            Task { await self.abandon(id, with: CancellationError()) }
        })
    }

    /// Removes a waiter that has not been granted a permit yet; a waiter already granted is left alone.
    private func abandon(_ id: UInt64, with error: Error) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        waiter.timer?.cancel()
        waiter.continuation.resume(throwing: error)
    }

    private func release() {
        guard !order.isEmpty else {
            running -= 1
            return
        }
        // Hand the permit directly to the next waiter; `running` stays unchanged.
        let id = order.removeFirst()
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.timer?.cancel()
            waiter.continuation.resume()
        }
    }

    /// Runs `operation` while holding a permit. `maxWait` bounds the time spent queued (throws `AddonError.timeout`).
    public func withPermit<T: Sendable>(maxWait: TimeInterval? = nil,
                                        _ operation: @Sendable () async throws -> T) async throws -> T {
        nextID &+= 1
        let id = nextID
        try await acquire(id: id, maxWait: maxWait)
        // Cancelled right as the permit arrived: give it back without running the operation.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }
}
