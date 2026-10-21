import Foundation

// A deliberately small HTTP/1.1 server dialect: GET, HEAD and OPTIONS of exactly one kind of resource, no bodies, no query strings, one
// request per connection. Everything it does not recognise is refused. Pure functions on bytes, so they are tested without a socket.

public enum RelayMethod: Equatable, Sendable {
    case get, head, options
}

/// One byte range as a receiver asked for it.
public enum RelayByteRange: Equatable, Sendable {
    case from(Int64, to: Int64?)
    case suffix(Int64)

    /// The inclusive range of bytes to serve out of `total`, or nil when it cannot be satisfied (answer 416).
    public func resolve(total: Int64) -> ClosedRange<Int64>? {
        guard total > 0 else { return nil }
        switch self {
        case .from(let start, let end):
            guard start >= 0, start < total else { return nil }
            let last = min(end ?? (total - 1), total - 1)
            guard last >= start else { return nil }
            return start...last
        case .suffix(let length):
            guard length > 0 else { return nil }
            return max(0, total - length)...(total - 1)
        }
    }
}

public enum RelayRangeHeader: Equatable, Sendable {
    /// No Range header: serve the whole body.
    case absent
    /// A Range header the relay does not honour (several ranges, another unit, nonsense): serve the whole body, as RFC 9110 allows.
    case ignored
    case single(RelayByteRange)

    public static func parse(_ header: String?) -> RelayRangeHeader {
        guard let header = header else { return .absent }
        let value = header.trimmingCharacters(in: .whitespaces)
        let prefix = "bytes="
        guard value.hasPrefix(prefix) else { return .ignored }
        let spec = String(value.dropFirst(prefix.count))
        guard !spec.isEmpty, !spec.contains(",") else { return .ignored }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .ignored }
        let first = parts[0], second = parts[1]
        func number(_ text: String) -> Int64? {
            guard !text.isEmpty, text.count <= 18, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int64(text)
        }
        if first.isEmpty {
            guard let length = number(second) else { return .ignored }
            return .single(.suffix(length))
        }
        guard let start = number(first) else { return .ignored }
        if second.isEmpty { return .single(.from(start, to: nil)) }
        guard let end = number(second), end >= start else { return .ignored }
        return .single(.from(start, to: end))
    }
}

public struct RelayRequestHead: Equatable, Sendable {
    public var method: RelayMethod
    public var token: String
    public var leaf: String
    public var range: RelayRangeHeader
    public var wantsDLNAFeatures: Bool

    public init(method: RelayMethod, token: String, leaf: String, range: RelayRangeHeader = .absent, wantsDLNAFeatures: Bool = false) {
        self.method = method
        self.token = token
        self.leaf = leaf
        self.range = range
        self.wantsDLNAFeatures = wantsDLNAFeatures
    }
}

public enum RelayParseResult: Equatable, Sendable {
    case needMoreData
    case request(RelayRequestHead, consumed: Int)
    /// 400, 404 (an address of the wrong shape: the same answer as an unknown token), 405, 431 or 505.
    case reject(status: Int)
}

public enum RelayRequestParser {
    private static let crlfcrlf: [UInt8] = [13, 10, 13, 10]

