import Foundation

/// Small files served next to a video in the same relay session: the subtitles the phone sends to the receiver. They are made on the
/// phone (already converted to WebVTT or SubRip), so there is no origin to reach and nothing to check.
public struct RelaySidecarFile: Sendable {
    public var leaf: String
    public var contentType: String
    public var data: Data

    public init(leaf: String, contentType: String, data: Data) {
        self.leaf = leaf
        self.contentType = contentType
        self.data = data
    }
}

/// A source that serves `files` and hands every other name to `base` (nil: only the files). The video leaf may say where its subtitle
/// is (`CaptionInfo.sec`, read by Samsung televisions over DLNA).
public final class SidecarRelaySource: RelaySource, @unchecked Sendable {
    private let base: RelaySource?
    private let files: [String: RelaySidecarFile]
    private let lock = NSLock()
    private var _captionURL: String?
    private var _captionLeaf: String?

    public init(base: RelaySource?, files: [RelaySidecarFile]) {
        self.base = base
        var table: [String: RelaySidecarFile] = [:]
        for file in files { table[file.leaf] = file }
        self.files = table
    }

    /// The address of the subtitle a DLNA television should show with the video (set once the session address is known).
    public func setCaption(url: String?, forVideoLeaf leaf: String?) {
        locked { _captionURL = url; _captionLeaf = leaf }
    }

    private func caption(for leaf: String) -> String? {
        return locked { (_captionLeaf == nil || _captionLeaf == leaf) ? _captionURL : nil }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var leaves: [String] { return files.keys.sorted() }

    public func resource(named leaf: String) async throws -> RelayResource {
        if let file = files[leaf] {
            return RelayResource(contentType: file.contentType, length: Int64(file.data.count), acceptsRanges: true)
        }
        guard let base = base else { throw RelayError.notFound }
        var resource = try await base.resource(named: leaf)
        resource.captionURL = caption(for: leaf)
        return resource
    }

    public func open(_ leaf: String, range: ClosedRange<Int64>?) async throws -> RelayBodyReader {
        if let file = files[leaf] { return DataBodyReader(data: file.data, range: range) }
        guard let base = base else { throw RelayError.notFound }
        return try await base.open(leaf, range: range)
    }

    public func close() {
        base?.close()
    }
}
