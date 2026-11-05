import UIKit
import WidgetKit
import AetherCore

/// Writes what the widgets show into the App Group: the titles to resume, the library titles the featured widget can open (poster, logo and
/// the colours of the poster) and the viewing statistics. If the signature gave the app no shared container there is nowhere to write
/// and nothing happens.
@MainActor
final class WidgetBridge {
    private var last: WidgetSnapshot?

    func refresh(history: [PlaybackProgress], library: [LibraryEntry], enabled: Bool, env: AppEnvironment) {
        Task { await write(history: history, library: library, enabled: enabled, env: env) }
    }

    private func name(_ id: String) -> String { return id.filter { $0.isLetter || $0.isNumber } }

    private func ensure(_ folder: URL, file: String, make: () async -> Data?) async -> String? {
        let target = folder.appendingPathComponent(file)
        if !FileManager.default.fileExists(atPath: target.path), let data = await make() { try? data.write(to: target) }
        return FileManager.default.fileExists(atPath: target.path) ? folder.lastPathComponent + "/" + file : nil
    }

    private func hex(_ color: PosterColor) -> String {
        func byte(_ value: Double) -> Int { return min(255, max(0, Int((value * 255).rounded()))) }
        return String(format: "%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    private func write(history: [PlaybackProgress], library: [LibraryEntry], enabled: Bool, env: AppEnvironment) async {
        guard let directory = AppGroup.containerURL else { return }
        let fm = FileManager.default
        func folder(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let thumbs = folder("thumbs"), posters = folder("posters"), logos = folder("logos")
        let images = env.images
        var keepThumbs = Set<String>(), keepPosters = Set<String>(), keepLogos = Set<String>()

        // Titles to resume.
        var items: [WidgetSnapshot.Item] = []
        for entry in enabled ? ContinueWatchingPlanner.items(from: history) : [] {
            var file: String?
            if let poster = entry.poster, let url = URL(string: poster) {
                let key = name(entry.metaID) + ".jpg"
                file = await ensure(thumbs, file: key) { await images.image(for: url, maxPixel: 240)?.jpegData(compressionQuality: 0.8) }
                if file != nil { keepThumbs.insert(key) }
            }
            items.append(WidgetSnapshot.Item(metaID: entry.metaID, type: entry.type, videoID: entry.videoID, title: entry.title,
                                             subtitle: entry.subtitle, progress: entry.progress, thumbnail: file))
        }

        // The library, for the featured widget: favourites first, then the list, then what is being watched.
        var pool: [WidgetSnapshot.Title] = []
        if enabled {
            var seen = Set<String>()
            var candidates: [(id: String, type: String, name: String, poster: String?, info: String?)] = []
            for entry in library where seen.insert(entry.id).inserted { candidates.append((entry.id, entry.type, entry.name, entry.poster, entry.releaseInfo)) }
            for row in history where seen.insert(row.metaID).inserted { candidates.append((row.metaID, row.type, row.title, row.poster, nil)) }
            for (index, candidate) in candidates.prefix(24).enumerated() {
                var posterFile: String?
                var accentHex: String?, backdropHex: String?
                if let poster = candidate.poster, let url = URL(string: poster) {
                    let key = name(candidate.id) + ".jpg"
                    posterFile = await ensure(posters, file: key) { await images.image(for: url, maxPixel: 320)?.jpegData(compressionQuality: 0.85) }
                    if posterFile != nil { keepPosters.insert(key) }
                    if let palette = await PosterTint.palette(for: poster, loader: images) {
                        accentHex = hex(palette.accent)
                        backdropHex = hex(palette.backdrop)
                    }
                }
                var logoFile: String?
                if index < 12 {
                    let key = name(candidate.id) + ".png"
                    let meta = MetaItem(id: candidate.id, type: candidate.type, name: candidate.name, poster: candidate.poster)
                    logoFile = await ensure(logos, file: key) { await FanartLogoStore.shared.load(meta: meta, env: env).flatMap { WidgetBridge.scaled($0, width: 400).pngData() } }
                    if logoFile != nil { keepLogos.insert(key) }
                }
                pool.append(WidgetSnapshot.Title(id: candidate.id, type: candidate.type, name: candidate.name, info: candidate.info,
                                                 poster: posterFile, logo: logoFile, backdropHex: backdropHex, accentHex: accentHex))
            }
        }

        // Statistics.
        var stats: WidgetSnapshot.Stats?
        if enabled {
            let value = ViewingStatsPlanner.compute(history, now: Date())
            stats = WidgetSnapshot.Stats(totalSeconds: value.totalSeconds, weekSeconds: value.weekSeconds, days: value.days, titles: value.titles,
                                         completed: value.completed, films: value.films, episodes: value.episodes, streak: value.streak)
        }

        for (dir, keep) in [(thumbs, keepThumbs), (posters, keepPosters), (logos, keepLogos)] {
            if let existing = try? fm.contentsOfDirectory(atPath: dir.path) {
                for file in existing where !keep.contains(file) { try? fm.removeItem(at: dir.appendingPathComponent(file)) }
            }
        }
        let snapshot = WidgetSnapshot(updated: Date(), items: items, pool: pool, stats: stats)
        if let previous = last, previous.items == snapshot.items, previous.pool == snapshot.pool, previous.stats == snapshot.stats { return }
        last = snapshot
        WidgetSnapshot.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func scaled(_ image: UIImage, width: CGFloat) -> UIImage {
        guard image.size.width > width else { return image }
        let size = CGSize(width: width, height: image.size.height * width / image.size.width)
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
