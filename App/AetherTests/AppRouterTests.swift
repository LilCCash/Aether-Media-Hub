import XCTest
import AetherCore
@testable import Aether

@MainActor
final class AppRouterTests: XCTestCase {
    func testStremioInstallLinkOpensAddonsWithHTTPSURL() {
        let router = AppRouter()
        router.handle(url: URL(string: "stremio://addon.example.com/abc/manifest.json")!)
        XCTAssertEqual(router.pendingAddonInput, "https://addon.example.com/abc/manifest.json")
        XCTAssertEqual(router.tab, .more)
    }

    func testAetherInstallLink() {
        let router = AppRouter()
        let target = "https://addon.example.com/manifest.json"
        let encoded = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? target
        router.handle(url: URL(string: "aether://install?url=\(encoded)")!)
        XCTAssertEqual(router.pendingAddonInput, target)
    }

    func testDetailLinkWithEmptyHost() {
        let router = AppRouter()
        router.handle(url: URL(string: "stremio:///detail/movie/tt0111161")!)
        XCTAssertEqual(router.detail?.type, "movie")
        XCTAssertEqual(router.detail?.id, "tt0111161")
        XCTAssertNil(router.pendingAddonInput)
    }

    func testDetailLinkWithEpisode() {
        let router = AppRouter()
        router.handle(url: URL(string: "stremio:///detail/series/tt0944947/tt0944947:1:2")!)
        XCTAssertEqual(router.detail?.id, "tt0944947")
        XCTAssertEqual(router.detail?.videoID, "tt0944947:1:2")
    }

    func testSearchLink() {
        let router = AppRouter()
        router.handle(url: URL(string: "stremio:///search?search=matrix")!)
        XCTAssertEqual(router.pendingSearch, "matrix")
        XCTAssertEqual(router.tab, .search)
    }

    func testUnknownSchemeIsIgnored() {
        let router = AppRouter()
        router.handle(url: URL(string: "https://example.com/manifest.json")!)
        XCTAssertNil(router.pendingAddonInput)
        XCTAssertNil(router.detail)
        XCTAssertEqual(router.tab, .home)
    }

    func testJavascriptInstallLinkIsRejected() {
        let router = AppRouter()
        let link = URL(string: "aether://install?url=javascript:alert(1)")!
        router.handle(url: link)
        XCTAssertNil(router.pendingAddonInput)
    }
}
