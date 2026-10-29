import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum Hashing {
    /// Hex SHA-256 where CryptoKit exists, otherwise a 64-bit FNV-1a (only used for file names / fingerprints
    /// on platforms without CryptoKit; never for security decisions).
    public static func sha256Hex(_ string: String) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        return fnv1a64Hex(string)
        #endif
    }

    public static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Percent-encoding with the same safe set as `URI_COMPONENT_ENCODE_SET` in stremio-core:
/// everything except `A-Z a-z 0-9 - _ . ! ~ * ' ( )` is escaped, byte-wise on UTF-8.
public enum URIComponent {
    private static let hex: [Character] = Array("0123456789ABCDEF")

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        case 0x2D, 0x5F, 0x2E, 0x21, 0x7E, 0x2A, 0x27, 0x28, 0x29: return true
        default: return false
        }
    }

    public static func encode(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            if isUnreserved(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append("%")
                result.append(hex[Int(byte >> 4)])
                result.append(hex[Int(byte & 0x0F)])
            }
        }
        return result
    }

    public static func decode(_ string: String) -> String {
        return string.removingPercentEncoding ?? string
    }
}
