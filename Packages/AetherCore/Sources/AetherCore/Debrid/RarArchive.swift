import Foundation

/// Reads the file headers of a RAR (version 4 or 5) through ranged reads, so a video stored in it without compression (what
/// scene packs do, often split over many volumes: `.part01.rar…`, `.rar/.r00…`) can be played from inside it. A RAR has no index:
/// its headers are walked one after the other, skipping the data between them.
public enum RarArchive {
    public struct Entry: Equatable, Sendable {
        public var name: String
        /// Bytes of this entry in this volume.
        public var packedSize: Int64
        /// Size of the whole file once unpacked.
        public var unpackedSize: Int64
        /// Where the entry's bytes start in this volume.
        public var dataOffset: Int64
        public var isStored: Bool
        public var isEncrypted: Bool
        /// The file started in the volume before / continues in the next one.
        public var continuesFromPrevious: Bool
        public var continuesInNext: Bool
        public var isDirectory: Bool
    }

    public enum Failure: Error, Equatable {
        case notARar
        case encrypted
        case truncated
        case tooManyEntries
    }

    public typealias Fetch = ZipArchive.Fetch

    static let signature4: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    static let signature5: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
    static let chunk: Int64 = 64 * 1024

    /// The file entries of one volume, in order. `firstFileOnly` stops at the first file (what is needed of the volumes after the
    /// first one: the piece of the video they carry). `limit` bounds the walk (every header after a large file costs a read).
    public static func entries(total: Int64, fetch: Fetch, firstFileOnly: Bool = false, limit: Int = 400) async throws -> [Entry] {
        var buffer = try await fetch(0...min(total - 1, chunk - 1))
        var bufferStart: Int64 = 0
        let head = [UInt8](buffer.prefix(8))
        let isFive: Bool
        if head.count >= 8 && Array(head.prefix(8)) == signature5 {
            isFive = true
        } else if head.count >= 7 && Array(head.prefix(7)) == signature4 {
            isFive = false
        } else {
            throw Failure.notARar
        }
        var position: Int64 = isFive ? 8 : 7
        var result: [Entry] = []
        var headers = 0

        func ensure(_ length: Int) async throws -> Data? {
            if position < bufferStart || position + Int64(length) > bufferStart + Int64(buffer.count) {
                guard position < total else { return nil }
                buffer = try await fetch(position...min(total - 1, position + max(chunk, Int64(length)) - 1))
                bufferStart = position
            }
            let start = Int(position - bufferStart)
            guard start + length <= buffer.count else { return nil }
            return buffer.subdata(in: (buffer.startIndex + start)..<(buffer.startIndex + start + length))
        }

        while position < total {
            headers += 1
            if headers > limit * 4 { throw Failure.tooManyEntries }
            if isFive {
                guard let peek = try await ensure(min(Int(total - position), 4 + 10)) else { break }
                var cursor = 4
                guard let headerSize = vint(peek, &cursor) else { throw Failure.truncated }
                let blockStart = position
                let headerTotal = cursor + Int(headerSize)
                guard headerSize > 0, headerSize < 2 << 20, let block = try await ensure(headerTotal) else { throw Failure.truncated }
                guard let parsed = parseHeader5(block, at: cursor) else { throw Failure.truncated }
                let dataStart = blockStart + Int64(headerTotal)
                if parsed.type == 4 { throw Failure.encrypted }    // archive encryption header
                if parsed.type == 5 { break }                      // end of archive
                if parsed.type == 2, var entry = parsed.entry {
                    entry.dataOffset = dataStart
                    result.append(entry)
                    if firstFileOnly || result.count >= limit { break }
                }
                position = dataStart + parsed.dataSize
            } else {
                guard let common = try await ensure(min(Int(total - position), 7)), common.count >= 7 else { break }
                let type = common[common.startIndex + 2]
                let flags = Int(u16(common, 3))
                let headSize = Int(u16(common, 5))
                guard headSize >= 7 else { throw Failure.truncated }
                guard let block = try await ensure(headSize) else { throw Failure.truncated }
                var dataSize: Int64 = 0
                if flags & 0x8000 != 0 && headSize >= 11 { dataSize = Int64(u32(block, 7)) }
                if type == 0x7B { break }                          // end of archive
                if type == 0x74, var entry = parseFileHeader4(block, flags: flags) {
                    if flags & 0x100 != 0 && headSize >= 36 { dataSize |= Int64(u32(block, 32)) << 32 }
                    entry.dataOffset = position + Int64(headSize)
                    entry.packedSize = dataSize
                    result.append(entry)
                    if firstFileOnly || result.count >= limit { break }
                }
                if type == 0x73 && flags & 0x0080 != 0 { throw Failure.encrypted }   // headers encrypted
                position += Int64(headSize) + dataSize
            }
        }
        return result
    }

