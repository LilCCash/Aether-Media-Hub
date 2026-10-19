import Foundation

/// Counting semaphore for async code: bounds the number of simultaneous addon requests.
public actor ConcurrencyLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public var activeCount: Int { return running }

    private func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // Hand the permit directly to the next waiter; `running` stays unchanged.
            let next = waiters.removeFirst()
            next.resume()
        }
    }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
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
