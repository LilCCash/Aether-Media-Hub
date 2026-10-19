import XCTest
@testable import AetherCore

final class ManifestTests: XCTestCase {
    func testDecodesFullManifest() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_full.json"))
        XCTAssertEqual(manifest.id, "org.aether.fixture.full")
        XCTAssertEqual(manifest.version, "1.2.0")
        XCTAssertEqual(manifest.catalogs.count, 3)
        XCTAssertEqual(manifest.catalogs[0].genreOptions, ["Azione", "Commedia"])
        XCTAssertTrue(manifest.catalogs[0].supportsSearch)
        XCTAssertTrue(manifest.catalogs[0].supportsSkip)
        XCTAssertEqual(manifest.resources.count, 4)
        XCTAssertEqual(manifest.resource(named: "meta")?.idPrefixes, ["fx"])
        XCTAssertNil(manifest.resource(named: "catalog")?.types, "string resources carry no types")
        XCTAssertEqual(manifest.capabilitySummary, ["catalog", "meta", "stream", "subtitles"])
    }

    func testLegacyShortExtraFormat() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_legacy_extra.json"))
        let catalog = manifest.catalogs[0]
        XCTAssertEqual(catalog.extra.map { $0.name }, ["search", "skip"])
        XCTAssertTrue(catalog.extraProperty("search")?.isRequired ?? false)
        XCTAssertFalse(catalog.isExtraSupported([]))
        XCTAssertTrue(catalog.isExtraSupported([ExtraValue(name: "search", value: "x")]))
    }

    func testCatalogExtraSupportMirrorsCore() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_full.json"))
        let top = manifest.catalogs[0]
        XCTAssertTrue(top.isExtraSupported([]))
        XCTAssertTrue(top.isExtraSupported([ExtraValue(name: "skip", value: "100")]))
        XCTAssertTrue(top.isExtraSupported([ExtraValue(name: "genre", value: "Azione"), ExtraValue(name: "skip", value: "0")]))
        XCTAssertFalse(top.isExtraSupported([ExtraValue(name: "undeclared", value: "1")]))
        let searchOnly = manifest.catalogs[2]
        XCTAssertFalse(searchOnly.isExtraSupported([]), "required extra missing")
        XCTAssertTrue(searchOnly.isExtraSupported([ExtraValue(name: "search", value: "a")]))
        XCTAssertFalse(searchOnly.isPlainFeed)
    }

    func testResourceRoutingByTypeAndPrefix() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_full.json"))
        func path(_ resource: String, _ type: String, _ id: String, _ extra: [ExtraValue] = []) -> ResourcePath {
            return ResourcePath(resource: resource, type: type, id: id, extra: extra)
        }
        XCTAssertTrue(manifest.supports(path("catalog", "movie", "top")))
        XCTAssertFalse(manifest.supports(path("catalog", "movie", "missing")))
        XCTAssertFalse(manifest.supports(path("catalog", "channel", "top")))
        XCTAssertTrue(manifest.supports(path("meta", "movie", "fx1")))
        XCTAssertFalse(manifest.supports(path("meta", "movie", "tt1")), "meta limited to the fx prefix")
        XCTAssertFalse(manifest.supports(path("meta", "channel", "fx1")))
        XCTAssertTrue(manifest.supports(path("stream", "series", "tt0898266:9:17")))
        XCTAssertFalse(manifest.supports(path("stream", "series", "other:1")))
        XCTAssertTrue(manifest.supports(path("subtitles", "movie", "anything")), "no idPrefixes means all ids")
        XCTAssertFalse(manifest.supports(path("addon_catalog", "movie", "x")))
    }

    func testShortResourcesInheritManifestTypes() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_minimal_short.json"))
        XCTAssertTrue(manifest.supports(ResourcePath(resource: "stream", type: "movie", id: "anything")))
        XCTAssertFalse(manifest.supports(ResourcePath(resource: "stream", type: "series", id: "anything")))
        XCTAssertFalse(manifest.supports(ResourcePath(resource: "meta", type: "movie", id: "x")))
        XCTAssertEqual(manifest.catalogs[0].name, "bbb", "name falls back to the catalog id")
    }

    func testRejectsInvalidManifests() throws {
        XCTAssertThrowsError(try ResponseDecoder.decodeManifest(Fixture.data("manifest_invalid_no_id.json"))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .missingField("id"))
        }
        XCTAssertThrowsError(try ResponseDecoder.decodeManifest(Fixture.data("manifest_invalid_no_resources.json"))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .noResources)
        }
        XCTAssertThrowsError(try ResponseDecoder.decodeManifest(Data("<html>not json</html>".utf8))) { error in
            XCTAssertEqual(error as? ResponseDecodingError, .notJSON)
        }
        XCTAssertThrowsError(try ResponseDecoder.decodeManifest(Data("[1,2,3]".utf8))) { error in
            XCTAssertEqual(error as? ResponseDecodingError, .notAnObject)
        }
    }

    func testBehaviorHints() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_p2p_adult.json"))
        XCTAssertTrue(manifest.behaviorHints.p2p)
        XCTAssertTrue(manifest.behaviorHints.adult)
        let config = try ResponseDecoder.decodeManifest(Fixture.data("manifest_configuration_required.json"))
        XCTAssertTrue(config.behaviorHints.configurationRequired)
    }

    func testManifestRoundTripsThroughCodable() throws {
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_full.json"))
        let encoded = try JSONEncoder.aether().encode(manifest)
        let decoded = try JSONDecoder.aether().decode(AddonManifest.self, from: encoded)
        XCTAssertEqual(decoded.catalogs, manifest.catalogs)
        XCTAssertEqual(decoded.resources, manifest.resources)
        XCTAssertEqual(decoded.id, manifest.id)
    }
}