    // MARK: RAR 4

    static func parseFileHeader4(_ block: Data, flags: Int) -> Entry? {
        guard block.count >= 32 else { return nil }
        var unpacked = Int64(u32(block, 11))
        let method = block[block.startIndex + 25]
        let nameSize = Int(u16(block, 26))
        var nameStart = 32
        if flags & 0x100 != 0 {
            guard block.count >= 40 else { return nil }
            unpacked |= Int64(u32(block, 36)) << 32
            nameStart = 40
        }
        guard nameStart + nameSize <= block.count else { return nil }
        var nameBytes = [UInt8](block.subdata(in: (block.startIndex + nameStart)..<(block.startIndex + nameStart + nameSize)))
        // With a Unicode name the ASCII name ends at a zero byte, the encoded one follows.
        if let zero = nameBytes.firstIndex(of: 0) { nameBytes = Array(nameBytes[..<zero]) }
        let name = (String(bytes: nameBytes, encoding: .utf8) ?? String(decoding: nameBytes, as: UTF8.self)).replacingOccurrences(of: "\\", with: "/")
        return Entry(name: name, packedSize: 0, unpackedSize: unpacked, dataOffset: 0, isStored: method == 0x30,
                     isEncrypted: flags & 0x04 != 0, continuesFromPrevious: flags & 0x01 != 0, continuesInNext: flags & 0x02 != 0,
                     isDirectory: flags & 0xE0 == 0xE0)
    }

    // MARK: RAR 5

    struct Header5 {
        var type: UInt64
        var dataSize: Int64
        var entry: Entry?
    }

    static func parseHeader5(_ block: Data, at start: Int) -> Header5? {
        var cursor = start
        guard let type = vint(block, &cursor), let flags = vint(block, &cursor) else { return nil }
        var extraSize: UInt64 = 0
        var dataSize: UInt64 = 0
        if flags & 0x01 != 0 { guard let value = vint(block, &cursor) else { return nil }; extraSize = value }
        if flags & 0x02 != 0 { guard let value = vint(block, &cursor) else { return nil }; dataSize = value }
        guard type == 2 else { return Header5(type: type, dataSize: Int64(dataSize), entry: nil) }
        guard let fileFlags = vint(block, &cursor), let unpacked = vint(block, &cursor), vint(block, &cursor) != nil else { return nil }
        if fileFlags & 0x02 != 0 { cursor += 4 }
        if fileFlags & 0x04 != 0 { cursor += 4 }
        guard let compression = vint(block, &cursor), vint(block, &cursor) != nil, let nameLength = vint(block, &cursor) else { return nil }
        guard cursor + Int(nameLength) <= block.count else { return nil }
        let nameBytes = block.subdata(in: (block.startIndex + cursor)..<(block.startIndex + cursor + Int(nameLength)))
        cursor += Int(nameLength)
        // Extra records: type 1 is file encryption.
        var encrypted = false
        var extraCursor = cursor
        let extraEnd = min(block.count, cursor + Int(extraSize))
        while extraCursor < extraEnd {
            guard let size = vint(block, &extraCursor) else { break }
            let recordEnd = extraCursor + Int(size)
            guard let recordType = vint(block, &extraCursor) else { break }
            if recordType == 1 { encrypted = true }
            extraCursor = recordEnd
        }
        let method = (compression >> 7) & 0x7
        let name = String(decoding: nameBytes, as: UTF8.self)
        let entry = Entry(name: name, packedSize: Int64(dataSize), unpackedSize: Int64(unpacked), dataOffset: 0, isStored: method == 0,
                          isEncrypted: encrypted, continuesFromPrevious: flags & 0x08 != 0, continuesInNext: flags & 0x10 != 0,
                          isDirectory: fileFlags & 0x01 != 0)
        return Header5(type: type, dataSize: Int64(dataSize), entry: entry)
    }

