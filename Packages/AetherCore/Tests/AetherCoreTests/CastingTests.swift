import XCTest
@testable import AetherCore

final class CastCompatibilityTests: XCTestCase {
    private func info(_ url: String, details: String = "", hints: StreamBehaviorHints = StreamBehaviorHints()) -> (URL, StreamInfo) {
        let stream = AddonStream(source: .url(url), details: details, behaviorHints: hints)
        return (URL(string: url)!, StreamAnalyzer.analyze(stream))
    }

    func testHostClassification() {
        XCTAssertEqual(CastCompatibility.hostKind(of: URL(string: "https://cdn.example.com/a.mp4")!), .publicInternet)
        XCTAssertEqual(CastCompatibility.hostKind(of: URL(string: "http://192.168.1.20:8080/a.mp4")!), .localNetwork)
        XCTAssertEqual(CastCompatibility.hostKind(of: URL(string: "http://nas.local/a.mp4")!), .localNetwork)
        XCTAssertEqual(CastCompatibility.hostKind(of: URL(string: "http://127.0.0.1:8080/a.mp4")!), .loopback)
        XCTAssertEqual(CastCompatibility.hostKind(of: URL(string: "http://localhost/a.mp4")!), .loopback)
    }

    func testLoopbackIsBlockedForEveryTarget() {
        let (url, details) = info("http://127.0.0.1:8080/a.mp4")
        for target in CastTarget.allCases {
            XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, target: target).isBlocked, target.title)
        }
    }

    func testPublicMP4WorksEverywhere() {
        let (url, details) = info("https://cdn.example.com/a.mp4", details: "1080p x264")
        for target in CastTarget.allCases {
            let verdict = CastCompatibility.evaluate(url: url, info: details, target: target)
            XCTAssertFalse(verdict.isBlocked, target.title)
        }
        XCTAssertEqual(CastCompatibility.evaluate(url: url, info: details, target: .googleCast), .ok)
        XCTAssertEqual(CastCompatibility.evaluate(url: url, info: details, target: .airPlay), .ok)
    }

    func testLocalNetworkSourcesWarnForCastAndDLNA() {
        let (url, details) = info("http://192.168.1.20/a.mp4")
        let verdict = CastCompatibility.evaluate(url: url, info: details, target: .googleCast)
        guard case .warning(let messages) = verdict else { return XCTFail("expected warning, got \(verdict)") }
        XCTAssertTrue(messages.contains(where: { $0.contains("rete locale") }))
    }

    func testHeadersBlockCastAndDLNAButOnlyWarnAirPlay() {
        let hints = StreamBehaviorHints(notWebReady: true, proxyRequestHeaders: ["Referer": "https://x.test"])
        let (url, details) = info("https://cdn.example.com/a.mp4", hints: hints)
        XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, headers: hints.proxyRequestHeaders, target: .googleCast).isBlocked)
        XCTAssertTrue(CastCompatibility.evaluate(url: url, info: details, headers: hints.proxyRequestHeaders, target: .dlna).isBlocked)
        guard case .warning = CastCompatibility.evaluate(url: url, info: details, headers: hints.proxyRequestHeaders, target: .airPlay) else {
            return XCTFail("AirPlay should warn only")
        }
    }

    func testContainerRulesPerProtocol() {
        let mkv = info("https://cdn.example.com/a.mkv")
        XCTAssertTrue(CastCompatibility.evaluate(url: mkv.0, info: mkv.1, target: .airPlay).isBlocked, "AVPlayer cannot play MKV")
        guard case .warning(let castMessages) = CastCompatibility.evaluate(url: mkv.0, info: mkv.1, target: .googleCast) else {
            return XCTFail("MKV on Cast should warn")
        }
        XCTAssertTrue(castMessages.contains(where: { $0.contains("MKV") }))
        XCTAssertFalse(CastCompatibility.evaluate(url: mkv.0, info: mkv.1, target: .dlna).isBlocked, "DLNA TVs commonly play MKV")

        let avi = info("https://cdn.example.com/a.avi")
        XCTAssertTrue(CastCompatibility.evaluate(url: avi.0, info: avi.1, target: .googleCast).isBlocked)

        let dash = info("https://cdn.example.com/a.mpd")
        XCTAssertTrue(CastCompatibility.evaluate(url: dash.0, info: dash.1, target: .dlna).isBlocked)
        XCTAssertFalse(CastCompatibility.evaluate(url: dash.0, info: dash.1, target: .googleCast).isBlocked)

        let hls = info("https://cdn.example.com/a.m3u8")
        XCTAssertFalse(CastCompatibility.evaluate(url: hls.0, info: hls.1, target: .googleCast).isBlocked)
        XCTAssertFalse(CastCompatibility.evaluate(url: hls.0, info: hls.1, target: .airPlay).isBlocked)
        XCTAssertFalse(CastCompatibility.evaluate(url: hls.0, info: hls.1, target: .dlna).messages.isEmpty, "DLNA HLS warns")
    }

    func testExternalSubtitlesWarnPerProtocol() {
        let (url, details) = info("https://cdn.example.com/a.mp4")
        for target in CastTarget.allCases {
            let verdict = CastCompatibility.evaluate(url: url, info: details, target: target, hasExternalSubtitles: true)
            XCTAssertFalse(verdict.messages.isEmpty, "\(target.title) should explain subtitle limits")
        }
    }

    func testAndroidTVGuidanceMentionsTheCastVsDLNADistinction() {
        let text = CastCompatibility.androidTVGuidance.joined(separator: " ")
        XCTAssertTrue(text.contains("Chromecast"))
        XCTAssertTrue(text.contains("DLNA"))
    }
}