final class ResponseDecodingTests: XCTestCase {
    func testCatalogSkipsInvalidItemsAndAcceptsLooseTypes() throws {
        let response = try ResponseDecoder.decode(Fixture.data("catalog_movies.json"), resource: "catalog")
        guard case .metas(let items) = response.payload else { return XCTFail("expected metas") }
        XCTAssertEqual(items.map { $0.id }, ["fx1", "fx2", "tt0000003", "fx5"], "the item without id is skipped")
        XCTAssertEqual(items[1].releaseInfo, "2010", "numeric releaseInfo is accepted")
        XCTAssertEqual(items[1].imdbRating, "7.4", "numeric rating becomes a string")
        XCTAssertEqual(items[2].posterShape, .landscape)
        XCTAssertEqual(items[2].imdbID, "tt0000003")
        XCTAssertNil(items[0].imdbID)
        XCTAssertEqual(items[0].year, 2008)
        XCTAssertEqual(response.cache.maxAge, 120)
    }

    func testNullAndEmptyCatalogsAreValidEmptyResults() throws {
        for name in ["catalog_null.json", "catalog_empty.json"] {
            let response = try ResponseDecoder.decode(Fixture.data(name), resource: "catalog")
            guard case .metas(let items) = response.payload else { return XCTFail("expected metas") }
            XCTAssertTrue(items.isEmpty)
        }
    }

    func testMalformedCatalogResponses() {
        XCTAssertThrowsError(try ResponseDecoder.decode(Data("{}".utf8), resource: "catalog")) { error in
            XCTAssertEqual(error as? ResponseDecodingError, .missingKey("metas"))
        }
        XCTAssertThrowsError(try ResponseDecoder.decode(Data("garbage".utf8), resource: "catalog")) { error in
            XCTAssertEqual(error as? ResponseDecodingError, .notJSON)
        }
        XCTAssertThrowsError(try ResponseDecoder.decode(Data("[]".utf8), resource: "catalog")) { error in
            XCTAssertEqual(error as? ResponseDecodingError, .notAnObject)
        }
    }

    func testSeriesMetaSortsEpisodesAndSkipsBadVideos() throws {
        let response = try ResponseDecoder.decode(Fixture.data("meta_series.json"), resource: "meta")
        guard case .meta(let meta) = response.payload else { return XCTFail("expected meta") }
        XCTAssertEqual(meta.videos.map { $0.id },
                       ["fx-series:0:1", "fx-series:1:1", "fx-series:1:2", "fx-series:2:1", "fx-series:9:9"])
        XCTAssertEqual(meta.seasons, [0, 1, 2, 9])
        XCTAssertEqual(meta.videos(inSeason: 1).count, 2)
        XCTAssertEqual(meta.directors, ["R. Regista"])
        XCTAssertEqual(meta.cast.count, 2)
        XCTAssertEqual(meta.trailers.first?.youtubeID, "dQw4w9WgXcQ")
        XCTAssertEqual(meta.links.first?.category, "Genres")
        XCTAssertEqual(meta.videos[1].episodeLabel, "S01E01")
        XCTAssertNotNil(meta.videos[1].released)
        XCTAssertEqual(meta.ratingValue ?? 0, 8.3, accuracy: 0.001)
    }