    static func vint(_ data: Data, _ cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < data.count && shift < 64 {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func u16(_ data: Data, _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= data.count else { return 0 }
        let i = data.startIndex + at
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private static func u32(_ data: Data, _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        let i = data.startIndex + at
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    // MARK: Volumes

    /// The volumes of the torrent grouped by set (one set per archive), each set in reading order:
    /// `name.part1.rar, name.part2.rar…` or `name.rar, name.r00, name.r01…`.
    public static func volumeSets(_ names: [String]) -> [[String]] {
        struct Volume { var name: String; var base: String; var order: Int }
        var volumes: [Volume] = []
        for name in names {
            let lower = name.lowercased()
            if let range = lower.range(of: #"\.part(\d+)\.rar$"#, options: .regularExpression) {
                let digits = lower[range].filter { $0.isNumber }
                volumes.append(Volume(name: name, base: String(lower[..<range.lowerBound]), order: Int(digits) ?? 0))
            } else if lower.hasSuffix(".rar") {
                volumes.append(Volume(name: name, base: String(lower.dropLast(4)), order: -1))
            } else if let range = lower.range(of: #"\.r(\d{2,3})$"#, options: .regularExpression) {
                let digits = lower[range].filter { $0.isNumber }
                volumes.append(Volume(name: name, base: String(lower[..<range.lowerBound]), order: Int(digits) ?? 0))
            }
        }
        let grouped = Dictionary(grouping: volumes, by: { $0.base })
        return grouped.keys.sorted().map { key in grouped[key]!.sorted { $0.order < $1.order }.map { $0.name } }
    }
}

/// Several pieces of several files read as one: the parts of a video split over RAR volumes.
public final class ConcatenatedRangeFetcher: RelayRangeFetcher, @unchecked Sendable {
    public struct Piece {
        public var fetcher: RelayRangeFetcher
        public var offset: Int64
        public var length: Int64
        public init(fetcher: RelayRangeFetcher, offset: Int64, length: Int64) {
            self.fetcher = fetcher
            self.offset = offset
            self.length = length
        }
    }

    private let pieces: [Piece]
    private let starts: [Int64]
    private let length: Int64
    private let contentType: String

    public init(pieces: [Piece], contentType: String) {
        self.pieces = pieces
        var starts: [Int64] = []
        var running: Int64 = 0
        for piece in pieces {
            starts.append(running)
            running += piece.length
        }
        self.starts = starts
        self.length = running
        self.contentType = contentType
    }

    public func probe() async throws -> RelayResource {
        return RelayResource(contentType: contentType, length: length, acceptsRanges: true)
    }

    public func fetch(_ range: ClosedRange<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound < length else { throw RelayError.rangeNotSatisfiable(total: length) }
        var result = Data()
        var position = range.lowerBound
        while position <= range.upperBound {
            guard let index = starts.lastIndex(where: { $0 <= position }) else { break }
            let piece = pieces[index]
            let inside = position - starts[index]
            let end = min(range.upperBound - starts[index], piece.length - 1)
            result.append(try await piece.fetcher.fetch((piece.offset + inside)...(piece.offset + end)))
            position = starts[index] + end + 1
        }
        return result
    }

    public func invalidate() {
        for piece in pieces { piece.fetcher.invalidate() }
    }
}

/// A fetcher shared by two sources (the phone's player and the AirPlay address): closing one source must not stop the other.
public final class SharedRangeFetcher: RelayRangeFetcher, @unchecked Sendable {
    private let base: RelayRangeFetcher
    public init(_ base: RelayRangeFetcher) { self.base = base }
    public func probe() async throws -> RelayResource { return try await base.probe() }
    public func fetch(_ range: ClosedRange<Int64>) async throws -> Data { return try await base.fetch(range) }
    public func invalidate() {}
}
