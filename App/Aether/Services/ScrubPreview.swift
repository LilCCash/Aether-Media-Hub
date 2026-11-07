import AVFoundation
import UIKit

/// The little pictures shown above the progress bar while the viewer slides along the film («as on Netflix»). They are cut from the very
/// file being played with AVFoundation, so they exist only where AVFoundation can read it: a direct MP4/MOV/M4V link or a downloaded file with
/// AVPlayer. For HLS streams, converted files and anything played by MPV (MKV and the like) there is no picture, only the time.
@MainActor
final class ScrubPreviewProvider: ObservableObject {
    @Published private(set) var image: UIImage?

    private var generator: AVAssetImageGenerator?
    private var key = ""
    private var task: Task<Void, Never>?
    private var cache: [Int: UIImage] = [:]

    /// Whether pictures can be made for this source.
    static func isSupported(url: URL?, usesAVPlayer: Bool) -> Bool {
        guard usesAVPlayer, let url = url else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "m3u8" || ext == "mkv" || ext == "avi" || ext == "ts" || ext == "webm" { return false }
        if url.host == "127.0.0.1" || url.host == "localhost" { return false }   // the local conversion: a stream of pieces
        return true
    }

    func request(at seconds: Double, url: URL?, headers: [String: String], usesAVPlayer: Bool) {
        guard Self.isSupported(url: url, usesAVPlayer: usesAVPlayer), let url = url else { image = nil; return }
        let newKey = url.absoluteString
        if newKey != key {
            key = newKey
            cache = [:]
            var options: [String: Any] = [:]
            if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: url, options: options))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 360, height: 220)
            // Any nearby picture will do, and it comes much faster: no need to decode up to the exact frame.
            made.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
            made.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)
            generator = made
        }
        let bucket = Int(seconds / 5)
        if let hit = cache[bucket] { image = hit; return }
        guard let generator = generator else { return }
        task?.cancel()
        task = Task { [weak self] in
            // Waits a moment: while the finger moves, only the last position is worth asking for.
            try? await Task.sleep(nanoseconds: 90_000_000)
            if Task.isCancelled { return }
            guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else { return }
            if Task.isCancelled { return }
            let picture = UIImage(cgImage: result.image)
            self?.cache[bucket] = picture
            self?.image = picture
        }
    }

    func clear() {
        task?.cancel()
        image = nil
    }
}
