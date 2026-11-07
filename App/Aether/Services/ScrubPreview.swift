import AVFoundation
import UIKit

/// The little pictures shown above the progress bar while the viewer slides along the film («as on Netflix»). They are cut from the original
/// source with FFmpeg (`FFmpegThumbnailer`), so every format and both players are covered: MKV, AVI, TS, WebM, HLS and MP4, with AVPlayer or MPV.
/// AVFoundation steps in only when FFmpeg cannot make a picture (and the player is AVPlayer).
@MainActor
final class ScrubPreviewProvider: ObservableObject {
    @Published private(set) var image: UIImage?

    private var thumbnailer: FFmpegThumbnailer?
    private var fallbackGenerator: AVAssetImageGenerator?
    private var key = ""
    private var task: Task<Void, Never>?
    private var cache: [Int: UIImage] = [:]

    /// A picture can be asked only for an address that FFmpeg or AVFoundation can open.
    static func isSupported(url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    func request(at seconds: Double, url: URL?, headers: [String: String], usesAVPlayer: Bool) {
        guard let url = url, Self.isSupported(url: url) else { image = nil; return }
        let newKey = url.absoluteString
        if newKey != key {
            key = newKey
            cache = [:]
            thumbnailer?.close()
            thumbnailer = FFmpegThumbnailer.isAvailable ? FFmpegThumbnailer(url: url, headers: headers) : nil
            fallbackGenerator = nil
        }
        let bucket = Int(seconds / 5)
        if let hit = cache[bucket] { image = hit; return }
        task?.cancel()
        task = Task { [weak self] in
            // Waits a moment: while the finger moves, only the last position is worth asking for.
            try? await Task.sleep(nanoseconds: 90_000_000)
            if Task.isCancelled { return }
            guard let self = self else { return }
            var made: UIImage?
            if let thumbnailer = self.thumbnailer { made = await thumbnailer.image(at: seconds) }
            if made == nil, usesAVPlayer { made = await self.fallbackImage(at: seconds, url: url, headers: headers) }
            if Task.isCancelled { return }
            guard let picture = made else { return }
            if self.cache.count > 240 { self.cache.removeAll() }
            self.cache[bucket] = picture
            self.image = picture
        }
    }

    private func fallbackImage(at seconds: Double, url: URL, headers: [String: String]) async -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mkv", "avi", "ts", "webm"].contains(ext) { return nil }
        if fallbackGenerator == nil {
            var options: [String: Any] = [:]
            if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: url, options: options))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 360, height: 220)
            made.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
            made.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)
            fallbackGenerator = made
        }
        guard let generator = fallbackGenerator,
              let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image)
    }

    func clear() {
        task?.cancel()
        image = nil
    }
}
