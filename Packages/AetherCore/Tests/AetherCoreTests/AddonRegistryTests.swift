import XCTest
@testable import AetherCore

final class AddonRegistryTests: XCTestCase {
    func testInstallsAValidAddon() async throws {
        let env = try TestEnvironment()
        let addon = try await env.install(manifestFixture: "manifest_full.json", at: "https://addon.test/manifest.json")
        XCTAssertEqual(addon.manifest.name, "Fixture Full")
        XCTAssertEqual(addon.host, "addon.test")
        XCTAssertTrue(addon.isEnabled)
        let all = await env.registry.all()
        XCTAssertEqual(all.count, 1)
        let handles = await env.registry.handles()
        XCTAssertEqual(handles.first?.transportURL.absoluteString, "https://addon.test/manifest.json")
    }

    func testRejectsInvalidManifestsWithoutChangingState() async throws {
        let env = try TestEnvironment()
        try env.server.set("https://bad.test/manifest.json", fixture: "manifest_invalid_no_id.json")
        do {
            _ = try await env.registry.install(input: "https://bad.test/manifest.json")
            XCTFail("expected invalidManifest")
        } catch let error as AddonError {
            guard case .invalidManifest = error else { return XCTFail("unexpected \(error)") }
        }
        env.server.set("https://html.test/manifest.json", body: Data("<html></html>".utf8))
        do {
            _ = try await env.registry.install(input: "https://html.test/manifest.json")
            XCTFail("expected invalidManifest")
        } catch let error as AddonError {
            guard case .invalidManifest = error else { return XCTFail("unexpected \(error)") }
        }
        let count = await env.registry.all().count
        XCTAssertEqual(count, 0)
    }

