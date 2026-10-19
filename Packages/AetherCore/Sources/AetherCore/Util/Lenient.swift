import Foundation

// Addon responses are untrusted third-party JSON. The Stremio core skips invalid
// array items instead of failing the whole response (`VecSkipError`), accepts `null`
// and tolerates numbers where strings are expected. These helpers reproduce that.

/// Decodes an array, silently dropping elements that fail to decode.
/// `null` or a non-array value decodes to an empty array.
public struct LossyArray<Element: Decodable>: Decodable {
    public var elements: [Element]

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        var result: [Element] = []
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                if let element = try? container.decode(Element.self) {
                    result.append(element)
                } else {
                    // Advance past the bad element, otherwise the loop never ends.
                    _ = try? container.decode(Skip.self)
                }
            }
        }
        self.elements = result
    }
}

/// A string that may arrive as a JSON string, number or bool.
public struct FlexString: Decodable, Equatable {
    public var value: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int64.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = FlexString.format(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? "true" : "false"
        } else {
            value = nil
        }
    }

    static func format(_ double: Double) -> String {
        if double == double.rounded() && abs(double) < 1e15 {
            return String(Int64(double))
        }
        return String(double)
    }
}

/// An integer that may arrive as a JSON number or a numeric string.
public struct FlexInt: Decodable, Equatable {
    public var value: Int?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self), double.isFinite, abs(double) < 1e15 {
            value = Int(double)
        } else if let string = try? container.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if let int = Int(trimmed) {
                value = int
            } else if let double = Double(trimmed), double.isFinite, abs(double) < 1e15 {
                value = Int(double)
            } else {
                value = nil
            }
        } else {
            value = nil
        }
    }
}

/// A boolean that may arrive as a JSON bool, number or string.
public struct FlexBool: Decodable, Equatable {
    public var value: Bool?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int != 0
        } else if let string = try? container.decode(String.self) {
            switch string.lowercased() {
            case "true", "1", "yes": value = true
            case "false", "0", "no": value = false
            default: value = nil
            }
        } else {
            value = nil
        }
    }
}

extension KeyedDecodingContainer {
    /// Never throws: returns nil when the key is missing, null, or not representable.
    func flexString(_ key: Key) -> String? {
        let wrapped = try? decodeIfPresent(FlexString.self, forKey: key)
        return wrapped?.value
    }

    func flexInt(_ key: Key) -> Int? {
        let wrapped = try? decodeIfPresent(FlexInt.self, forKey: key)
        return wrapped?.value
    }

    func flexBool(_ key: Key) -> Bool? {
        let wrapped = try? decodeIfPresent(FlexBool.self, forKey: key)
        return wrapped?.value
    }

    /// Lossy array decode: invalid elements are skipped, missing/null gives [].
    func lossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        let wrapped = try? decodeIfPresent(LossyArray<T>.self, forKey: key)
        return wrapped?.elements ?? []
    }

    /// Array of strings where each element may be a string or number.
    func stringList(_ key: Key) -> [String] {
        let wrapped = try? decodeIfPresent(LossyArray<FlexString>.self, forKey: key)
        guard let items = wrapped?.elements else { return [] }
        return items.compactMap { $0.value }
    }

    /// Like `decodeIfPresent` but turns any error into nil.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        return try? decodeIfPresent(type, forKey: key)
    }

    /// Settings-style decoding: missing or malformed values fall back to the default instead of failing.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        let decoded = try? decodeIfPresent(T.self, forKey: key)
        return decoded ?? fallback
    }
}

/// Parses the date formats found in the wild in addon payloads.
public enum AddonDate {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    public static func parse(_ string: String?) -> Date? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = withFraction.date(from: raw) { return date }
        if let date = plain.date(from: raw) { return date }
        if let date = dateOnly.date(from: raw) { return date }
        // "2010-12-06 05:00" / "2010-12-06T05:00:00" without zone: assume UTC.
        let candidates = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"]
        for format in candidates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    public static func format(_ date: Date) -> String {
        return withFraction.string(from: date)
    }
}
