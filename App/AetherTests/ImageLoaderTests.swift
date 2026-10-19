import XCTest
import UIKit
import AetherCore
@testable import Aether

/// Counts requests and serves canned bytes; stands in for the network.
final class CountingHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var payload: Data
    var delay: UInt64 = 0
    init(payload: Data) { self.payload = payload }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock(); count += 1; lock.unlock()
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return HTTPResponse(data: payload, statusCode: 200, headers: [:], url: request.url)
    }
}

/// Scenario 19: caches and memory behaviour of artwork loading.
final class ImageLoaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-image-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// Incompressible RGBA noise so the PNG has a predictable, large size.
    private func noisePNG(width: Int, height: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image).pngData()!
    }

    func testConcurrentRequestsForTheSameImageHitTheNetworkOnce() async {
        let http = CountingHTTPClient(payload: noisePNG(width: 64, height: 96))
        http.delay = 150_000_000
        let loader = ImageLoader(http: http, directory: directory, diskLimitMB: 50)
        let url = URL(string: "https://img.example/poster.png")!
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 { group.addTask { await loader.image(for: url, maxPixel: 160) != nil } }
            var loaded = 0
            for await ok in group where ok { loaded += 1 }
            XCTAssertEqual(loaded, 12)
        }
        XCTAssertEqual(http.requestCount, 1)
    }

    func testSecondLoaderReadsFromDiskWithoutTheNetwork() async {
        let png = noisePNG(width: 64, height: 96)
        let url = URL(string: "https://img.example/a.png")!
        let first = CountingHTTPClient(payload: png)
        let firstLoader = ImageLoader(http: first, directory: directory, diskLimitMB: 50)
        let image = await firstLoader.image(for: url, maxPixel: 160)
        XCTAssertNotNil(image)
        XCTAssertEqual(first.requestCount, 1)

        let second = CountingHTTPClient(payload: Data())
        let secondLoader = ImageLoader(http: second, directory: directory, diskLimitMB: 50)
        let again = await secondLoader.image(for: url, maxPixel: 160)
        XCTAssertNotNil(again, "should be decoded from the disk cache")
        XCTAssertEqual(second.requestCount, 0)
    }

    func testImagesAreDownsampledToTheRequestedSize() async throws {
        let http = CountingHTTPClient(payload: noisePNG(width: 800, height: 1200))
        let loader = ImageLoader(http: http, directory: directory, diskLimitMB: 50)
        let image = await loader.image(for: URL(string: "https://img.example/big.png")!, maxPixel: 160)
        let result = try XCTUnwrap(image)
        let longest = max(result.size.width * result.scale, result.size.height * result.scale)
        XCTAssertLessThanOrEqual(longest, 160.5, "decoded bitmaps must not keep the full resolution in memory")
    }

    func testCorruptDataIsNotCached() async {
        let http = CountingHTTPClient(payload: Data("not an image".utf8))
        let loader = ImageLoader(http: http, directory: directory, diskLimitMB: 50)
        let image = await loader.image(for: URL(string: "https://img.example/broken.png")!, maxPixel: 160)
        XCTAssertNil(image)
        let usage = await loader.diskUsage()
        XCTAssertEqual(usage, 0)
    }

    func testDiskCacheIsTrimmedToItsLimitOldestFirst() async throws {
        let http = CountingHTTPClient(payload: noisePNG(width: 400, height: 400))   // ~640 KB each
        let loader = ImageLoader(http: http, directory: directory, diskLimitMB: 50)
        for index in 0..<4 {
            _ = await loader.image(for: URL(string: "https://img.example/\(index).png")!, maxPixel: 160)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let before = await loader.diskUsage()
        XCTAssertGreaterThan(before, 2 * 1_048_576)
        await loader.setDiskLimit(megabytes: 1)
        let after = await loader.diskUsage()
        XCTAssertLessThanOrEqual(after, 1_048_576)
        XCTAssertGreaterThan(after, 0, "the newest entry should survive")
    }

    func testClearDiskRemovesEverything() async {
        let http = CountingHTTPClient(payload: noisePNG(width: 64, height: 64))
        let loader = ImageLoader(http: http, directory: directory, diskLimitMB: 50)
        _ = await loader.image(for: URL(string: "https://img.example/x.png")!, maxPixel: 160)
        await loader.clearDisk()
        let usage = await loader.diskUsage()
        XCTAssertEqual(usage, 0)
    }
}
