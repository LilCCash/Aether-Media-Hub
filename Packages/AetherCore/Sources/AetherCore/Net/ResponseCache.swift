import Foundation

/// What kind of payload is cached; decides default TTL and whether it may be written to disk.
public enum CacheKind: String, Codable, Sendable, CaseIterable {
    case manifest
    case catalog
    case meta
    case stream
    case subtitles

    /// Default freshness in seconds when the addon sends no `cacheMaxAge`.
    public var defaultMaxAge: Int {
        switch self {
        case .manifest: return 3600
        case .catalog: return 600
        case .meta: return 6 * 3600
        case .stream: return 60
        case .subtitles: return 3600
        }
    }

    /// How long a stale entry may be served when the network fails and the addon sent no `staleError`.
    public var defaultStaleError: Int {
        switch self {
        case .manifest: return 7 * 86400
        case .catalog: return 86400
        case .meta: return 7 * 86400
        case .stream: return 0
        case .subtitles: return 86400
        }
    }

    /// Stream URLs frequently embed short-lived tokens: keep them in memory only.
    public var persistsToDisk: Bool { return self != .stream }

    public static func forResource(_ resource: String) -> CacheKind {
        switch resource {
        case ResourceName.catalog, ResourceName.addonCatalog: return .catalog
        case ResourceName.meta: return .meta
        case ResourceName.stream: return .stream
        case ResourceName.subtitles: return .subtitles
        default: return .catalog
        }
    }
}

public struct CacheLookup: Sendable {
    public var data: Data
    public var storedAt: Date
    public var isFresh: Bool
    /// Whether this (possibly stale) entry may still be served after a network failure.
    public var usableAsStale: Bool
}

