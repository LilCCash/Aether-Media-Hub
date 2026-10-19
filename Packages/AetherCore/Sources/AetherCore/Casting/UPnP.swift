import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// DLNA / UPnP AV "MediaRenderer" control: device description parsing, SOAP (AVTransport / RenderingControl),
// DIDL-Lite metadata, SSDP message helpers. Transport is HTTP via `HTTPClient`; multicast sockets live in the app.

public struct UPnPService: Hashable, Sendable {
    public var serviceType: String
    public var controlURL: URL
}

public struct UPnPDevice: Hashable, Identifiable, Sendable {
    public var udn: String
    public var friendlyName: String
    public var manufacturer: String?
    public var modelName: String?
    public var location: URL
    public var services: [UPnPService]

    public var id: String { return udn.isEmpty ? location.absoluteString : udn }

    public var avTransport: UPnPService? {
        return services.first(where: { $0.serviceType.contains(":service:AVTransport:") })
    }

    public var renderingControl: UPnPService? {
        return services.first(where: { $0.serviceType.contains(":service:RenderingControl:") })
    }

    public var isMediaRenderer: Bool { return avTransport != nil }
}

public enum UPnPError: Error, Equatable, Sendable {
    case invalidDescription
    case notAMediaRenderer
    case soapFault(code: Int?, message: String)
    case http(Int)
    case unreachable

    public var message: String {
        switch self {
        case .invalidDescription: return "La descrizione del dispositivo UPnP non è valida."
        case .notAMediaRenderer: return "Il dispositivo non è un renderer multimediale (manca AVTransport)."
        case .soapFault(let code, let message):
            return "Il televisore ha rifiutato il comando\(code.map { " (\($0))" } ?? ""): \(message)"
        case .http(let status): return "Il televisore ha risposto con errore HTTP \(status)."
        case .unreachable: return "Impossibile raggiungere il dispositivo UPnP."
        }
    }
}

// MARK: - Device description

public enum UPnPDescriptionParser {
    public static func parse(_ data: Data, location: URL) throws -> UPnPDevice {
        let delegate = DescriptionDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.friendlyName.isEmpty || !delegate.services.isEmpty else {
            throw UPnPError.invalidDescription
        }
        let base: URL
        if let urlBase = delegate.urlBase, let url = URL(string: urlBase) {
            base = url
        } else {
            base = location
        }
        var services: [UPnPService] = []
        for raw in delegate.services {
            guard let type = raw["serviceType"], let control = raw["controlURL"],
                  let url = URL(string: control, relativeTo: base)?.absoluteURL else { continue }
            services.append(UPnPService(serviceType: type, controlURL: url))
        }
        return UPnPDevice(udn: delegate.udn, friendlyName: delegate.friendlyName.isEmpty ? "Dispositivo UPnP" : delegate.friendlyName,
                          manufacturer: delegate.manufacturer, modelName: delegate.modelName,
                          location: location, services: services)
    }

    private final class DescriptionDelegate: NSObject, XMLParserDelegate {
        var urlBase: String?
        var friendlyName = ""
        var udn = ""
        var manufacturer: String?
        var modelName: String?
        var services: [[String: String]] = []

        private var stack: [String] = []
        private var text = ""
        private var currentService: [String: String]?
        private var deviceDepth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(elementName)
            text = ""
            if elementName == "service" { currentService = [:] }
            if elementName == "device" { deviceDepth += 1 }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentService != nil {
                if ["serviceType", "serviceId", "controlURL", "eventSubURL", "SCPDURL"].contains(elementName) {
                    currentService?[elementName] = value
                }
                if elementName == "service" {
                    if let service = currentService { services.append(service) }
                    currentService = nil
                }
            } else if deviceDepth == 1 {
                // Only the root device's own fields; embedded devices come later and must not override them.
                switch elementName {
                case "friendlyName" where friendlyName.isEmpty: friendlyName = value
                case "UDN" where udn.isEmpty: udn = value
                case "manufacturer" where manufacturer == nil: manufacturer = value
                case "modelName" where modelName == nil: modelName = value
                default: break
                }
            }
            if elementName == "URLBase" { urlBase = value }
            if elementName == "device" { deviceDepth -= 1 }
            _ = stack.popLast()
            text = ""
        }
    }
}

