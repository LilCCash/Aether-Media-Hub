import Foundation
import XCTest
@testable import AetherCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let url = Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures") else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        return String(decoding: try data(name), as: UTF8.self)
    }
}

/// Scripted HTTP responses keyed by absolute URL string. Unknown URLs answer 404.
final class FakeServer: HTTPClient, @unchecked Sendable {
    struct Route {
        var status: Int = 200
        var body: Data = Data()
        var delay: TimeInterval = 0
        var error: Error?
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var log: [HTTPRequest] = []

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    func requestCount(containing fragment: String) -> Int {
        return requests.filter { $0.url.absoluteString.contains(fragment) }.count
    }

    func set(_ url: String, status: Int = 200, body: Data = Data(), delay: TimeInterval = 0, error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        routes[url] = Route(status: status, body: body, delay: delay, error: error)
    }

    func set(_ url: String, fixture: String, status: Int = 200, delay: TimeInterval = 0) throws {
        set(url, status: status, body: try Fixture.data(fixture), delay: delay)
    }

    func set(_ url: String, json: String, status: Int = 200, delay: TimeInterval = 0) {
        set(url, status: status, body: Data(json.utf8), delay: delay)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll()
        log.removeAll()
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        log.append(request)
        let route = routes[request.url.absoluteString]
        lock.unlock()
        guard let route = route else {
            return HTTPResponse(data: Data("{\"err\":\"not found\"}".utf8), statusCode: 404, url: request.url)
        }
        if route.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(route.delay * 1_000_000_000))
        }
        try Task.checkCancellation()
        if let error = route.error { throw error }
        if route.body.count > request.maxBytes { throw AddonError.responseTooLarge(limit: request.maxBytes) }
        return HTTPResponse(data: route.body, statusCode: route.status, headers: route.headers, url: request.url)
    }
}

/// A policy usable in tests: no DNS, loopback and private ranges allowed only when asked.
func testPolicy(allowLocal: Bool = false) -> NetworkPolicy {
    return NetworkPolicy(allowLocalNetwork: allowLocal, allowLoopback: false,
                         requireHTTPSForPublicHosts: true, checkDNS: false)
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("aether-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a registry + service wired to a `FakeServer`.
struct TestEnvironment {
    let server: FakeServer
    let secrets: InMemorySecretStore
    let registry: AddonRegistry
    let client: AddonClient
    let service: AddonService
    let directory: URL

    init(requestTimeout: TimeInterval = 5) throws {
        server = FakeServer()
        secrets = InMemorySecretStore()
        directory = try makeTempDirectory()
        client = AddonClient(http: server, cache: nil)
        let store = JSONFileStore<AddonRegistryState>(url: directory.appendingPathComponent("addons.json"))
        registry = AddonRegistry(store: store, secrets: secrets, client: client, policyProvider: { testPolicy() })
        service = AddonService(registry: registry, client: client, maxConcurrentRequests: 4, requestTimeout: requestTimeout)
    }

    /// Registers `manifest` at `url` on the fake server and installs it.
    @discardableResult
    func install(manifestFixture: String, at url: String) async throws -> InstalledAddon {
        try server.set(url, fixture: manifestFixture)
        return try await registry.install(input: url)
    }
}
