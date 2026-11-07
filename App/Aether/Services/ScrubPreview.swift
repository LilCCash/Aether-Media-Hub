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
    private var reported = false
    /// Where the reason goes when no picture can be made (the diagnostic log).
    var log: ((String) -> Void)?

    /// A picture can be asked only for an address that FFmpeg or AVFoundation can open.
    static func isSupported(url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return ["http", "https", "file"].contains(scheme)
    }

    /// Opens the source in the background right when the film starts, so the first slide already finds it open.
    func prepare(url: URL?, headers: [String: String]) {
        guard let url = url, Self.isSupported(url: url), FFmpegThumbnailer.isAvailable else { return }
        if url.absoluteString != key {
            key = url.absoluteString
            cache = [:]
            reported = false
            thumbnailer?.close()
            thumbnailer = FFmpegThumbnailer(url: url, headers: headers)
            fallbackGenerator = nil
        }
        thumbnailer?.warmUp()
    }

    func request(at seconds: Double, url: URL?, headers: [String: String], usesAVPlayer: Bool) {
        guard let url = url, Self.isSupported(url: url) else { image = nil; return }
        let newKey = url.absoluteString
        if newKey != key {
            key = newKey
            cache = [:]
            reported = false
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
            guard let picture = made else {
                // No picture for this spot: the nearest one already made is better than an empty frame, and the reason goes to the log once.
                if let nearest = self.cache.min(by: { abs($0.key - bucket) < abs($1.key - bucket) })?.value { self.image = nearest }
                if !self.reported {
                    self.reported = true
                    self.log?("Anteprime: nessuna immagine (\(self.thumbnailer?.lastFailure ?? "motore non disponibile"))")
                }
                return
            }
            if self.cache.count > 240 { self.cache.removeAll() }
            self.cache[bucket] = picture
            self.image = picture
        }
    }

    private func fallbackImage(at seconds: Double, url: URL, headers: [String: String]) async -> UIImage? {
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mkv", "avi", "webm"].contains(ext) { return nil }
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