    func testReportsHTTPAndNetworkFailures() async throws {
        let env = try TestEnvironment()
        env.server.set("https://down.test/manifest.json", status: 503, body: Data("busy".utf8))
        do {
            _ = try await env.registry.install(input: "https://down.test/manifest.json")
            XCTFail("expected http error")
        } catch let error as AddonError {
            XCTAssertEqual(error, .http(status: 503))
        }
        env.server.set("https://offline.test/manifest.json", error: AddonError.offline)
        do {
            _ = try await env.registry.install(input: "https://offline.test/manifest.json")
            XCTFail("expected offline")
        } catch let error as AddonError {
            XCTAssertEqual(error, .offline)
        }
        do {
            _ = try await env.registry.install(input: "https://nothing.test/manifest.json")
            XCTFail("expected 404")
        } catch let error as AddonError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testConfigurationRequiredAddonsAreRefused() async throws {
        let env = try TestEnvironment()
        try env.server.set("https://cfg.test/manifest.json", fixture: "manifest_configuration_required.json")
        do {
            _ = try await env.registry.install(input: "https://cfg.test/manifest.json")
            XCTFail("expected configurationRequired")
        } catch let error as AddonError {
            XCTAssertEqual(error, .configurationRequired)
        }
    }

    func testPreviewWarnsAboutUnknownP2PAdultAndSameId() async throws {
        let env = try TestEnvironment()
        try env.server.set("https://p2p.test/manifest.json", fixture: "manifest_p2p_adult.json")
        let preview = try await env.registry.preview(input: "https://p2p.test/manifest.json")
        XCTAssertTrue(preview.warnings.contains(.unknownAddon))
        XCTAssertTrue(preview.warnings.contains(.p2p))
        XCTAssertTrue(preview.warnings.contains(.adult))
        XCTAssertNil(preview.existing)

        _ = try await env.registry.install(preview)
        try env.server.set("https://p2p-copy.test/manifest.json", fixture: "manifest_p2p_adult.json")
        let copy = try await env.registry.preview(input: "https://p2p-copy.test/manifest.json")
        XCTAssertTrue(copy.warnings.contains(.sameIdDifferentURL(existingName: "P2P Adult")))
    }

    func testCinemetaFromItsRealHostIsRecognisedAsOfficial() async throws {
        let env = try TestEnvironment()
        let manifest = """
        {"id":"com.linvo.cinemeta","version":"3.0.0","name":"Cinemeta","types":["movie","series"],
         "resources":["catalog",{"name":"meta","types":["movie","series"],"idPrefixes":["tt"]}],
         "catalogs":[{"type":"movie","id":"top"}]}
        """
        env.server.set("https://v3-cinemeta.strem.io/manifest.json", json: manifest)
        let official = try await env.registry.preview(input: "https://v3-cinemeta.strem.io/manifest.json")
        XCTAssertTrue(official.isOfficial)
        XCTAssertFalse(official.warnings.contains(.unknownAddon))

        // An impostor claiming the same manifest id from another host gets no special treatment.
        env.server.set("https://evil.test/manifest.json", json: manifest)
        let impostor = try await env.registry.preview(input: "https://evil.test/manifest.json")
        XCTAssertFalse(impostor.isOfficial)
        XCTAssertTrue(impostor.warnings.contains(.unknownAddon))
    }

    func testInstallingTheSameURLUpdatesInPlaceAndKeepsPreferences() async throws {
        let env = try TestEnvironment()
        let first = try await env.install(manifestFixture: "manifest_full.json", at: "https://addon.test/manifest.json")
        await env.registry.setEnabled(false, id: first.id)
        await env.registry.setCatalogVisible(false, catalogKey: "movie/top", id: first.id)
        await env.registry.setNameOverride("Il mio addon", id: first.id)

        let updated = """
        {"id":"org.aether.fixture.full","version":"9.9.9","name":"Fixture Full","types":["movie"],
         "resources":["catalog"],"catalogs":[{"type":"movie","id":"top","name":"Top"}]}
        """
        env.server.set("https://addon.test/manifest.json", json: updated)
        let second = try await env.registry.install(input: "https://addon.test/manifest.json")

        XCTAssertEqual(second.id, first.id, "same transport URL means the same record")
        XCTAssertEqual(second.manifest.version, "9.9.9")
        XCTAssertFalse(second.isEnabled, "the user's enable switch survives an update")
        XCTAssertEqual(second.hiddenCatalogs, ["movie/top"])
        XCTAssertEqual(second.displayName, "Il mio addon")
        let count = await env.registry.all().count
        XCTAssertEqual(count, 1, "no duplicate was created")
    }

    func testSecretURLIsKeptOutOfTheJSONFile() async throws {
        let env = try TestEnvironment()
        let secretURL = "https://addon.test/SUPER-SECRET-API-KEY/manifest.json"
        let addon = try await env.install(manifestFixture: "manifest_full.json", at: secretURL)
        let file = try String(contentsOf: env.directory.appendingPathComponent("addons.json"), encoding: .utf8)
        XCTAssertFalse(file.contains("SUPER-SECRET-API-KEY"), "the registry file must not contain the key")
        XCTAssertEqual(try env.secrets.get(addon.secretKey), secretURL)
        XCTAssertEqual(addon.host, "addon.test")
    }

    func testPersistsAcrossRelaunchAndFlagsMissingSecrets() async throws {
        let env = try TestEnvironment()
        let kept = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        let lost = try await env.install(manifestFixture: "manifest_minimal_short.json", at: "https://b.test/manifest.json")
        try env.secrets.remove(lost.secretKey)   // e.g. Keychain cleared

        let store = JSONFileStore<AddonRegistryState>(url: env.directory.appendingPathComponent("addons.json"))
        let reborn = AddonRegistry(store: store, secrets: env.secrets, client: env.client, policyProvider: { testPolicy() })
        let all = await reborn.all()
        XCTAssertEqual(all.map { $0.id }, [kept.id, lost.id])
        XCTAssertFalse(all[0].needsReinstall)
        XCTAssertTrue(all[1].needsReinstall)
        let handles = await reborn.handles()
        XCTAssertEqual(handles.map { $0.id }, [kept.id], "addons without their URL are not queried")
    }

    func testEnableDisableReorderUninstall() async throws {
        let env = try TestEnvironment()
        let a = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        let b = try await env.install(manifestFixture: "manifest_minimal_short.json", at: "https://b.test/manifest.json")
        let c = try await env.install(manifestFixture: "manifest_search_only.json", at: "https://c.test/manifest.json")

        await env.registry.move(from: IndexSet(integer: 2), to: 0)
        var order = await env.registry.all().map { $0.id }
        XCTAssertEqual(order, [c.id, a.id, b.id])

        await env.registry.move(from: IndexSet(integer: 0), to: 3)
        order = await env.registry.all().map { $0.id }
        XCTAssertEqual(order, [a.id, b.id, c.id])

        await env.registry.setEnabled(false, id: b.id)
        var handles = await env.registry.handles()
        XCTAssertEqual(handles.map { $0.id }, [a.id, c.id])
        handles = await env.registry.handles(includeDisabled: true)
        XCTAssertEqual(handles.count, 3)

        await env.registry.uninstall(id: a.id)
        let remaining = await env.registry.all().map { $0.id }
        XCTAssertEqual(remaining, [b.id, c.id])
        XCTAssertNil(try env.secrets.get(a.secretKey), "uninstall removes the stored URL")
    }

    func testRefreshKeepsPreferencesAndRecordsFailures() async throws {
        let env = try TestEnvironment()
        let addon = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        await env.registry.setEnabled(false, id: addon.id)

        let newer = """
        {"id":"org.aether.fixture.full","version":"2.0.0","name":"Fixture Full","types":["movie"],"resources":["catalog"],"catalogs":[{"type":"movie","id":"top"}]}
        """
        env.server.set("https://a.test/manifest.json", json: newer)
        let ok = await env.registry.refresh(id: addon.id)
        XCTAssertEqual(ok?.previousVersion, "1.2.0")
        XCTAssertEqual(ok?.newVersion, "2.0.0")
        XCTAssertEqual(ok?.versionChanged, true)
        var current = await env.registry.addon(id: addon.id)
        XCTAssertEqual(current?.manifest.version, "2.0.0")
        XCTAssertEqual(current?.isEnabled, false)

        env.server.set("https://a.test/manifest.json", status: 500)
        let failed = await env.registry.refresh(id: addon.id)
        XCTAssertNotNil(failed?.error)
        current = await env.registry.addon(id: addon.id)
        XCTAssertEqual(current?.manifest.version, "2.0.0", "a failed refresh keeps the previous manifest")
        XCTAssertNotNil(current?.lastError)
    }

    func testRestoreReplacesContentAndFlagsEntriesWithoutURL() async throws {
        let env = try TestEnvironment()
        _ = try await env.install(manifestFixture: "manifest_full.json", at: "https://a.test/manifest.json")
        let manifest = try ResponseDecoder.decodeManifest(Fixture.data("manifest_minimal_short.json"))
        let withURL = InstalledAddon(manifest: manifest, host: "b.test", fingerprint: "f1")
        let withoutURL = InstalledAddon(manifest: manifest, host: "c.test", fingerprint: "f2")
        await env.registry.restore(entries: [(addon: withURL, url: URL(string: "https://b.test/manifest.json")),
                                             (addon: withoutURL, url: nil)])
        let all = await env.registry.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertFalse(all[0].needsReinstall)
        XCTAssertTrue(all[1].needsReinstall)
        XCTAssertFalse(all[1].isEnabled)
    }
}
