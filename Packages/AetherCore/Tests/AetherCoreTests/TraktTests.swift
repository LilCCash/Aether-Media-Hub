import XCTest
@testable import AetherCore

private final class FakeTraktHTTP: HTTPClient, @unchecked Sendable {
    var responses: [String: (Int, String)] = [:]
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let path = request.url.path
        let answer = responses[path] ?? (404, "")
        return HTTPResponse(data: Data(answer.1.utf8), statusCode: answer.0, headers: [:], url: request.url)
    }
}

final class TraktTests: XCTestCase {
    private func makeClient(_ http: FakeTraktHTTP, session: TraktSession? = nil) -> (TraktClient, SavedSession) {
        let saved = SavedSession(session)
        let store = TraktClient.SessionStore(load: { saved.value }, save: { saved.value = $0 })
        return (TraktClient(http: http, store: store), saved)
    }

    private final class SavedSession: @unchecked Sendable {
        var value: TraktSession?
        init(_ value: TraktSession?) { self.value = value }
    }

    func testDeviceLoginFlow() async throws {
        let http = FakeTraktHTTP()
        http.responses["/oauth/device/code"] = (200, "{\"device_code\":\"d\",\"user_code\":\"ABCD1234\",\"verification_url\":\"https://auth.trakt.tv/activate\",\"expires_in\":600,\"interval\":5}")
        let (client, saved) = makeClient(http)
        let code = try await client.startDeviceLogin()
        XCTAssertEqual(code.userCode, "ABCD1234")
        XCTAssertEqual(code.interval, 5)

        http.responses["/oauth/device/token"] = (400, "")
        do {
            try await client.pollDeviceLogin(code)
            XCTFail("doveva essere in attesa")
        } catch let error as TraktError {
            XCTAssertEqual(error, .pending)
        }
        XCTAssertNil(saved.value)

        http.responses["/oauth/device/token"] = (200, "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":604800,\"created_at\":1700000000}")
        try await client.pollDeviceLogin(code)
        XCTAssertEqual(saved.value?.accessToken, "a")
        XCTAssertEqual(saved.value?.refreshToken, "r")
        let connected = await client.isConnected
        XCTAssertTrue(connected)
        // Nessun segreto del client viene inviato.
        let body = String(decoding: http.requests.last?.body ?? Data(), as: UTF8.self)
        XCTAssertFalse(body.contains("client_secret"))
        XCTAssertEqual(http.requests.last?.headers["trakt-api-key"], TraktClient.clientID)
    }

    func testExpiredSessionIsRefreshedAndNewTokenSaved() async throws {
        let http = FakeTraktHTTP()
        http.responses["/oauth/token"] = (200, "{\"access_token\":\"new\",\"refresh_token\":\"newr\",\"expires_in\":604800,\"created_at\":\(Int(Date().timeIntervalSince1970))}")
        http.responses["/users/settings"] = (200, "{\"user\":{\"username\":\"mario\",\"vip\":false},\"limits\":{\"watchlist\":{\"item_count\":100},\"list\":{\"count\":2}}}")
        let old = TraktSession(accessToken: "old", refreshToken: "oldr", createdAt: Date(timeIntervalSinceNow: -8 * 86_400), expiresIn: 604_800)
        let (client, saved) = makeClient(http, session: old)
        let user = try await client.user()
        XCTAssertEqual(user.username, "mario")
        XCTAssertEqual(user.watchlistLimit, 100)
        XCTAssertEqual(saved.value?.refreshToken, "newr")
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new")
    }

    func testNotConnectedBlocksAuthorizedCalls() async {
        let (client, _) = makeClient(FakeTraktHTTP())
        do {
            _ = try await client.user()
            XCTFail("serve il collegamento")
        } catch let error as TraktError {
            XCTAssertEqual(error, .notConnected)
        } catch {
            XCTFail("errore inatteso")
        }
    }

    func testParsers() {
        let trending = try! JSONSerialization.jsonObject(with: Data("[{\"watchers\":12,\"movie\":{\"title\":\"Heat\",\"year\":1995,\"ids\":{\"imdb\":\"tt0113277\",\"tmdb\":949}}}]".utf8))
        let items = TraktClient.parseWrapped(trending, key: "movie", kind: .movie, note: TraktClient.noteWatchers)
        XCTAssertEqual(items.first?.imdb, "tt0113277")
        XCTAssertEqual(items.first?.note, "12 spettatori ora")

        let playback = try! JSONSerialization.jsonObject(with: Data("[{\"progress\":42.5,\"type\":\"episode\",\"episode\":{\"season\":2,\"number\":3,\"title\":\"X\"},\"show\":{\"title\":\"Lost\",\"year\":2004,\"ids\":{\"imdb\":\"tt0411008\"}}}]".utf8))
        let resume = TraktClient.parsePlayback(playback)
        XCTAssertEqual(resume.first?.season, 2)
        XCTAssertEqual(resume.first?.note, "S2E3 · 42%")

        let calendar = try! JSONSerialization.jsonObject(with: Data("[{\"first_aired\":\"2026-11-05T01:00:00.000Z\",\"episode\":{\"season\":1,\"number\":4},\"show\":{\"title\":\"Show\",\"ids\":{\"imdb\":\"tt1\"}}}]".utf8))
        XCTAssertEqual(TraktClient.parseCalendar(calendar).first?.note, "S1E4 · 2026-11-05")
    }

    func testSessionRefreshWindowAndSettings() {
        let fresh = TraktSession(accessToken: "a", refreshToken: "r", createdAt: Date(), expiresIn: 604_800)
        XCTAssertFalse(fresh.needsRefresh())
        let old = TraktSession(accessToken: "a", refreshToken: "r", createdAt: Date(timeIntervalSinceNow: -6.5 * 86_400), expiresIn: 604_800)
        XCTAssertTrue(old.needsRefresh())

        var settings = TraktSettings()
        XCTAssertFalse(settings.enabled)
        XCTAssertTrue(settings.isCatalogVisible(.trendingMovies))
        settings.setCatalog(.trendingMovies, visible: false)
        XCTAssertFalse(settings.isCatalogVisible(.trendingMovies))
        settings.setCatalog(.trendingMovies, visible: true)
        XCTAssertTrue(settings.isCatalogVisible(.trendingMovies))
        XCTAssertTrue(TraktCatalogKind.watchlist.needsLogin)
        XCTAssertFalse(TraktCatalogKind.trendingShows.needsLogin)
    }
}
