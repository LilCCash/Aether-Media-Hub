import Foundation

public extension JSONEncoder {
    /// Deterministic output (sorted keys, ISO-8601 dates) so backups and tests are stable.
    static func aether(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if pretty { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return encoder
    }
}

public extension JSONDecoder {
    static func aether() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Atomic JSON persistence with a one-generation backup and quarantine of unreadable files.
public final class JSONFileStore<Value: Codable>: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private var backupURL: URL { return url.appendingPathExtension("bak") }
    private var corruptURL: URL { return url.appendingPathExtension("corrupt") }

    /// Returns the stored value, falling back to the backup if the main file is unreadable.
    public func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder.aether()
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let data = try? Data(contentsOf: backupURL), let value = try? decoder.decode(Value.self, from: data) {
                return value
            }
            return nil
        }
        if let data = try? Data(contentsOf: url), let value = try? decoder.decode(Value.self, from: data) {
            return value
        }
        // Main file exists but cannot be decoded: keep it for diagnosis and try the backup.
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: url, to: corruptURL)
        if let data = try? Data(contentsOf: backupURL), let value = try? decoder.decode(Value.self, from: data) {
            return value
        }
        return nil
    }

    public func save(_ value: Value) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder.aether().encode(value)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: .atomic)
    }

    public func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: corruptURL)
    }

    public func exists() -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// Storage for secrets (addon URLs embedding API keys, future tokens). The app provides a Keychain implementation.
public protocol SecretStore: Sendable {
    func set(_ value: String, for key: String) throws
    func get(_ key: String) throws -> String?
    func remove(_ key: String) throws
    func allKeys(prefix: String) throws -> [String]
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func set(_ value: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    public func get(_ key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }

    public func allKeys(prefix: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}
