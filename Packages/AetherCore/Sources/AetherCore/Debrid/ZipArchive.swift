import Foundation

/// Reads the index of a ZIP file through ranged reads (its end, then its central directory), without downloading it: a torrent
/// that is one big ZIP of episodes can then play one of them. An entry stored without compression (what packers do with video) is
/// a plain run of bytes inside the ZIP, so it plays like a file of its own; a compressed one cannot be played without unpacking it.
public enum ZipArchive {
    public struct Entry: Equatable, Sendable {
        public var name: String
        /// 0 = stored, 8 = deflate…
        public var method: Int
        public var flags: Int
        public var compressedSize: Int64
        public var uncompressedSize: Int64
        public var localHeaderOffset: Int64

        public var isStored: Bool { return method == 0 }
        public var isEncrypted: Bool { return flags & 1 != 0 }
        public var isDirectory: Bool { return name.hasSuffix("/") }
    }

    /// Where an entry's bytes are inside the ZIP.
    public struct Window: Equatable, Sendable {
        public var entry: Entry
        public var offset: Int64
        public var length: Int64
    }

    public enum Failure: Error, Equatable {
        case notAZip
        case tooLarge
        case truncated
    }

    public typealias Fetch = (ClosedRange<Int64>) async throws -> Data

    // MARK: Reading through ranges

    /// Every entry of the ZIP of `total` bytes.
    public static func entries(total: Int64, fetch: Fetch) async throws -> [Entry] {
        guard total >= 22 else { throw Failure.notAZip }
        let tailLength = min(total, Int64(65_535 + 22 + 20))
        let tailStart = total - tailLength
        let tail = try await fetch(tailStart...(total - 1))
        guard let directory = try locateDirectory(tail: tail, tailStart: tailStart) else { throw Failure.notAZip }
        var location = directory
        if location.needsZip64, let record = location.zip64RecordOffset {
            // The ZIP64 record is usually in the tail already; otherwise it is read on its own.
            let recordData: Data
            if record >= tailStart, record + 56 <= total {
                let start = Int(record - tailStart)
                recordData = tail.subdata(in: (tail.startIndex + start)..<(tail.startIndex + min(tail.count, start + 56)))
            } else {
                recordData = try await fetch(record...min(total - 1, record + 55))
            }
            guard let parsed = parseZip64Record(recordData) else { throw Failure.truncated }
            location.offset = parsed.offset
            location.size = parsed.size
        }
        guard location.size > 0, location.offset >= 0, location.offset + location.size <= total else { throw Failure.truncated }
        guard location.size <= 64 << 20 else { throw Failure.tooLarge }
        let directoryData = try await fetch(location.offset...(location.offset + location.size - 1))
        return parseDirectory(directoryData)
    }

    /// Where the bytes of `entry` start (after its local header, whose extra field can differ from the central one).
    public static func window(of entry: Entry, total: Int64, fetch: Fetch) async throws -> Window {
        guard entry.localHeaderOffset + 30 <= total else { throw Failure.truncated }
        let header = try await fetch(entry.localHeaderOffset...(entry.localHeaderOffset + 29))
        guard header.count >= 30, u32(header, 0) == 0x04034b50 else { throw Failure.truncated }
        let nameLength = Int64(u16(header, 26))
        let extraLength = Int64(u16(header, 28))
        let offset = entry.localHeaderOffset + 30 + nameLength + extraLength
        let length = entry.isStored ? entry.uncompressedSize : entry.compressedSize
        guard offset + length <= total else { throw Failure.truncated }
        return Window(entry: entry, offset: offset, length: length)
    }

