import Foundation

/// Just enough of the MP4 box structure to cut the muxer's output into an init segment and a fragment, and to put the real decode
/// time into each track fragment. FFmpeg's MP4 muxer writes every fresh output with its first sample at time zero, but the segments of
/// one stream must continue each other.
public enum MP4Fragment {
    public struct Box: Equatable, Sendable {
        public var type: String
        public var start: Int
        public var size: Int
        public var headerSize: Int

        public var end: Int { return start + size }
        public var payloadStart: Int { return start + headerSize }
    }

    private static func be32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16) | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64 {
        return (UInt64(be32(data, offset)) << 32) | UInt64(be32(data, offset + 4))
    }

    /// The boxes found between `start` and `end` (default: the whole data). Stops at the first box that does not fit.
    public static func boxes(in data: Data, from start: Int = 0, to end: Int? = nil) -> [Box] {
        let limit = min(end ?? data.count, data.count)
        var result: [Box] = []
        var offset = start
        while offset + 8 <= limit {
            var size = Int(be32(data, offset))
            var header = 8
            if size == 1 {
                guard offset + 16 <= limit else { break }
                let large = be64(data, offset + 8)
                guard large <= UInt64(Int.max) else { break }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = limit - offset
            }
            guard size >= header, offset + size <= limit else { break }
            let typeBytes = (0..<4).map { data[data.startIndex + offset + 4 + $0] }
            result.append(Box(type: String(decoding: typeBytes, as: UTF8.self), start: offset, size: size, headerSize: header))
            offset += size
        }
        return result
    }

    /// Splits what the muxer wrote: everything before the first `moof` is the init segment (`ftyp` + `moov`); the fragment is the
    /// `moof` and `mdat` boxes from there, without any trailing index (`mfra`) the muxer may have added.
    public static func split(_ muxed: Data) -> (initPart: Data, fragment: Data)? {
        let top = boxes(in: muxed)
        guard let firstFragment = top.first(where: { $0.type == "moof" }) else { return nil }
        var end = firstFragment.start
        for box in top where box.start >= firstFragment.start {
            guard box.type == "moof" || box.type == "mdat" else { break }
            end = box.end
        }
        guard end > firstFragment.start else { return nil }
        let initPart = Data(muxed[muxed.startIndex..<(muxed.startIndex + firstFragment.start)])
        let fragment = Data(muxed[(muxed.startIndex + firstFragment.start)..<(muxed.startIndex + end)])
        return (initPart, fragment)
    }

    /// Writes `times[trackID]` as the base media decode time of every track fragment of the given track. Returns false when a value does
    /// not fit the box (a version 0 `tfdt` holds 32 bits) or the structure is not what is expected.
    @discardableResult
    public static func setDecodeTimes(in fragment: inout Data, _ times: [UInt32: UInt64]) -> Bool {
        var patched = true
        for moof in boxes(in: fragment) where moof.type == "moof" {
            for traf in boxes(in: fragment, from: moof.payloadStart, to: moof.end) where traf.type == "traf" {
                let children = boxes(in: fragment, from: traf.payloadStart, to: traf.end)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }), tfhd.payloadStart + 8 <= tfhd.end,
                      let tfdt = children.first(where: { $0.type == "tfdt" }) else {
                    patched = false
                    continue
                }
                let trackID = be32(fragment, tfhd.payloadStart + 4)
                guard let value = times[trackID] else { continue }
                // The version byte is the first of the payload: an empty box has none.
                guard tfdt.payloadStart < tfdt.end else { patched = false; continue }
                let base = fragment.startIndex + tfdt.payloadStart
                let version = fragment[base]
                if version == 1 {
                    guard tfdt.payloadStart + 12 <= tfdt.end else { patched = false; continue }
                    for index in 0..<8 { fragment[base + 4 + index] = UInt8(truncatingIfNeeded: value >> UInt64(56 - 8 * index)) }
                } else {
                    guard tfdt.payloadStart + 8 <= tfdt.end, value <= UInt64(UInt32.max) else { patched = false; continue }
                    for index in 0..<4 { fragment[base + 4 + index] = UInt8(truncatingIfNeeded: value >> UInt64(24 - 8 * index)) }
                }
            }
        }
        return patched
    }

    /// The base media decode time of each track fragment, by track ID (for tests and diagnostics).
    public static func decodeTimes(in fragment: Data) -> [UInt32: UInt64] {
        var result: [UInt32: UInt64] = [:]
        for moof in boxes(in: fragment) where moof.type == "moof" {
            for traf in boxes(in: fragment, from: moof.payloadStart, to: moof.end) where traf.type == "traf" {
                let children = boxes(in: fragment, from: traf.payloadStart, to: traf.end)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }), tfhd.payloadStart + 8 <= tfhd.end,
                      let tfdt = children.first(where: { $0.type == "tfdt" }) else { continue }
                let trackID = be32(fragment, tfhd.payloadStart + 4)
                let base = tfdt.payloadStart
                guard base < tfdt.end else { continue }
                if fragment[fragment.startIndex + base] == 1 {
                    if base + 12 <= tfdt.end { result[trackID] = be64(fragment, base + 4) }
                } else if base + 8 <= tfdt.end {
                    result[trackID] = UInt64(be32(fragment, base + 4))
                }
            }
        }
        return result
    }

    /// The time scale of each track of an init segment, by track ID.
    public static func trackTimescales(in initPart: Data) -> [UInt32: UInt32] {
        var result: [UInt32: UInt32] = [:]
        for moov in boxes(in: initPart) where moov.type == "moov" {
            for trak in boxes(in: initPart, from: moov.payloadStart, to: moov.end) where trak.type == "trak" {
                let parts = boxes(in: initPart, from: trak.payloadStart, to: trak.end)
                guard let tkhd = parts.first(where: { $0.type == "tkhd" }), let mdia = parts.first(where: { $0.type == "mdia" }),
                      let mdhd = boxes(in: initPart, from: mdia.payloadStart, to: mdia.end).first(where: { $0.type == "mdhd" }) else { continue }
                guard tkhd.payloadStart < tkhd.end, mdhd.payloadStart < mdhd.end else { continue }
                let tkhdVersion = initPart[initPart.startIndex + tkhd.payloadStart]
                let mdhdVersion = initPart[initPart.startIndex + mdhd.payloadStart]
                let idOffset = tkhd.payloadStart + (tkhdVersion == 1 ? 20 : 12)
                let scaleOffset = mdhd.payloadStart + (mdhdVersion == 1 ? 20 : 12)
                guard idOffset + 4 <= tkhd.end, scaleOffset + 4 <= mdhd.end else { continue }
                result[be32(initPart, idOffset)] = be32(initPart, scaleOffset)
            }
        }
        return result
    }
}
