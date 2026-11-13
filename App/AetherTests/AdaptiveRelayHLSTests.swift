import XCTest
import AetherCore
@testable import Aether

/// The relay must hand the receiver the same audio / subtitle renditions as the source master playlist.
final class AdaptiveRelayHLSTests: XCTestCase {
    private let base = URL(string: "https://cdn.example.com/movie/master.m3u8?token=abc")!

    private func makeSource() -> AdaptiveStreamRelaySource {
        AdaptiveStreamRelaySource(upstream: RelayUpstream(url: base), guardian: UpstreamGuard(allowPrivateOrigin: false),
                                  extension: "m3u8")
    }

    private let master = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="it",NAME="Italiano 5.1",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="6",URI="audio/it.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="en",NAME="English",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="https://cdn.example.com/movie/audio/en.m3u8?sig=1"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="it",NAME="Italiano forzati",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI="subs/it-forced.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English SDH",DEFAULT=NO,AUTOSELECT=NO,CHARACTERISTICS="public.accessibility.describes-music-and-sound",URI="subs/en.m3u8"
    #EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",LANGUAGE="en",NAME="CC",INSTREAM-ID="CC1"
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.B0,mp4a.40.2",AUDIO="aud",SUBTITLES="subs",CLOSED-CAPTIONS="cc"
    video/2160p.m3u8
    #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,URI="video/iframes.m3u8"
    """

    func testRenditionsKeepEveryAttributeAndOnlyURIsChange() throws {
        let source = makeSource()
        let output = try source.rewriteHLS(master, baseURL: base)
        let inLines = master.components(separatedBy: "\n")
        let outLines = output.components(separatedBy: "\n")
        XCTAssertEqual(inLines.count, outLines.count)
        XCTAssertFalse(output.contains("cdn.example.com"), "no upstream URL may reach the receiver")
        XCTAssertFalse(output.contains("token=") || output.contains("sig="))
        let uri = try NSRegularExpression(pattern: #"URI="[^"]*""#)
        for (before, after) in zip(inLines, outLines) where before.hasPrefix("#") {
            let strip = { (s: String) in uri.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "URI=\"\"") }
            XCTAssertEqual(strip(before), strip(after), "attributes other than URI must be preserved")
        }
        let media = outLines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }
        XCTAssertEqual(media.filter { $0.contains("TYPE=AUDIO") }.count, 2)
        XCTAssertEqual(media.filter { $0.contains("TYPE=SUBTITLES") }.count, 2)
        XCTAssertEqual(media.filter { $0.contains("TYPE=CLOSED-CAPTIONS") }.count, 1)
    }

    func testRenditionURIsResolveToTheirUpstreamPlaylists() throws {
        let source = makeSource()
        let output = try source.rewriteHLS(master, baseURL: base)
        let regex = try NSRegularExpression(pattern: #"NAME="([^"]+)".*URI="([^"]+)""#)
        var byName: [String: URL] = [:]
        for line in output.components(separatedBy: "\n") {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let name = Range(match.range(at: 1), in: line), let leaf = Range(match.range(at: 2), in: line) else { continue }
            XCTAssertTrue(line[leaf].hasSuffix(".m3u8"), "rendition playlists keep a playlist name")
            byName[String(line[name])] = source.upstreamURL(for: String(line[leaf]))
        }
        // Relative renditions inherit the signed query of the master; absolute ones keep their own.
        XCTAssertEqual(byName["Italiano 5.1"]?.absoluteString, "https://cdn.example.com/movie/audio/it.m3u8?token=abc")
        XCTAssertEqual(byName["English"]?.absoluteString, "https://cdn.example.com/movie/audio/en.m3u8?sig=1")
        XCTAssertEqual(byName["Italiano forzati"]?.absoluteString, "https://cdn.example.com/movie/subs/it-forced.m3u8?token=abc")
        XCTAssertEqual(byName["English SDH"]?.absoluteString, "https://cdn.example.com/movie/subs/en.m3u8?token=abc")
        let variant = output.components(separatedBy: "\n").first { $0.hasSuffix(".m3u8") && !$0.hasPrefix("#") }
        XCTAssertEqual(variant.flatMap { source.upstreamURL(for: $0) }?.absoluteString,
                       "https://cdn.example.com/movie/video/2160p.m3u8?token=abc")
    }

    func testSubtitleMediaPlaylistSegmentsAreServedAsWebVTT() throws {
        let source = makeSource()
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:60\n#EXTINF:60.0,\nseg-0.vtt\n#EXTINF:60.0,\nseg-1.webvtt\n#EXT-X-ENDLIST"
        let output = try source.rewriteHLS(media, baseURL: URL(string: "https://cdn.example.com/movie/subs/en.m3u8")!)
        let leaves = output.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(leaves.count, 2)
        XCTAssertEqual(source.upstreamURL(for: leaves[0])?.lastPathComponent, "seg-0.vtt")
        XCTAssertTrue(leaves.allSatisfy { $0.hasSuffix(".vtt") || $0.hasSuffix(".webvtt") })
    }

    func testSameURIUsedTwiceGetsOneLocalName() throws {
        let source = makeSource()
        let text = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"A\",URI=\"a.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"b\",NAME=\"A\",URI=\"a.m3u8\""
        let output = try source.rewriteHLS(text, baseURL: base)
        let regex = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        let names = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
            .compactMap { Range($0.range(at: 1), in: output).map { String(output[$0]) } }
        XCTAssertEqual(Set(names).count, 1)
    }

    func testEncryptedOrSteeredPlaylistsAreRefusedNotLeaked() {
        let source = makeSource()
        for text in ["#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"", "#EXTM3U\n#EXT-X-DEFINE:NAME=\"x\",VALUE=\"y\"",
                     "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\",KEYFORMAT=\"com.apple.streamingkeydelivery\""] {
            XCTAssertThrowsError(try source.rewriteHLS(text, baseURL: base))
        }
    }
}
