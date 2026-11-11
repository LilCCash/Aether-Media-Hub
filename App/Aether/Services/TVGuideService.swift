import Foundation
import Compression
import AetherCore

/// The TV guide under the channels of the M3U playlists: downloads the XMLTV file (the viewer's address, else the one a playlist
/// announces, else the public Italian guide), keeps the next day and a half on disk and refreshes it every 12 hours.
@MainActor
final class TVGuideService: ObservableObject {
    @Published private(set) var guide = TVGuide()
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var source: String?

    private var matcher: TVGuideMatcher?
    private var matches: [String: String?] = [:]
    private let file: URL
    private static let maxBytes = 80 * 1024 * 1024
    private static let refreshAfter: TimeInterval = 12 * 3600

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("LiveTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("guide.json")
        if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            apply(stored.guide, source: stored.source)
        }
    }

    private struct Stored: Codable {
        var guide: TVGuide
        var source: String
    }

    /// The guide channel of a playlist channel (nil when the guide does not know it).
    func channelID(for channel: M3UChannel) -> String? {
        if let known = matches[channel.id] { return known }
        let found = matcher?.channelID(tvgID: channel.tvgID, name: channel.name)
        matches[channel.id] = found
        return found
    }

    func now(for channel: M3UChannel, at date: Date = Date()) -> TVProgramme? {
        guard let id = channelID(for: channel) else { return nil }
        return guide.now(id, at: date)
    }

    func upcoming(for channel: M3UChannel, count: Int) -> [TVProgramme] {
        guard let id = channelID(for: channel) else { return [] }
        return guide.upcoming(id, count: count)
    }

    /// Downloads the guide when there is none, when the address changed, or when it is older than 12 hours (or `force`).
    func refresh(settings: LiveTVSettings, announced: [String], force: Bool = false) async {
        guard let address = settings.guideAddress(announced: announced) else {
            message = nil
            return
        }
        let fresh = Date().timeIntervalSince(guide.fetchedAt) < Self.refreshAfter
        if !force, source == address, !guide.isEmpty, fresh { return }
        guard !isLoading else { return }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            message = "L'indirizzo della guida non è valido (serve https)."
            return
        }
        isLoading = true
        message = nil
        defer { isLoading = false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Aether", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                message = "Il server della guida ha risposto con un errore (\(http.statusCode))."
                return
            }
            guard data.count <= Self.maxBytes else {
                message = "La guida è troppo grande."
                return
            }
            let parsed: TVGuide? = await Task.detached(priority: .utility) {
                guard let xml = Self.inflateIfNeeded(data) else { return nil }
                return XMLTVParser.parse(xml)
            }.value
            guard let parsed = parsed, !parsed.isEmpty else {
                message = "Non ho trovato programmi in questa guida (serve un file XMLTV, anche .gz)."
                return
            }
            apply(parsed, source: address)
            if let encoded = try? JSONEncoder().encode(Stored(guide: parsed, source: address)) { try? encoded.write(to: file, options: .atomic) }
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            message = "iOS blocca gli indirizzi non cifrati (http): usa un indirizzo https."
        } catch {
            message = "Download della guida non riuscito: \(error.localizedDescription)"
        }
    }

    func clear() {
        guide = TVGuide()
        matcher = nil
        matches = [:]
        source = nil
        try? FileManager.default.removeItem(at: file)
    }

    private func apply(_ guide: TVGuide, source: String) {
        self.guide = guide
        self.source = source
        matcher = TVGuideMatcher(guide)
        matches = [:]
    }

    /// A `.xml.gz` guide is inflated here (the system decompressor reads raw deflate: the gzip wrapper is taken off first).
    nonisolated static func inflateIfNeeded(_ data: Data) -> Data? {
        guard GzipContainer.isGzip(data) else { return data }
        guard let payload = GzipContainer.deflatePayload(data) else { return nil }
        let expected = GzipContainer.originalSize(data) ?? payload.count * 8
        // The size in the trailer is modulo 4 GB and may be wrong for odd files: grow the buffer when it is too small.
        var capacity = max(expected + 1024, payload.count * 4)
        for _ in 0..<4 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
                payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                    guard let dst = out.bindMemory(to: UInt8.self).baseAddress,
                          let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dst, capacity, src, payload.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity {
                output.count = written
                return output
            }
            capacity *= 2
            if capacity > 320 * 1024 * 1024 { break }
        }
        return nil
    }
}
