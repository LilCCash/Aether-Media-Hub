import XCTest
@testable import AetherCore

// A torrent stream counts as playable only when a debrid service (TorBox) is available; nothing else changes.

final class StreamAnalyzerDebridTests: XCTestCase {
    private let hash = "0123456789abcdef0123456789abcdef01234567"

    private func torrent(_ name: String? = nil, filename: String? = nil) -> AddonStream {
        var hints = StreamBehaviorHints()
        hints.filename = filename
        return AddonStream(source: .torrent(infoHash: hash, fileIndex: nil, trackers: []), name: name, behaviorHints: hints)
    }

    func testCapabilitiesDefaultToNoDebrid() {
        let defaults = PlaybackCapabilities()
        XCTAssertFalse(defaults.debridAvailable)
        XCTAssertFalse(PlaybackCapabilities.avPlayerOnly.debridAvailable)
        XCTAssertFalse(PlaybackCapabilities(mpvAvailable: true).debridAvailable, "the old initialiser keeps meaning no debrid")
        XCTAssertNotEqual(PlaybackCapabilities(mpvAvailable: false, debridAvailable: true), PlaybackCapabilities())
    }

    func testATorrentIsRefusedWithoutADebridService() {
        let info = StreamAnalyzer.analyze(torrent())
        XCTAssertEqual(info.kind, .torrent)
        XCTAssertEqual(info.support, .unsupported(.torrent))
        let withMPV = StreamAnalyzer.analyze(torrent(), capabilities: PlaybackCapabilities(mpvAvailable: true))
        XCTAssertEqual(withMPV.support, .unsupported(.torrent), "MPV does not resolve torrents")
    }

    func testATorrentIsPlayableThroughTheDebridServiceWhenOneIsAvailable() {
        let capabilities = PlaybackCapabilities(mpvAvailable: false, debridAvailable: true)
        let info = StreamAnalyzer.analyze(torrent(), capabilities: capabilities)
        XCTAssertEqual(info.kind, .torrent)
        XCTAssertTrue(info.support.isPlayable)
        XCTAssertEqual(info.support, .unknown, "the container is only known after the provider has been asked")
        XCTAssertNil(info.container)
        XCTAssertTrue(info.warnings.isEmpty, "no 'external server' warning on the debrid path")
    }

    func testTheDebridServiceWinsOverAnExternalStreamingServer() {
        let server = URL(string: "http://192.168.1.5:11470")!
        let capabilities = PlaybackCapabilities(mpvAvailable: false, debridAvailable: true)
        let info = StreamAnalyzer.analyze(torrent(), streamingServer: server, capabilities: capabilities)
        XCTAssertEqual(info.support, .unknown)
        XCTAssertTrue(info.warnings.isEmpty, "the experimental-server warning belongs to the other path")
        let serverOnly = StreamAnalyzer.analyze(torrent(), streamingServer: server)
        XCTAssertFalse(serverOnly.warnings.isEmpty)
    }

    func testDebridDoesNotChangeOtherSources() {
        let capabilities = PlaybackCapabilities(mpvAvailable: false, debridAvailable: true)
        let direct = AddonStream(source: .url("https://cdn.test/file.mp4"))
        XCTAssertEqual(StreamAnalyzer.analyze(direct, capabilities: capabilities).support, .supported)
        let mkv = AddonStream(source: .url("https://cdn.test/file.mkv"))
        XCTAssertEqual(StreamAnalyzer.analyze(mkv, capabilities: capabilities).support, .unsupported(.container("mkv")))
        let youtube = AddonStream(source: .youtube("abc"))
        XCTAssertEqual(StreamAnalyzer.analyze(youtube, capabilities: capabilities).support, .unsupported(.youtube))
        let archive = AddonStream(source: .archive(kind: "rar"))
        XCTAssertEqual(StreamAnalyzer.analyze(archive, capabilities: capabilities).support, .unsupported(.archive("rar")))
    }

    func testRankingKeepsDirectLinksAheadOfTorrentsAndTorrentsAheadOfUnplayable() {
        let direct = AddonStream(source: .url("https://cdn.test/file.mp4"), name: "Diretto")
        let bt = torrent("Torrent")
        let youtube = AddonStream(source: .youtube("abc"), name: "Trailer")
        var preferences = StreamPreferences()
        preferences.capabilities = PlaybackCapabilities(mpvAvailable: false, debridAvailable: true)
        let ranked = StreamSelector.rank([youtube, bt, direct], preferences: preferences)
        XCTAssertEqual(ranked.map { $0.stream.name ?? "" }, ["Diretto", "Torrent", "Trailer"])
        let auto = StreamSelector.autoSelect(ranked)
        XCTAssertEqual(auto?.stream.name, "Diretto")
    }

    func testWithoutDebridATorrentRanksAsUnplayable() {
        let bt = torrent("Torrent")
        let direct = AddonStream(source: .url("https://cdn.test/file.mp4"), name: "Diretto")
        let ranked = StreamSelector.rank([bt, direct], preferences: StreamPreferences())
        XCTAssertEqual(ranked.map { $0.stream.name ?? "" }, ["Diretto", "Torrent"])
        XCTAssertFalse(ranked[1].info.support.isPlayable)
    }
}
