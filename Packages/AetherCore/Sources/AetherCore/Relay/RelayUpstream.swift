import Foundation

/// The real address of a video and the headers needed to read it. This is the secret the relay exists to keep from the television, so
/// the type cannot be printed, dumped or encoded by accident: `description`, `debugDescription` and the reflection mirror say nothing,
/// and it is deliberately not `Codable`.
public struct RelayUpstream: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    public var description: String { return "RelayUpstream(redatto)" }
    public var debugDescription: String { return "RelayUpstream(redatto)" }
    public var customMirror: Mirror { return Mirror(self, children: [], displayStyle: .struct) }
}
