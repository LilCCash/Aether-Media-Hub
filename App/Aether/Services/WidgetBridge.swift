import UIKit
import WidgetKit
import AetherCore

/// Writes the list of titles to resume into the App Group (with a small poster of each), where the widget reads it. If the signature gave the
/// app no shared container there is nowhere to write and nothing happens.
@MainActor
final class WidgetBridge {
    private var lastItems: [WidgetSnapshot.Item]?

    func refresh(history: [PlaybackProgress], enabled: Bool, images: ImageLoader) {
        Task { await write(history: history, enabled: enabled, images: images) }
    }

    private func write(history: [PlaybackProgress], enabled: Bool, images: ImageLoader) async {
        guard let directory = AppGroup.containerURL else { return }
        let thumbnails = directory.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        var items: [WidgetSnapshot.Item] = []
        var keep = Set<String>()
        for entry in enabled ? ContinueWatchingPlanner.items(from: history) : [] {
            var file: String?
            if let poster = entry.poster, let url = URL(string: poster) {
                let name = entry.metaID.filter { $0.isLetter || $0.isNumber } + ".jpg"
                let target = thumbnails.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: target.path), let image = await images.image(for: url, maxPixel: 240),
                   let data = image.jpegData(compressionQuality: 0.8) {
                    try? data.write(to: target)
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    file = "thumbs/" + name
                    keep.insert(name)
                }
            }
            items.append(WidgetSnapshot.Item(metaID: entry.metaID, type: entry.type, videoID: entry.videoID, title: entry.title,
                                             subtitle: entry.subtitle, progress: entry.progress, thumbnail: file))
        }
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path) {
            for name in existing where !keep.contains(name) { try? FileManager.default.removeItem(at: thumbnails.appendingPathComponent(name)) }
        }
        guard items != lastItems else { return }
        lastItems = items
        WidgetSnapshot.write(WidgetSnapshot(updated: Date(), items: items))
        WidgetCenter.shared.reloadAllTimelines()
    }
}
