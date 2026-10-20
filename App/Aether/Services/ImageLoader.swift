import SwiftUI
import ImageIO
import AetherCore

/// Downloads, downsamples and caches artwork. Memory (decoded, cost-limited) + disk (raw bytes, size-capped),
/// request coalescing, policy-checked network access (addon artwork is untrusted too).
actor ImageLoader {
    private let http: HTTPClient
    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var diskLimitBytes: Int64
    private var writesSinceTrim = 0

    init(http: HTTPClient, directory: URL, diskLimitMB: Int) {
        self.http = http
        self.directory = directory
        self.diskLimitBytes = Int64(diskLimitMB) * 1_048_576
        memory.totalCostLimit = 120 * 1_048_576
        memory.countLimit = 600
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func setDiskLimit(megabytes: Int) {
        diskLimitBytes = Int64(megabytes) * 1_048_576
        trimDisk()
    }

    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let bucket = ImageLoader.bucket(maxPixel)
        let key = "\(url.absoluteString)|\(bucket)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return await running.value }
        let task = Task { [weak self] () -> UIImage? in
            guard let self = self else { return nil }
            return await self.loadUncached(url: url, bucket: bucket, key: key)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    /// Warms the cache for items about to scroll into view. Low priority, bounded by the caller.
    func prefetch(_ urls: [URL], maxPixel: Int) {
        for url in urls.prefix(8) {
            Task(priority: .utility) { [weak self] in
                _ = await self?.image(for: url, maxPixel: maxPixel)
            }
        }
    }

    func clearMemory() {
        memory.removeAllObjects()
    }

    func clearDisk() {
        memory.removeAllObjects()
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    func diskUsage() -> Int64 {
        return AppPaths.directorySize(directory)
    }

    // MARK: Private

    /// Round up to a few sizes so slightly different request sizes share the same decoded bitmap.
    private static func bucket(_ pixels: Int) -> Int {
        for step in [160, 320, 480, 720, 1080, 1600, 2400] where pixels <= step { return step }
        return 2400
    }

    private func fileURL(for url: URL) -> URL {
        return directory.appendingPathComponent(Hashing.sha256Hex(url.absoluteString)).appendingPathExtension("img")
    }

    private func loadUncached(url: URL, bucket: Int, key: String) async -> UIImage? {
        if Task.isCancelled { return nil }
        let file = fileURL(for: url)
        var data: Data?
        if let onDisk = try? Data(contentsOf: file) {
            data = onDisk
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            do {
                let response = try await http.send(HTTPRequest(url: url, headers: ["Accept": "image/*"], timeout: 15,
                                                               maxBytes: 8 * 1_048_576, purpose: .addonRequest))
                if response.isSuccess && !response.data.isEmpty {
                    data = response.data
                }
            } catch {
                return nil
            }
        }
        guard let bytes = data, let image = ImageLoader.downsample(bytes, maxPixel: bucket) else {
            // Corrupt cache entry: drop it so the next attempt refetches.
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            try? bytes.write(to: file, options: .atomic)
            writesSinceTrim += 1
            if writesSinceTrim >= 40 {
                writesSinceTrim = 0
                trimDisk()
            }
        }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func trimDisk() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > diskLimitBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            if total <= diskLimitBytes * 8 / 10 { break }
        }
    }
}

private struct ImageLoaderKey: EnvironmentKey {
    static let defaultValue: ImageLoader? = nil
}

extension EnvironmentValues {
    var imageLoader: ImageLoader? {
        get { self[ImageLoaderKey.self] }
        set { self[ImageLoaderKey.self] = newValue }
    }
}

/// Asynchronous artwork with a deterministic placeholder; cancels automatically when it leaves the screen.
///
/// The picture never takes part in layout: it fills whatever size the caller proposes and is clipped to it.
/// An `Image` laid out with `.fill` reports a size larger than the proposal on one axis (a 16:9 backdrop in a
/// narrow, tall slot is wider than the slot), and that excess used to propagate to the parent, widening the whole
/// detail screen and the Home carousel beyond the display so their sides were cut off.
struct RemoteImage: View {
    let urlString: String?
    var width: CGFloat = 160
    var contentMode: ContentMode = .fill
    var alignment: Alignment = .center
    var placeholderSeed: String = ""
    var systemPlaceholder: String = "film"

    @Environment(\.imageLoader) private var loader
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var settings: SettingsStore
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Color.clear
            .overlay(alignment: alignment) { artwork }
            .clipped()
            .animation(settings.animationsEnabled ? .easeOut(duration: 0.25) : nil, value: image != nil)
            .task(id: urlString) { await load() }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
                .transition(settings.animationsEnabled ? .opacity : .identity)
        } else {
            ZStack {
                Theme.fallbackGradient(for: placeholderSeed.isEmpty ? (urlString ?? "aether") : placeholderSeed)
                Image(systemName: failed ? "photo" : systemPlaceholder)
                    .font(.system(size: max(14, width * 0.18), weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func load() async {
        image = nil
        failed = false
        guard let string = urlString, let url = URL.lenient(string), let loader = loader else {
            failed = urlString != nil
            return
        }
        let pixels = Int(width * displayScale)
        let loaded = await loader.image(for: url, maxPixel: pixels)
        if Task.isCancelled { return }
        if let loaded = loaded { image = loaded } else { failed = true }
    }
}
