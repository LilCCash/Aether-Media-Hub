import Foundation

/// A small fragmented-MP4 writer: the init segment (`ftyp` + `moov`) and one `moof` + `mdat` per piece. The FFmpeg that ships inside
/// the app (the one media_kit brings) has no MP4 muxer, so the boxes are written here; FFmpeg only reads the Matroska file.
enum MP4Writer {
    struct Track {
        enum Kind { case video, audio }
        var id: UInt32
        var kind: Kind
        var timescale: UInt32
        var width: Int
        var height: Int
        /// The finished sample entry box (`avc1`, `hvc1`, `mp4a`, `ac-3`, `ec-3`).
        var entry: Data
    }

    struct Sample {
        var data: Data
        var duration: UInt32
        var sync: Bool
        /// Presentation time minus decode time, in the track's time scale.
        var offset: Int32
    }

    struct Run {
        var trackID: UInt32
        var baseDecodeTime: UInt64
        var samples: [Sample]
    }

    // MARK: Bytes

    static func u8(_ v: Int) -> Data { return Data([UInt8(truncatingIfNeeded: v)]) }
    static func u16(_ v: Int) -> Data { return Data([UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]) }
    static func u32(_ v: UInt32) -> Data {
        return Data([UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)])
    }
    static func u64(_ v: UInt64) -> Data { return u32(UInt32(truncatingIfNeeded: v >> 32)) + u32(UInt32(truncatingIfNeeded: v)) }

    static func box(_ type: String, _ payload: Data) -> Data {
        var out = u32(UInt32(8 + payload.count))
        out.append(contentsOf: Array(type.utf8))
        out.append(payload)
        return out
    }

    static func full(_ type: String, version: Int, flags: UInt32, _ payload: Data) -> Data {
        var head = Data([UInt8(version), UInt8(truncatingIfNeeded: flags >> 16), UInt8(truncatingIfNeeded: flags >> 8), UInt8(truncatingIfNeeded: flags)])
        head.append(payload)
        return box(type, head)
    }

    private static func join(_ parts: [Data]) -> Data {
        var out = Data()
        for part in parts { out.append(part) }
        return out
    }

    private static var matrix: Data {
        return join([u32(0x00010000), u32(0), u32(0), u32(0), u32(0x00010000), u32(0), u32(0), u32(0), u32(0x40000000)])
    }

    // MARK: Init segment

    static func initSegment(_ tracks: [Track]) -> Data {
        let ftyp = box("ftyp", join([Data("isom".utf8), u32(1), Data("isom".utf8), Data("iso6".utf8), Data("mp41".utf8)]))
        let mvhd = full("mvhd", version: 0, flags: 0, join([
            u32(0), u32(0), u32(1000), u32(0), u32(0x00010000), u16(0x0100), u16(0), u32(0), u32(0), matrix,
            Data(count: 24), u32(UInt32(tracks.count + 1)),
        ]))
        var children: [Data] = [mvhd]
        for track in tracks { children.append(trak(track)) }
        children.append(box("mvex", join(tracks.map { full("trex", version: 0, flags: 0, join([u32($0.id), u32(1), u32(0), u32(0), u32(0)])) })))
        return ftyp + box("moov", join(children))
    }

    private static func trak(_ t: Track) -> Data {
        let audio = t.kind == .audio
        let tkhd = full("tkhd", version: 0, flags: 7, join([
            u32(0), u32(0), u32(t.id), u32(0), u32(0), u32(0), u32(0), u16(0), u16(0), u16(audio ? 0x0100 : 0), u16(0), matrix,
            u32(UInt32(max(0, t.width)) << 16), u32(UInt32(max(0, t.height)) << 16),
        ]))
        let mdhd = full("mdhd", version: 0, flags: 0, join([u32(0), u32(0), u32(t.timescale), u32(0), u16(0x55C4), u16(0)]))
        let hdlr = full("hdlr", version: 0, flags: 0, join([
            u32(0), Data((audio ? "soun" : "vide").utf8), u32(0), u32(0), u32(0), Data((audio ? "SoundHandler" : "VideoHandler").utf8), u8(0),
        ]))
        let header = audio
            ? full("smhd", version: 0, flags: 0, join([u16(0), u16(0)]))
            : full("vmhd", version: 0, flags: 1, join([u16(0), u16(0), u16(0), u16(0)]))
        let dinf = box("dinf", full("dref", version: 0, flags: 0, u32(1) + full("url ", version: 0, flags: 1, Data())))
        let stbl = box("stbl", join([
            full("stsd", version: 0, flags: 0, u32(1) + t.entry),
            full("stts", version: 0, flags: 0, u32(0)),
            full("stsc", version: 0, flags: 0, u32(0)),
            full("stsz", version: 0, flags: 0, u32(0) + u32(0)),
            full("stco", version: 0, flags: 0, u32(0)),
        ]))
        let minf = box("minf", join([header, dinf, stbl]))
        return box("trak", join([tkhd, box("mdia", join([mdhd, hdlr, minf]))]))
    }

    // MARK: Fragment

    static func fragment(sequence: Int, runs: [Run]) -> Data {
        let sorted = runs.sorted { $0.trackID < $1.trackID }
        func build(_ offsets: [Int32]) -> Data {
            var trafs: [Data] = []
            for (position, run) in sorted.enumerated() {
                let tfhd = full("tfhd", version: 0, flags: 0x020000, u32(run.trackID))
                let tfdt = full("tfdt", version: 1, flags: 0, u64(run.baseDecodeTime))
                var entries = Data()
                for s in run.samples {
                    entries.append(u32(s.duration))
                    entries.append(u32(UInt32(s.data.count)))
                    entries.append(u32(s.sync ? 0x02000000 : 0x01010000))
                    entries.append(u32(UInt32(bitPattern: s.offset)))
                }
                let trun = full("trun", version: 1, flags: 0x000F01, u32(UInt32(run.samples.count)) + u32(UInt32(bitPattern: offsets[position])) + entries)
                trafs.append(box("traf", join([tfhd, tfdt, trun])))
            }
            return box("moof", full("mfhd", version: 0, flags: 0, u32(UInt32(sequence))) + join(trafs))
        }
        let size = build(Array(repeating: 0, count: sorted.count)).count
        var offsets: [Int32] = []
        var cursor = size + 8
        for run in sorted {
            offsets.append(Int32(cursor))
            cursor += run.samples.reduce(0) { $0 + $1.data.count }
        }
        var mdat = Data()
        for run in sorted { for s in run.samples { mdat.append(s.data) } }
        return build(offsets) + box("mdat", mdat)
    }
}

