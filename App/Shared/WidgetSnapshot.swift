import Foundation

/// What the widgets show: written by the app into the App Group, read by the widget extension.
struct WidgetSnapshot: Codable, Equatable {
    /// A title to resume («Continua a guardare»).
    struct Item: Codable, Equatable, Identifiable {
        var id: String { return metaID }
        var metaID: String
        var type: String
        var videoID: String
        var title: String
        var subtitle: String?
        var progress: Double
        /// Path of the poster (a small JPEG) inside the container.
        var thumbnail: String?
    }

    /// A title of the viewer's library the featured widget can open, with the look taken from its poster.
    struct Title: Codable, Equatable, Identifiable {
        var id: String
        var type: String
        var name: String
        var info: String?
        var poster: String?
        var logo: String?
        var backdropHex: String?
        var accentHex: String?
    }

    struct Stats: Codable, Equatable {
        var totalSeconds: Double
        var weekSeconds: Double
        var days: [Double]
        var titles: Int
        var completed: Int
        var films: Int
        var episodes: Int
        var streak: Int
    }

    var updated: Date
    var items: [Item]
    var pool: [Title]? = nil
    var stats: Stats? = nil

    private static let fileName = "widget.json"

    static func read() -> WidgetSnapshot? {
        guard let url = AppGroup.containerURL?.appendingPathComponent(fileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = AppGroup.containerURL?.appendingPathComponent(fileName), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func fileURL(_ path: String?) -> URL? {
        guard let path = path else { return nil }
        return AppGroup.containerURL?.appendingPathComponent(path)
    }

    static func thumbnailURL(_ path: String?) -> URL? { return fileURL(path) }

    /// The address that opens a title in the app (handled by `AppRouter.handle(url:)`).
    static func deepLink(type: String, id: String, videoID: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "aether"
        components.host = "detail"
        let parts = [type, id] + (videoID.map { [$0] } ?? [])
        components.path = "/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return components.url
    }

    static func deepLink(_ item: Item) -> URL? { return deepLink(type: item.type, id: item.metaID, videoID: item.videoID) }
}
