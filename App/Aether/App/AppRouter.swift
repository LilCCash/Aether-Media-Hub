import SwiftUI
import AetherCore

enum AppTab: String, Hashable {
    case home, discover, library, search, more
}

/// Navigation target for a title detail screen.
struct MetaRoute: Hashable, Identifiable {
    var type: String
    var id: String
    /// Preview data from the catalog the user tapped (poster, name, …) shown instantly while details load.
    var preview: MetaItem?
    /// Optional episode to focus.
    var videoID: String?

    init(type: String, id: String, preview: MetaItem? = nil, videoID: String? = nil) {
        self.type = type
        self.id = id
        self.preview = preview
        self.videoID = videoID
    }

    init(meta: MetaItem) {
        self.init(type: meta.type, id: meta.id, preview: meta)
    }
}

/// What the full-screen player is asked to play.
struct PlayerRequest: Identifiable {
    enum Source {
        case stream(AddonStream)
        case download(DownloadItem)
    }

    let id = UUID()
    var meta: MetaItem
    var video: Video?
    var source: Source
    /// Other sources the user may switch to if this one fails.
    var alternatives: [RankedStream]
}

/// Single place for cross-screen navigation: tab selection, deep links, the player, addon-install prompts.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var player: PlayerRequest?
    @Published var detail: MetaRoute?
    @Published var pendingAddonInput: String?
    @Published var pendingSearch: String?
    @Published var showCasting = false

    func openDetail(_ meta: MetaItem) {
        detail = MetaRoute(meta: meta)
    }

    func play(_ request: PlayerRequest) {
        player = request
    }

    /// Handles `aether://…` and `stremio://…` links.
    func handle(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if let installURL = AddonURL.installURL(fromDeepLink: url) {
            pendingAddonInput = installURL.absoluteString
            tab = .more
            return
        }
        if scheme == "stremio" || scheme == "aether" {
            let components = url.pathComponents.filter { $0 != "/" }
            // stremio:///detail/{type}/{id}[/{videoId}]
            if (url.host?.lowercased() ?? components.first?.lowercased()) == "detail" || components.first == "detail" {
                let parts = components.first == "detail" ? Array(components.dropFirst()) : components
                if parts.count >= 2 {
                    detail = MetaRoute(type: parts[0], id: parts[1], videoID: parts.count >= 3 ? parts[2] : nil)
                }
                return
            }
            // stremio:///search?search=query
            if components.first == "search" || url.host?.lowercased() == "search" {
                if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "search" || $0.name == "q" })?.value {
                    pendingSearch = query
                    tab = .search
                }
                return
            }
            switch components.first ?? url.host?.lowercased() ?? "" {
            case "discover", "board": tab = .discover
            case "library": tab = .library
            default: break
            }
        }
    }
}