    /// The video of the ZIP the viewer asked for (the episode, or the file name the addon gave), with the same rules as the files of
    /// a torrent. Nil when none is certain.
    public static func choose(_ entries: [Entry], query: TorBoxFileMatcher.Query) -> Entry? {
        let files = entries.enumerated().compactMap { index, entry -> TorBoxFile? in
            guard !entry.isDirectory, !entry.isEncrypted else { return nil }
            return TorBoxFile(id: index, name: entry.name, size: entry.uncompressedSize)
        }
        guard case .selected(let file, _) = TorBoxFileMatcher.select(from: files, query: query), let index = file.id,
              entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    // MARK: Parsing (pure)

    struct DirectoryLocation {
        var offset: Int64
        var size: Int64
        var needsZip64: Bool
        var zip64RecordOffset: Int64?
    }

    /// Finds the end-of-central-directory record in the last bytes of the file (`tailStart` is where they begin in the file).
    static func locateDirectory(tail: Data, tailStart: Int64) throws -> DirectoryLocation? {
        let bytes = [UInt8](tail)
        guard bytes.count >= 22 else { return nil }
        var position = bytes.count - 22
        while position >= 0 {
            if bytes[position] == 0x50 && bytes[position + 1] == 0x4b && bytes[position + 2] == 0x05 && bytes[position + 3] == 0x06 {
                let data = Data(bytes[position...])
                let entries = u16(data, 10)
                let size = Int64(u32(data, 12))
                let offset = Int64(u32(data, 16))
                var location = DirectoryLocation(offset: offset, size: size,
                                                 needsZip64: entries == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF,
                                                 zip64RecordOffset: nil)
                // The ZIP64 locator sits right before the record.
                if position >= 20 {
                    let locator = Data(bytes[(position - 20)..<position])
                    if u32(locator, 0) == 0x07064b50 {
                        location.zip64RecordOffset = Int64(u64(locator, 8))
                        location.needsZip64 = true
                    }
                }
                _ = tailStart
                return location
            }
            position -= 1
        }
        return nil
    }

    static func parseZip64Record(_ data: Data) -> (offset: Int64, size: Int64)? {
        guard data.count >= 56, u32(data, 0) == 0x06064b50 else { return nil }
        return (Int64(u64(data, 48)), Int64(u64(data, 40)))
    }

    public static func parseDirectory(_ data: Data) -> [Entry] {
        var result: [Entry] = []
        var position = 0
        while position + 46 <= data.count, u32(data, position) == 0x02014b50 {
            let flags = Int(u16(data, position + 8))
            let method = Int(u16(data, position + 10))
            var compressed = Int64(u32(data, position + 20))
            var uncompressed = Int64(u32(data, position + 24))
            let nameLength = Int(u16(data, position + 28))
            let extraLength = Int(u16(data, position + 30))
            let commentLength = Int(u16(data, position + 32))
            var localOffset = Int64(u32(data, position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength <= data.count else { break }
            let nameBytes = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLength))
            let name = String(data: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)
            // ZIP64 extra field: the 64-bit values of the fields that are 0xFFFFFFFF, in order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let tag = u16(data, extra)
                let size = Int(u16(data, extra + 2))
                if tag == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { uncompressed = Int64(u64(data, field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { compressed = Int64(u64(data, field)); field += 8 }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= extra + 4 + size { localOffset = Int64(u64(data, field)) }
                }
                extra += 4 + size
            }
            result.append(Entry(name: name, method: method, flags: flags, compressedSize: compressed, uncompressedSize: uncompressed,
                                localHeaderOffset: localOffset))
            position = nameStart + nameLength + extraLength + commentLength
        }
        return result
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        let i = data.startIndex + at
        guard at >= 0, at + 2 <= data.count else { return 0 }
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        let i = data.startIndex + at
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    private static func u64(_ data: Data, _ at: Int) -> UInt64 {
        return UInt64(u32(data, at)) | UInt64(u32(data, at + 4)) << 32
    }
}

/// The bytes of one entry of a ZIP, offered as a file of their own: every range is moved by the entry's offset.
public final class WindowRangeFetcher: RelayRangeFetcher, @unchecked Sendable {
    private let base: RelayRangeFetcher
    private let offset: Int64
    private let length: Int64
    private let contentType: String

    public init(base: RelayRangeFetcher, offset: Int64, length: Int64, contentType: String) {
        self.base = base
        self.offset = offset
        self.length = length
        self.contentType = contentType
    }

    public func probe() async throws -> RelayResource {
        return RelayResource(contentType: contentType, length: length, acceptsRanges: true)
    }

    public func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound < length else { throw RelayError.rangeNotSatisfiable(total: length) }
        return try await base.fetch((range.lowerBound + offset)...(range.upperBound + offset))
    }

    public func invalidate() {
        base.invalidate()
    }
}
