import Foundation

/// What the «Continua a guardare» widget shows: written by the app into the App Group, read by the widget.
struct WidgetSnapshot: Codable, Equatable {
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

    var updated: Date
    var items: [Item]

    private static let fileName = "widget.json"

    static func read() -> WidgetSnapshot? {
        guard let url = AppGroup.containerURL?.appendingPathComponent(fileName), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot) {
        guard let url = AppGroup.containerURL?.appendingPathComponent(fileName), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func thumbnailURL(_ path: String?) -> URL? {
        guard let path = path else { return nil }
        return AppGroup.containerURL?.appendingPathComponent(path)
    }

    /// The address that opens the title in the app (handled by `AppRouter.handle(url:)`).
    static func deepLink(_ item: Item) -> URL? {
        var components = URLComponents()
        components.scheme = "aether"
        components.host = "detail"
        components.path = "/" + [item.type, item.metaID, item.videoID].map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return components.url
    }
}
