import Foundation

/// OpenSubtitles "moviehash" (the hash Media Player Classic introduced and every Stremio subtitles addon understands).
///
///     hash = file_size + sum_uint64_le(first 65536 bytes) + sum_uint64_le(last 65536 bytes)    (mod 2^64)
///
/// The result is 16 lowercase hexadecimal digits, left padded with zeros. Files smaller than 131072 bytes (128 KiB)
/// have no valid hash. The two windows never overlap for valid files (they are adjacent at exactly 131072 bytes), and
/// the part of the file between them is not read at all: this is what makes hashing a remote file possible with two
/// small `Range` requests (see `SubtitleHashProbe`).
///
/// This type is pure: no I/O, no network. Reference: `opensubtitles/oshash` (MIT), test vectors in docs/05-SUBTITLES-RESEARCH.md §4.1.
public enum OpenSubtitlesHash {
    /// Size of each of the two windows that are summed.
    public static let chunkSize = 65_536

    /// Smallest file size for which a hash exists (two adjacent windows).
    public static let minimumFileSize: UInt64 = 131_072

    /// Hash from the declared `size` of the file and its first and last `chunkSize` bytes.
    /// Returns nil when `size` is below `minimumFileSize` or when a window does not have exactly `chunkSize` bytes.
    /// `size` is unsigned because the algorithm is defined modulo 2^64 and the reference suite includes sizes above `Int64.max`.
    public static func compute(size: UInt64, head: Data, tail: Data) -> String? {
        guard size >= minimumFileSize else { return nil }
        guard head.count == chunkSize, tail.count == chunkSize else { return nil }
        var sum: UInt64 = size
        sum = sum &+ wordSum(head)
        sum = sum &+ wordSum(tail)
        return String(format: "%016llx", sum)
    }

    /// Hash of a complete in-memory file (`size` is `data.count`). Only the two windows are read.
    public static func compute(data: Data) -> String? {
        guard UInt64(data.count) >= minimumFileSize else { return nil }
        let start = data.startIndex
        let head = Data(data[start..<(start + chunkSize)])
        let tail = Data(data[(data.endIndex - chunkSize)..<data.endIndex])
        return compute(size: UInt64(data.count), head: head, tail: tail)
    }

    /// Sum of the little-endian 64-bit words of `window` with wrap-around. `window.count` is a multiple of 8 here.
    /// Index arithmetic is relative to `startIndex`, so slices of a larger `Data` are handled correctly.
    private static func wordSum(_ window: Data) -> UInt64 {
        var sum: UInt64 = 0
        var base = window.startIndex
        let end = window.endIndex
        while base + 8 <= end {
            var word: UInt64 = 0
            for offset in 0..<8 {
                let byte = UInt64(window[base + offset])
                let shift = UInt64(offset * 8)
                word |= byte << shift
            }
            sum = sum &+ word
            base += 8
        }
        return sum
    }
}