// MARK: - SOAP

public enum SOAP {
    public static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    public static func envelope(serviceType: String, action: String, arguments: [(String, String)]) -> Data {
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        body += "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
        body += "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
        body += "<u:\(action) xmlns:u=\"\(serviceType)\">"
        for (name, value) in arguments {
            body += "<\(name)>\(escape(value))</\(name)>"
        }
        body += "</u:\(action)></s:Body></s:Envelope>"
        return Data(body.utf8)
    }

    public static func headers(serviceType: String, action: String) -> [String: String] {
        return [
            "Content-Type": "text/xml; charset=\"utf-8\"",
            "SOAPAction": "\"\(serviceType)#\(action)\"",
            "Accept": "text/xml"
        ]
    }

    /// Leaf element name → text, for response bodies; also detects `UPnPError` faults.
    public static func parseResponse(_ data: Data) -> (values: [String: String], fault: (code: Int?, message: String)?) {
        let delegate = LeafDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        var fault: (code: Int?, message: String)?
        if delegate.values["errorCode"] != nil || delegate.values["errorDescription"] != nil || delegate.values["faultstring"] != nil {
            fault = (code: delegate.values["errorCode"].flatMap { Int($0) },
                     message: delegate.values["errorDescription"] ?? delegate.values["faultstring"] ?? "errore sconosciuto")
        }
        return (delegate.values, fault)
    }

    private final class LeafDelegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var text = ""
        private var hasChildren: [Bool] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if !hasChildren.isEmpty { hasChildren[hasChildren.count - 1] = true }
            hasChildren.append(false)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            let leaf = !(hasChildren.popLast() ?? false)
            if leaf {
                let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
                values[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = ""
        }
    }
}

// MARK: - DIDL-Lite, time formats, MIME

public enum DIDLLite {
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "avi": return "video/x-msvideo"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "ts", "mpg", "mpeg": return "video/mpeg"
        case "wmv": return "video/x-ms-wmv"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "flac": return "audio/flac"
        default: return "video/mp4"
        }
    }

    public static func metadata(title: String, url: URL, mimeType: String, artworkURL: String? = nil) -> String {
        var xml = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
        xml += "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        xml += "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
        xml += "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
        xml += "<dc:title>\(SOAP.escape(title))</dc:title>"
        xml += "<upnp:class>object.item.videoItem</upnp:class>"
        if let artwork = artworkURL {
            xml += "<upnp:albumArtURI>\(SOAP.escape(artwork))</upnp:albumArtURI>"
        }
        xml += "<res protocolInfo=\"http-get:*:\(SOAP.escape(mimeType)):*\">\(SOAP.escape(url.absoluteString))</res>"
        xml += "</item></DIDL-Lite>"
        return xml
    }

    /// 3725.5 → "1:02:05"
    public static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%ld:%02ld:%02ld", h, m, s)
    }

    /// "1:02:05" / "01:02:05.500" → seconds; nil for "NOT_IMPLEMENTED" etc.
    public static func parseTime(_ text: String?) -> Double? {
        guard let text = text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }
}

// MARK: - SSDP

public enum SSDP {
    public static let multicastAddress = "239.255.255.250"
    public static let port: UInt16 = 1900
    public static let mediaRendererTarget = "urn:schemas-upnp-org:device:MediaRenderer:1"

    public static func searchRequest(target: String = SSDP.mediaRendererTarget, mx: Int = 2) -> Data {
        let text = "M-SEARCH * HTTP/1.1\r\nHOST: \(multicastAddress):\(port)\r\nMAN: \"ssdp:discover\"\r\nMX: \(mx)\r\nST: \(target)\r\nUSER-AGENT: Aether/1.0 UPnP/1.1\r\n\r\n"
        return Data(text.utf8)
    }

    public struct Response: Hashable, Sendable {
        public var location: URL
        public var usn: String?
        public var searchTarget: String?
        public var server: String?
    }