/// Memory + optional disk cache honouring addon-provided `cacheMaxAge` / `staleError`.
public actor ResponseCache {
    private struct Entry: Codable {
        var key: String
        var kind: CacheKind
        var storedAt: Date
        var maxAge: Int
        var staleError: Int
        var data: Data
    }

    private var memory: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private var memoryBytes = 0
    private let directory: URL?
    private let maxMemoryEntries: Int
    private let maxMemoryBytes: Int
    private let maxDiskBytes: Int64
    private let maxDiskAge: TimeInterval
    private var diskBytesEstimate: Int64?
    private let now: @Sendable () -> Date

    /// Defaults: 400 entries **and** 48 MiB in memory; 256 MiB on disk, and files untouched for 30 days are dropped
    /// (well past every default stale window, so offline / stale serving keeps working as before).
    public init(directory: URL?, maxMemoryEntries: Int = 400, maxMemoryBytes: Int = 48 * 1_048_576,
                maxDiskBytes: Int64 = 256 * 1_048_576, maxDiskAge: TimeInterval = 30 * 86400,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.maxMemoryEntries = max(1, maxMemoryEntries)
        self.maxMemoryBytes = max(1, maxMemoryBytes)
        self.maxDiskBytes = max(1, maxDiskBytes)
        self.maxDiskAge = maxDiskAge
        self.now = now
        if let directory = directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Cache keys are request URLs, which can embed addon secrets; only their hash is kept in memory and on disk.
    private func fileURL(forHash hash: String) -> URL? {
        guard let directory = directory else { return nil }
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    public func lookup(_ rawKey: String) -> CacheLookup? {
        let key = Hashing.sha256Hex(rawKey)
        var entry = memory[key]
        if entry == nil, let url = fileURL(forHash: key), let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(Entry.self, from: data), decoded.key == key {
                entry = decoded
                insertMemory(decoded)
                // Disk eviction is least-recently-used by modification date.
                try? FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
            } else {
                // Corrupt or foreign file: drop it so it stops costing a read on every lookup.
                try? FileManager.default.removeItem(at: url)
                diskBytesEstimate = diskBytesEstimate.map { $0 - Int64(data.count) }
            }
        }
        guard let found = entry else { return nil }
        if memory[key] != nil { touch(key) }
        let age = now().timeIntervalSince(found.storedAt)
        let fresh = age >= 0 && age < Double(found.maxAge)
        let staleOK = age >= 0 && age < Double(found.maxAge + found.staleError)
        return CacheLookup(data: found.data, storedAt: found.storedAt, isFresh: fresh, usableAsStale: staleOK)
    }

    public func store(key rawKey: String, data: Data, kind: CacheKind, hints: CacheHints = CacheHints()) {
        let key = Hashing.sha256Hex(rawKey)
        let maxAge = max(0, hints.maxAge ?? kind.defaultMaxAge)
        let staleError = max(0, hints.staleError ?? kind.defaultStaleError)
        let entry = Entry(key: key, kind: kind, storedAt: now(), maxAge: maxAge, staleError: staleError, data: data)
        insertMemory(entry)
        if kind.persistsToDisk, let url = fileURL(forHash: key), let encoded = try? JSONEncoder().encode(entry) {
            // A full disk makes the write fail: the entry simply stays memory-only.
            if (try? encoded.write(to: url, options: .atomic)) != nil {
                if diskBytesEstimate == nil { pruneDisk() } else { diskBytesEstimate! += Int64(encoded.count) }
                if let estimate = diskBytesEstimate, estimate > maxDiskBytes { pruneDisk() }
            }
        }
    }

    public func remove(key rawKey: String) {
        let key = Hashing.sha256Hex(rawKey)
        dropMemory(key)
        if let url = fileURL(forHash: key) { try? FileManager.default.removeItem(at: url) }
    }

    /// Removes cached entries of the given kinds (all kinds when nil) from memory and disk.
    public func clear(kinds: Set<CacheKind>? = nil) {
        if let kinds = kinds {
            for (key, entry) in memory where kinds.contains(entry.kind) {
                dropMemory(key)
            }
        } else {
            memory.removeAll()
            accessOrder.removeAll()
            memoryBytes = 0
        }
        diskBytesEstimate = nil
        guard let directory = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            if let kinds = kinds {
                guard let data = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(Entry.self, from: data),
                      kinds.contains(entry.kind) else { continue }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Bytes used on disk.
    public func diskUsage() -> Int64 {
        guard let directory = directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for file in files {
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    public var memoryEntryCount: Int { return memory.count }
    public var memoryByteCount: Int { return memoryBytes }

    /// Drops disk files untouched for longer than `maxDiskAge`, then the least recently used ones until the disk
    /// budget is met (to 90%, so pruning does not run on every write). Runs on the first write after launch and
    /// whenever the budget is exceeded.
    public func pruneDisk() {
        guard let directory = directory else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            diskBytesEstimate = 0
            return
        }
        let cutoff = now().addingTimeInterval(-maxDiskAge)
        var kept: [(url: URL, size: Int64, date: Date)] = []
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? .distantPast
            if date < cutoff {
                try? fm.removeItem(at: file)
            } else {
                kept.append((file, size, date))
            }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.size }
        if total > maxDiskBytes {
            let target = maxDiskBytes / 10 * 9
            for file in kept.sorted(by: { $0.date < $1.date }) where total > target {
                try? fm.removeItem(at: file.url)
                total -= file.size
            }
        }
        diskBytesEstimate = total
    }

    // MARK: Private

    private func insertMemory(_ entry: Entry) {
        dropMemory(entry.key)
        // An entry larger than the whole budget is served from disk only.
        guard entry.data.count <= maxMemoryBytes else { return }
        memory[entry.key] = entry
        memoryBytes += entry.data.count
        touch(entry.key)
        while memory.count > maxMemoryEntries || memoryBytes > maxMemoryBytes, let oldest = accessOrder.first {
            dropMemory(oldest)
        }
    }

    private func dropMemory(_ key: String) {
        if let old = memory.removeValue(forKey: key) { memoryBytes -= old.data.count }
        accessOrder.removeAll(where: { $0 == key })
    }

    private func touch(_ key: String) {
        if let index = accessOrder.firstIndex(of: key) { accessOrder.remove(at: index) }
        accessOrder.append(key)
    }
}
