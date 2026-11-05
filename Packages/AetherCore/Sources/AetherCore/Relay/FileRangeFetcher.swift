import Foundation

/// The same job as the network fetcher, for a file on this phone (a finished download): its size, and exact windows of it. It lets the
/// converter for AVPlayer work offline, from the file instead of a link. Nothing about the file's path is ever put in an error.
public final class FileRangeFetcher: RelayRangeFetcher, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var invalidated = false

    public init(url: URL) { self.url = url }

    public func probe() async throws -> RelayResource {
        guard !isInvalidated else { throw RelayError.upstreamUnreachable(code: -999) }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard let length = size, length > 0 else { throw RelayError.notFound }
        return RelayResource(contentType: "application/octet-stream", length: length, acceptsRanges: true)
    }

    public func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        guard range.lowerBound >= 0 else { throw RelayError.upstreamBadRange }
        guard !isInvalidated else { throw RelayError.upstreamUnreachable(code: -999) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw RelayError.notFound }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(range.lowerBound))
            let wanted = Int(range.upperBound - range.lowerBound + 1)
            let data = try handle.read(upToCount: wanted) ?? Data()
            guard !data.isEmpty else { throw RelayError.upstreamBadRange }
            return data
        } catch let error as RelayError {
            throw error
        } catch {
            throw RelayError.upstreamUnreachable(code: -1)
        }
    }

    public func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    private var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invalidated
    }
}