    func testStreamSourcesAreClassified() throws {
        let response = try ResponseDecoder.decode(Fixture.data("streams_mixed.json"), resource: "stream")
        guard case .streams(let streams) = response.payload else { return XCTFail("expected streams") }
        XCTAssertEqual(streams.count, 10, "the string element is dropped, the empty object becomes .unknown")
        XCTAssertEqual(streams[0].source, .url("https://cdn.fixture.test/movie.mp4"))
        XCTAssertEqual(streams[0].details?.contains("1080p"), true, "title is used when description is absent")
        XCTAssertEqual(streams[0].behaviorHints.bingeGroup, "fixture-1080p")
        XCTAssertEqual(streams[0].behaviorHints.videoSize, 1503238553)
        XCTAssertEqual(streams[0].behaviorHints.filename, "movie.mp4")
        XCTAssertEqual(streams[1].details, "2160p HEVC HDR10 Atmos")
        XCTAssertEqual(streams[4].source, .torrent(infoHash: "0123456789abcdef0123456789abcdef01234567", fileIndex: 1,
                                                    trackers: ["tracker:udp://tracker.fixture.test:80"]))
        XCTAssertEqual(streams[5].source, .youtube("dQw4w9WgXcQ"))
        XCTAssertEqual(streams[6].source, .archive(kind: "nzb"))
        XCTAssertEqual(streams[7].source, .external("https://www.fixture.test/watch"))
        XCTAssertEqual(streams[8].behaviorHints.proxyRequestHeaders["User-Agent"], "Fixture/1.0")
        XCTAssertEqual(streams[8].behaviorHints.proxyRequestHeaders["Referer"], "5")
        XCTAssertEqual(streams[9].source, .unknown)
        XCTAssertEqual(response.cache.maxAge, 30)
    }

    func testStreamCodableRoundTrip() throws {
        let response = try ResponseDecoder.decode(Fixture.data("streams_mixed.json"), resource: "stream")
        guard case .streams(let streams) = response.payload else { return XCTFail("expected streams") }
        let data = try JSONEncoder.aether().encode(streams[0])
        let again = try JSONDecoder.aether().decode(AddonStream.self, from: data)
        XCTAssertEqual(again.source, streams[0].source)
        XCTAssertEqual(again.behaviorHints, streams[0].behaviorHints)
    }

    func testSubtitlesAndAddonCatalog() throws {
        let subs = try ResponseDecoder.decode(Fixture.data("subtitles.json"), resource: "subtitles")
        guard case .subtitles(let list) = subs.payload else { return XCTFail("expected subtitles") }
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].lang, "ita")
        XCTAssertEqual(list[1].label, "English [CC]")
        XCTAssertEqual(list[2].id, list[2].url, "id falls back to the url")

        let addons = try ResponseDecoder.decode(Fixture.data("addon_catalog.json"), resource: "addon_catalog")
        guard case .addons(let entries) = addons.payload else { return XCTFail("expected addons") }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].manifest.id, "org.other")
    }

    func testLossyArrayDoesNotLoopOnBadElements() throws {
        struct Wrapper: Decodable {
            var items: [Int]
            enum CodingKeys: String, CodingKey { case items }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                items = c.lossyArray(Int.self, forKey: .items)
            }
        }
        let json = Data("{\"items\":[1,\"x\",{\"a\":1},null,[2],3]}".utf8)
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: json)
        XCTAssertEqual(wrapper.items, [1, 3])
    }

    func testDateParsing() {
        XCTAssertNotNil(AddonDate.parse("2010-12-06T05:00:00.000Z"))
        XCTAssertNotNil(AddonDate.parse("2010-12-06T05:00:00Z"))
        XCTAssertNotNil(AddonDate.parse("2010-12-06"))
        XCTAssertNotNil(AddonDate.parse("2010-12-06 05:00"))
        XCTAssertNil(AddonDate.parse("not a date"))
        XCTAssertNil(AddonDate.parse(nil))
    }

    func testMetaMerging() {
        let primary = MetaItem(id: "x", type: "movie", name: "X", poster: nil, description: "desc")
        let secondary = MetaItem(id: "x", type: "movie", name: "X", poster: "p.jpg", background: "b.jpg", description: "other", genres: ["A"])
        let merged = primary.merging(fallback: secondary)
        XCTAssertEqual(merged.poster, "p.jpg")
        XCTAssertEqual(merged.background, "b.jpg")
        XCTAssertEqual(merged.description, "desc", "existing values are never overwritten")
        XCTAssertEqual(merged.genres, ["A"])
    }

    func testLargeCatalogDecodesQuickly() throws {
        var items: [String] = []
        items.reserveCapacity(10_000)
        for i in 0..<10_000 {
            items.append("{\"id\":\"tt\(1_000_000 + i)\",\"type\":\"movie\",\"name\":\"Titolo \(i)\",\"poster\":\"https://img.test/\(i).jpg\",\"releaseInfo\":\"\(1950 + i % 70)\",\"genres\":[\"A\",\"B\"]}")
        }
        let data = Data("{\"metas\":[\(items.joined(separator: ","))]}".utf8)
        let start = Date()
        let response = try ResponseDecoder.decode(data, resource: "catalog")
        let elapsed = Date().timeIntervalSince(start)
        guard case .metas(let decoded) = response.payload else { return XCTFail("expected metas") }
        XCTAssertEqual(decoded.count, 10_000)
        XCTAssertLessThan(elapsed, 5.0, "10k items must decode well under a few seconds")
    }
}