final class UPnPTests: XCTestCase {
    private let rendererXML = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
      <specVersion><major>1</major><minor>0</minor></specVersion>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>Salotto TV</friendlyName>
        <manufacturer>Acme</manufacturer>
        <modelName>TV-9000</modelName>
        <UDN>uuid:1234-abcd</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
            <controlURL>/upnp/control/AVTransport</controlURL>
            <eventSubURL>/upnp/event/AVTransport</eventSubURL>
            <SCPDURL>/upnp/scpd/AVTransport.xml</SCPDURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
            <controlURL>/upnp/control/RenderingControl</controlURL>
          </service>
        </serviceList>
        <deviceList>
          <device><friendlyName>Embedded</friendlyName><UDN>uuid:embedded</UDN></device>
        </deviceList>
      </device>
    </root>
    """

    private let location = URL(string: "http://192.168.1.50:8080/description.xml")!

    func testParsesRendererDescription() throws {
        let device = try UPnPDescriptionParser.parse(Data(rendererXML.utf8), location: location)
        XCTAssertEqual(device.friendlyName, "Salotto TV", "embedded devices must not override the root device")
        XCTAssertEqual(device.udn, "uuid:1234-abcd")
        XCTAssertEqual(device.manufacturer, "Acme")
        XCTAssertEqual(device.modelName, "TV-9000")
        XCTAssertTrue(device.isMediaRenderer)
        XCTAssertEqual(device.avTransport?.controlURL.absoluteString, "http://192.168.1.50:8080/upnp/control/AVTransport")
        XCTAssertEqual(device.renderingControl?.controlURL.path, "/upnp/control/RenderingControl")
        XCTAssertEqual(device.id, "uuid:1234-abcd")
    }

    func testURLBaseOverridesTheLocation() throws {
        let xml = rendererXML.replacingOccurrences(of: "<specVersion>", with: "<URLBase>http://10.0.0.9:9000/</URLBase><specVersion>")
        let device = try UPnPDescriptionParser.parse(Data(xml.utf8), location: location)
        XCTAssertEqual(device.avTransport?.controlURL.absoluteString, "http://10.0.0.9:9000/upnp/control/AVTransport")
    }

    func testRejectsGarbageAndNonRenderers() async throws {
        XCTAssertThrowsError(try UPnPDescriptionParser.parse(Data("not xml".utf8), location: location))
        let server = FakeServer()
        server.set(location.absoluteString, body: Data("<root><device><friendlyName>Printer</friendlyName></device></root>".utf8))
        let client = UPnPClient(http: server)
        do {
            _ = try await client.fetchDevice(location: location)
            XCTFail("expected notAMediaRenderer")
        } catch let error as UPnPError {
            XCTAssertEqual(error, .notAMediaRenderer)
        }
    }

    func testSOAPEnvelopeEscapesArguments() {
        let data = SOAP.envelope(serviceType: "urn:schemas-upnp-org:service:AVTransport:1", action: "SetAVTransportURI",
                                 arguments: [("InstanceID", "0"), ("CurrentURI", "http://x/a?b=1&c=2"), ("CurrentURIMetaData", "<DIDL-Lite/>")])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"))
        XCTAssertTrue(text.contains("<CurrentURI>http://x/a?b=1&amp;c=2</CurrentURI>"))
        XCTAssertTrue(text.contains("<CurrentURIMetaData>&lt;DIDL-Lite/&gt;</CurrentURIMetaData>"))
        let headers = SOAP.headers(serviceType: "urn:schemas-upnp-org:service:AVTransport:1", action: "Play")
        XCTAssertEqual(headers["SOAPAction"], "\"urn:schemas-upnp-org:service:AVTransport:1#Play\"")
    }

    func testDIDLMetadataAndTimeFormats() throws {
        let didl = DIDLLite.metadata(title: "A & B <3", url: URL(string: "http://cdn/x.mkv?a=1&b=2")!, mimeType: "video/x-matroska")
        XCTAssertTrue(didl.contains("<dc:title>A &amp; B &lt;3</dc:title>"))
        XCTAssertTrue(didl.contains("protocolInfo=\"http-get:*:video/x-matroska:*\""))
        XCTAssertTrue(didl.contains("x.mkv?a=1&amp;b=2"))
        XCTAssertEqual(DIDLLite.mimeType(forExtension: "MKV"), "video/x-matroska")
        XCTAssertEqual(DIDLLite.mimeType(forExtension: "m3u8"), "application/vnd.apple.mpegurl")
        XCTAssertEqual(DIDLLite.formatTime(3725.5), "1:02:05")
        XCTAssertEqual(DIDLLite.formatTime(-4), "0:00:00")
        XCTAssertEqual(try XCTUnwrap(DIDLLite.parseTime("1:02:05")), 3725, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(DIDLLite.parseTime("00:00:07.500")), 7.5, accuracy: 0.001)
        XCTAssertNil(DIDLLite.parseTime("NOT_IMPLEMENTED"))
        XCTAssertNil(DIDLLite.parseTime(nil))
    }

    func testSSDPRequestAndResponse() throws {
        let request = String(decoding: SSDP.searchRequest(), as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("M-SEARCH * HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("HOST: 239.255.255.250:1900"))
        XCTAssertTrue(request.contains("MAN: \"ssdp:discover\""))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))

        let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.50:8080/description.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\nUSN: uuid:1234::urn:schemas-upnp-org:device:MediaRenderer:1\r\nSERVER: Linux/4 UPnP/1.0\r\n\r\n"
        let parsed = try XCTUnwrap(SSDP.parse(Data(reply.utf8)))
        XCTAssertEqual(parsed.location.absoluteString, "http://192.168.1.50:8080/description.xml")
        XCTAssertEqual(parsed.searchTarget, SSDP.mediaRendererTarget)
        XCTAssertNil(SSDP.parse(Data("HTTP/1.1 404 Not Found\r\n\r\n".utf8)))
        XCTAssertNil(SSDP.parse(Data("HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n\r\n".utf8)), "only http(s) locations are accepted")
        XCTAssertNil(SSDP.parse(Data([0xFF, 0xFE, 0x00])))
    }

    func testClientIssuesTheExpectedSOAPCalls() async throws {
        let server = FakeServer()
        server.set(location.absoluteString, body: Data(rendererXML.utf8))
        let control = "http://192.168.1.50:8080/upnp/control/AVTransport"
        let okResponse = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:Response xmlns:u=\"x\"/></s:Body></s:Envelope>"
        server.set(control, body: Data(okResponse.utf8))
        let client = UPnPClient(http: server)
        let device = try await client.fetchDevice(location: location)

        try await client.load(device: device, url: URL(string: "http://cdn.test/movie.mp4")!, title: "Film")
        try await client.play(device: device)
        try await client.seek(device: device, to: 125)
        try await client.pause(device: device)
        try await client.stop(device: device)

        let calls = server.requests.filter { $0.method == "POST" }
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls.compactMap { $0.headers["SOAPAction"] }.map { $0.components(separatedBy: "#").last ?? "" },
                       ["SetAVTransportURI\"", "Play\"", "Seek\"", "Pause\"", "Stop\""])
        let seekBody = String(decoding: calls[2].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(seekBody.contains("<Target>0:02:05</Target>"))
        XCTAssertTrue(seekBody.contains("<Unit>REL_TIME</Unit>"))
    }

    func testClientParsesStateAndPosition() async throws {
        let server = FakeServer()
        server.set(location.absoluteString, body: Data(rendererXML.utf8))
        let control = "http://192.168.1.50:8080/upnp/control/AVTransport"
        let envelope = { (inner: String) -> Data in
            Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>\(inner)</s:Body></s:Envelope>".utf8)
        }
        server.set(control, body: envelope("<u:GetPositionInfoResponse xmlns:u=\"x\"><Track>1</Track><TrackDuration>0:10:00</TrackDuration><RelTime>0:01:30</RelTime></u:GetPositionInfoResponse>"))
        let client = UPnPClient(http: server)
        let device = try await client.fetchDevice(location: location)
        let position = try await client.position(device: device)
        XCTAssertEqual(position.position, 90)
        XCTAssertEqual(position.duration, 600)

        server.set(control, body: envelope("<u:GetTransportInfoResponse xmlns:u=\"x\"><CurrentTransportState>PAUSED_PLAYBACK</CurrentTransportState></u:GetTransportInfoResponse>"))
        let state = try await client.transportState(device: device)
        XCTAssertEqual(state, .paused)
    }

    func testSOAPFaultsAreSurfaced() async throws {
        let server = FakeServer()
        server.set(location.absoluteString, body: Data(rendererXML.utf8))
        let fault = "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>714</errorCode><errorDescription>Illegal MIME-type</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
        server.set("http://192.168.1.50:8080/upnp/control/AVTransport", status: 500, body: Data(fault.utf8))
        let client = UPnPClient(http: server)
        let device = try await client.fetchDevice(location: location)
        do {
            try await client.play(device: device)
            XCTFail("expected soapFault")
        } catch let error as UPnPError {
            XCTAssertEqual(error, .soapFault(code: 714, message: "Illegal MIME-type"))
            XCTAssertTrue(error.message.contains("714"))
        }
    }
}