/// Reads bits from the start of a few bytes (for the Dolby Digital headers).
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            let byte = position / 8 < bytes.count ? Int(bytes[position / 8]) : 0
            value = (value << 1) | ((byte >> (7 - position % 8)) & 1)
            position += 1
        }
        return value
    }
}

/// The codec configuration boxes that the Matroska file does not carry ready-made.
enum AudioConfigBoxes {
    /// `esds` for AAC (object type 0x40, the AudioSpecificConfig) and MP3 (0x6B, none).
    static func esds(objectType: Int, config: [UInt8]) -> Data {
        func descriptor(_ tag: UInt8, _ payload: Data) -> Data {
            var d = Data([tag, 0x80, 0x80, 0x80, UInt8(payload.count)])
            d.append(payload)
            return d
        }
        var decoder = Data([UInt8(objectType), 0x15, 0, 0, 0])
        decoder.append(MP4Writer.u32(0))
        decoder.append(MP4Writer.u32(0))
        if !config.isEmpty { decoder.append(descriptor(0x05, Data(config))) }
        var stream = MP4Writer.u16(0)
        stream.append(0)
        stream.append(descriptor(0x04, decoder))
        stream.append(descriptor(0x06, Data([0x02])))
        return MP4Writer.full("esds", version: 0, flags: 0, descriptor(0x03, stream))
    }

    /// `dac3` from the first Dolby Digital frame.
    static func dac3(_ packet: Data) -> Data? {
        let b = [UInt8](packet.prefix(10))
        guard b.count >= 8, b[0] == 0x0B, b[1] == 0x77 else { return nil }
        var r = BitReader(Array(b.dropFirst(4)))
        let fscod = r.read(2)
        let frmsizecod = r.read(6)
        let bsid = r.read(5)
        let bsmod = r.read(3)
        let acmod = r.read(3)
        if acmod & 1 != 0 && acmod != 1 { _ = r.read(2) }
        if acmod & 4 != 0 { _ = r.read(2) }
        if acmod == 2 { _ = r.read(2) }
        let lfeon = r.read(1)
        var out = BitWriter()
        out.write(fscod, 2); out.write(bsid, 5); out.write(bsmod, 3); out.write(acmod, 3); out.write(lfeon, 1)
        out.write(frmsizecod >> 1, 5); out.write(0, 5)
        return MP4Writer.box("dac3", out.data)
    }

    /// `dec3` from the first Dolby Digital Plus frame (one independent substream).
    static func dec3(_ packet: Data) -> Data? {
        let b = [UInt8](packet.prefix(12))
        guard b.count >= 8, b[0] == 0x0B, b[1] == 0x77 else { return nil }
        var r = BitReader(Array(b.dropFirst(2)))
        _ = r.read(2)                    // strmtyp
        _ = r.read(3)                    // substreamid
        let frmsiz = r.read(11)
        var fscod = r.read(2)
        var blocks = 6
        if fscod == 3 {
            fscod = r.read(2) + 3        // fscod2: 24, 22.05 or 16 kHz; six blocks
        } else {
            blocks = [1, 2, 3, 6][r.read(2)]
        }
        let acmod = r.read(3)
        let lfeon = r.read(1)
        let bsid = r.read(5)
        let rates = [48000, 44100, 32000, 24000, 22050, 16000]
        let rate = rates[min(fscod, rates.count - 1)]
        let kbps = ((frmsiz + 1) * 2 * 8 * rate) / (blocks * 256) / 1000
        var out = BitWriter()
        out.write(min(kbps, 8191), 13); out.write(0, 3)
        out.write(min(fscod, 2), 2); out.write(bsid, 5); out.write(0, 1); out.write(0, 1); out.write(0, 3)
        out.write(acmod, 3); out.write(lfeon, 1); out.write(0, 3); out.write(0, 4); out.write(0, 1)
        return MP4Writer.box("dec3", out.data)
    }
}

struct BitWriter {
    private var bits: [UInt8] = []
    mutating func write(_ value: Int, _ count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) { bits.append(UInt8((value >> i) & 1)) }
    }
    var data: Data {
        var out = Data()
        var index = 0
        while index < bits.count {
            var byte: UInt8 = 0
            for k in 0..<8 { byte = (byte << 1) | (index + k < bits.count ? bits[index + k] : 0) }
            out.append(byte)
            index += 8
        }
        return out
    }
}
