import Foundation

/// RFC 6381 codec strings, which a receiver reads in the master playlist before it fetches anything.
public enum CodecStrings {
    private static func hex(_ value: UInt8) -> String {
        return String(format: "%02X", value)
    }

    /// `avc1.PPCCLL` from the first bytes of an `avcC` record (version, profile, compatibility, level).
    public static func avc1(avcC: [UInt8]) -> String? {
        guard avcC.count >= 4, avcC[0] == 1 else { return nil }
        return "avc1." + hex(avcC[1]) + hex(avcC[2]) + hex(avcC[3])
    }

    /// `hvc1.<profile>.<compatibility>.<tier><level>.<constraints>` from an `hvcC` record.
    public static func hvc1(hvcC: [UInt8]) -> String? {
        guard hvcC.count >= 13, hvcC[0] == 1 else { return nil }
        let spaceBits = hvcC[1] >> 6
        let space = spaceBits == 0 ? "" : String(UnicodeScalar(UInt8(64 + spaceBits)))
        let tier = (hvcC[1] >> 5) & 1 == 1 ? "H" : "L"
        let profile = hvcC[1] & 0x1f
        // The 32 compatibility flags are written with their bits in reverse order.
        var flags: UInt32 = 0
        for index in 2..<6 { flags = (flags << 8) | UInt32(hvcC[index]) }
        var reversed: UInt32 = 0
        for bit in 0..<32 where flags & (1 << UInt32(bit)) != 0 { reversed |= 1 << UInt32(31 - bit) }
        var constraints = Array(hvcC[6..<12])
        while let last = constraints.last, last == 0 { constraints.removeLast() }
        var text = "hvc1.\(space)\(profile).\(String(reversed, radix: 16, uppercase: true)).\(tier)\(hvcC[12])"
        for byte in constraints { text += "." + String(byte, radix: 16, uppercase: true) }
        return text
    }

    /// AAC object type 2 (LC) unless the stream says otherwise.
    public static func aac(objectType: Int? = nil) -> String {
        return "mp4a.40.\(objectType ?? 2)"
    }

    public static func audio(codec: String, aacObjectType: Int? = nil) -> String? {
        switch codec.lowercased() {
        case "aac": return aac(objectType: aacObjectType)
        case "ac3": return "ac-3"
        case "eac3": return "ec-3"
        case "mp3": return "mp4a.6B"
        default: return nil
        }
    }
}