    static func isTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true            // digits, letters
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E: return true   // !#$%&'*+-.^_`|~
        default: return false
        }
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        return (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)    // lowercase only
    }

    private static func isLeafCharacter(_ byte: UInt8) -> Bool {
        return (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || byte == 0x2E || byte == 0x5F || byte == 0x2D
    }

    /// Parses the head of one request from `buffer`.
    public static func parse(_ buffer: Data, limits: RelayLimits) -> RelayParseResult {
        let bytes = [UInt8](buffer)

        // The end of the head.
        var end: Int?
        if bytes.count >= 4 {
            var index = 0
            while index + 4 <= bytes.count {
                if bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
                    end = index
                    break
                }
                index += 1
            }
        }
        let scanned = end.map { $0 + 2 } ?? bytes.count      // up to and including the CRLF that ends the last header line
        // Only CRLF may end a line; control characters and non-ASCII bytes are never part of a head.
        for index in 0..<min(scanned, bytes.count) {
            let byte = bytes[index]
            if byte == 10 && (index == 0 || bytes[index - 1] != 13) { return .reject(status: 400) }
            if byte == 13 && index + 1 < bytes.count && bytes[index + 1] != 10 { return .reject(status: 400) }
            if byte == 0 || byte >= 0x80 { return .reject(status: 400) }
            if byte < 0x20 && byte != 9 && byte != 10 && byte != 13 { return .reject(status: 400) }
        }
        guard let headEnd = end else {
            return bytes.count >= limits.maxHeadBytes ? .reject(status: 431) : .needMoreData
        }
        if headEnd + 4 > limits.maxHeadBytes { return .reject(status: 431) }

        let headBytes = Array(bytes[0..<headEnd])
        let head = String(decoding: headBytes, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .reject(status: 400) }

        // Request line: METHOD SP target SP HTTP/1.x
        let pieces = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return .reject(status: 400) }
        let methodText = pieces[0], target = pieces[1], version = pieces[2]
        guard !methodText.isEmpty, methodText.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else { return .reject(status: 400) }
        guard version.hasPrefix("HTTP/") else { return .reject(status: 400) }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            let digits = version.dropFirst(5)
            let valid = digits.count == 3 && digits.first?.isNumber == true && digits[digits.index(after: digits.startIndex)] == "." && digits.last?.isNumber == true
            return .reject(status: valid ? 505 : 400)
        }
        let method: RelayMethod
        switch methodText {
        case "GET": method = .get
        case "HEAD": method = .head
        case "OPTIONS": method = .options
        default: return .reject(status: 405)
        }

        // Headers.
        guard lines.count - 1 <= limits.maxHeaders else { return .reject(status: 431) }
        var hostCount = 0
        var rangeValue: String?
        var wantsDLNA = false
        for line in lines.dropFirst() {
            guard let first = line.utf8.first, first != 32, first != 9 else { return .reject(status: 400) }     // obs-fold, empty line
            guard let colon = line.firstIndex(of: ":") else { return .reject(status: 400) }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenCharacter) else { return .reject(status: 400) }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            switch name.lowercased() {
            case "host": hostCount += 1
            case "range": if rangeValue == nil { rangeValue = value }
            case "transfer-encoding", "expect", "upgrade": return .reject(status: 400)
            case "content-length":
                guard let length = Int(value), length == 0 else { return .reject(status: 400) }
            case "getcontentfeatures.dlna.org": wantsDLNA = value.trimmingCharacters(in: .whitespaces) == "1"
            default: break
            }
        }
        guard hostCount <= 1 else { return .reject(status: 400) }

        // Target: /r/<64 lowercase hex>/<leaf>, nothing else.
        guard target.utf8.count <= 160, target.hasPrefix("/") else { return .reject(status: 400) }
        let targetBytes = Array(target.utf8)
        for byte in targetBytes where byte == 0x3F || byte == 0x23 || byte == 0x25 { return .reject(status: 404) }     // ? # %
        if target.contains("..") || target.contains("//") { return .reject(status: 404) }
        let segments = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count == 4, segments[0].isEmpty, segments[1] == "r" else { return .reject(status: 404) }
        let token = segments[2], leaf = segments[3]
        guard token.utf8.count == 64, token.utf8.allSatisfy(isHex) else { return .reject(status: 404) }
        guard !leaf.isEmpty, leaf.utf8.count <= 64, leaf.utf8.allSatisfy(isLeafCharacter),
              let firstLeaf = leaf.utf8.first, firstLeaf != 0x2E, firstLeaf != 0x5F, firstLeaf != 0x2D else { return .reject(status: 404) }

        let request = RelayRequestHead(method: method, token: token, leaf: leaf, range: RelayRangeHeader.parse(rangeValue), wantsDLNAFeatures: wantsDLNA)
        return .request(request, consumed: headEnd + 4)
    }
}

public struct RelayHeaderField: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

public struct RelayResponseHead: Equatable, Sendable {
    public var status: Int
    public var headers: [RelayHeaderField]

    public init(status: Int, headers: [RelayHeaderField]) {
        self.status = status
        self.headers = headers
    }

    public static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        case 431: return "Request Header Fields Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 505: return "HTTP Version Not Supported"
        default: return "Status"
        }
    }

    /// The head as bytes. A header whose name or value could break the line structure (CR, LF or NUL) is left out entirely.
    public func serialized() -> Data {
        var text = "HTTP/1.1 \(status) \(RelayResponseHead.reason(for: status))\r\n"
        for field in headers {
            let unsafe = CharacterSet(charactersIn: "\r\n\0")
            if field.name.isEmpty || field.name.rangeOfCharacter(from: unsafe) != nil || field.value.rangeOfCharacter(from: unsafe) != nil { continue }
            if field.name.contains(":") || field.name.contains(" ") { continue }
            text += "\(field.name): \(field.value)\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Content types for the leaf names the relay serves (`video.<ext>`).
public enum RelayMime {
    public static func forFileName(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        switch name[name.index(after: dot)...].lowercased() {
        case "mkv": return "video/x-matroska"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "ts": return "video/mp2t"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        default: return nil
        }
    }

    /// The extensions a `video.<ext>` leaf may have.
    public static let allowedExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "webm", "ts", "avi", "mp3", "m4a"]
}