    public static func parse(_ data: Data) -> Response? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        if lines.count <= 1 { lines = text.components(separatedBy: "\n") }
        guard let status = lines.first, status.uppercased().hasPrefix("HTTP/1.1 200") || status.uppercased().hasPrefix("NOTIFY") else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        guard let location = headers["LOCATION"], let url = URL(string: location),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return Response(location: url, usn: headers["USN"], searchTarget: headers["ST"] ?? headers["NT"], server: headers["SERVER"])
    }
}

// MARK: - Client

public enum UPnPTransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
    case unknown

    public init(raw: String?) {
        self = raw.flatMap { UPnPTransportState(rawValue: $0.uppercased()) } ?? .unknown
    }
}

public struct UPnPPosition: Sendable, Equatable {
    public var position: Double?
    public var duration: Double?
}

/// Controls one DLNA renderer. The `HTTPClient` passed in must use a `NetworkPolicy` that allows the local network.
public final class UPnPClient: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetchDevice(location: URL) async throws -> UPnPDevice {
        let response = try await http.send(HTTPRequest(url: location, timeout: 6, maxBytes: 256 * 1024))
        guard response.isSuccess else { throw UPnPError.http(response.statusCode) }
        let device = try UPnPDescriptionParser.parse(response.data, location: location)
        guard device.isMediaRenderer else { throw UPnPError.notAMediaRenderer }
        return device
    }

    @discardableResult
    private func call(_ service: UPnPService, action: String, arguments: [(String, String)]) async throws -> [String: String] {
        let body = SOAP.envelope(serviceType: service.serviceType, action: action, arguments: arguments)
        let request = HTTPRequest(url: service.controlURL, method: "POST",
                                  headers: SOAP.headers(serviceType: service.serviceType, action: action),
                                  body: body, timeout: 8, maxBytes: 512 * 1024)
        let response = try await http.send(request)
        let parsed = SOAP.parseResponse(response.data)
        if let fault = parsed.fault { throw UPnPError.soapFault(code: fault.code, message: fault.message) }
        guard response.isSuccess else { throw UPnPError.http(response.statusCode) }
        return parsed.values
    }

    public func load(device: UPnPDevice, url: URL, title: String, artworkURL: String? = nil) async throws {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        let mime = DIDLLite.mimeType(forExtension: url.pathExtension)
        let metadata = DIDLLite.metadata(title: title, url: url, mimeType: mime, artworkURL: artworkURL)
        try await call(service, action: "SetAVTransportURI", arguments: [
            ("InstanceID", "0"), ("CurrentURI", url.absoluteString), ("CurrentURIMetaData", metadata)
        ])
    }

    public func play(device: UPnPDevice) async throws {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        try await call(service, action: "Play", arguments: [("InstanceID", "0"), ("Speed", "1")])
    }

    public func pause(device: UPnPDevice) async throws {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        try await call(service, action: "Pause", arguments: [("InstanceID", "0")])
    }

    public func stop(device: UPnPDevice) async throws {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        try await call(service, action: "Stop", arguments: [("InstanceID", "0")])
    }

    public func seek(device: UPnPDevice, to seconds: Double) async throws {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        try await call(service, action: "Seek", arguments: [
            ("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", DIDLLite.formatTime(seconds))
        ])
    }

    public func position(device: UPnPDevice) async throws -> UPnPPosition {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        let values = try await call(service, action: "GetPositionInfo", arguments: [("InstanceID", "0")])
        return UPnPPosition(position: DIDLLite.parseTime(values["RelTime"]), duration: DIDLLite.parseTime(values["TrackDuration"]))
    }

    public func transportState(device: UPnPDevice) async throws -> UPnPTransportState {
        guard let service = device.avTransport else { throw UPnPError.notAMediaRenderer }
        let values = try await call(service, action: "GetTransportInfo", arguments: [("InstanceID", "0")])
        return UPnPTransportState(raw: values["CurrentTransportState"])
    }

    public func setVolume(device: UPnPDevice, percent: Int) async throws {
        guard let service = device.renderingControl else { throw UPnPError.notAMediaRenderer }
        try await call(service, action: "SetVolume", arguments: [
            ("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(max(0, min(100, percent))))
        ])
    }
}
