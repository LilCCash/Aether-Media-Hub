import Foundation

/// Removes secrets from anything that may be logged or exported. Addon URLs routinely embed API keys in the path
/// or query, so URLs are reduced to `scheme://host/…`.
public enum Redactor {
    private static let urlPattern = try! NSRegularExpression(
        pattern: "(?i)\\b(https?|stremio|ftp|rtmp)://(\\[[^\\]]+\\]|[^/\\s:?#\"'<>]+)(:\\d+)?[^\\s\"'<>]*", options: [])
    private static let secretPairPattern = try! NSRegularExpression(
        pattern: "(?i)\\b(api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|pwd|authorization|bearer|auth|session|cookie|key)\\b\\s*[=:]\\s*[^\\s&,;\"']+", options: [])
    private static let emailPattern = try! NSRegularExpression(
        pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.caseInsensitive])
    private static let longTokenPattern = try! NSRegularExpression(
        pattern: "\\b[A-Za-z0-9_\\-]{32,}\\b", options: [])

    public static func redact(_ text: String) -> String {
        var result = text
        result = replace(urlPattern, in: result, template: "$1://$2$3/…")
        result = replace(secretPairPattern, in: result, template: "$1=«redatto»")
        result = replace(emailPattern, in: result, template: "«email»")
        result = replace(longTokenPattern, in: result, template: "«token»")
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}

public enum LogLevel: Int, Codable, Comparable, Sendable {
    case debug = 0, info, warning, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { return lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }
}

public struct LogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var level: LogLevel
    public var category: String
    public var message: String

    public init(id: UUID = UUID(), date: Date, level: LogLevel, category: String, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.message = message
    }
}

/// In-memory ring buffer of redacted log lines. Nothing is sent anywhere; the user may export it explicitly.
public actor DiagnosticLog {
    private var buffer: [LogEntry] = []
    private let capacity: Int
    private var minimumLevel: LogLevel
    private var enabled: Bool
    private let now: @Sendable () -> Date

    public init(capacity: Int = 800, minimumLevel: LogLevel = .info, enabled: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = max(10, capacity)
        self.minimumLevel = minimumLevel
        self.enabled = enabled
        self.now = now
    }

    public func configure(enabled: Bool, verbose: Bool) {
        self.enabled = enabled
        self.minimumLevel = verbose ? .debug : .info
        if !enabled { buffer.removeAll() }
    }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard enabled, level >= minimumLevel else { return }
        let entry = LogEntry(date: now(), level: level, category: category, message: Redactor.redact(message))
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    }

    public func entries() -> [LogEntry] { return buffer }

    public func clear() { buffer.removeAll() }

    /// Plain-text export, already redacted at write time and redacted again defensively.
    public func exportText(header: [String] = []) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = header
        lines.append("— log diagnostico Aether (privo di URL completi e credenziali) —")
        for entry in buffer {
            let line = "\(formatter.string(from: entry.date)) [\(entry.level.label)] \(entry.category): \(entry.message)"
            lines.append(Redactor.redact(line))
        }
        return lines.joined(separator: "\n")
    }
}
