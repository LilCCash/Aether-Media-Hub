import SwiftUI
import AetherCore

enum AppTab: String, Hashable {
    case home, discover, universe, live, library, search, profile, downloads, settings
}

/// Pages inside the Profile tab other screens can send the viewer to.
enum ProfileRoute: Hashable {
    case settings, addons, services
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

/// The black page with the film's logo that stands in for the player from the tap on a source until the picture starts. It lives in
/// the player's own landscape container, so the screen turns once and nothing flashes in between.
@MainActor
final class PlayerLaunch: ObservableObject, Identifiable {
    let id = UUID()
    let meta: MetaItem
    @Published var resolution: DebridRowResolution?
    /// Everything is ready and the player waits for the «Guarda» button.
    @Published var ready = false
    /// Show the logo zooming out and wait for «Guarda» (off: the film starts as soon as it is ready).
    var intro = true
    var pending: PlayerRequest?
    /// The list of sources is still flying the logo to the middle of the screen: the page comes up when it lands (the work goes on).
    var holdUntil: Date?
    /// The logo arrived from the list already at its place: the page shows it there instead of zooming it in.
    var arrivesFromPicker = false
    /// Stops waiting for the link (the viewer pressed «Annulla»).
    let cancel: () -> Void

    init(meta: MetaItem, cancel: @escaping () -> Void) {
        self.meta = meta
        self.cancel = cancel
    }
}

/// Single place for cross-screen navigation: tab selection, deep links, the player, addon-install prompts.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .home
    /// With the Live TV tab on there is no room for the Search tab: Search opens as a page over the app instead.
    @Published var searchSheet = false
    /// «Scopri» opens as a page over the tabs (the Universe tab took its place in the bar).
    @Published var discoverSheet = false
    /// Universe and Live TV open as pages above the tabs, from the buttons at the top of the Home.
    @Published var universeSheet = false
    @Published var liveSheet = false
    @Published var player: PlayerRequest? {
        didSet {
            note(player == nil ? "Lettore: chiuso" : "Lettore: richiesta di apertura")
            guard player == nil else { return }
            launch = nil
            // The source list stays under the player while it plays: when the player closes, it goes away too.
            if let done = afterPlayer {
                afterPlayer = nil
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    done()
                }
            }
        }
    }
    /// The page shown while the source is prepared; nil once the picture runs.
    @Published var launch: PlayerLaunch?
    /// A line for the diagnostic log about how the player was opened and closed (set by the app).
    var note: (String) -> Void = { _ in }
    /// What to do once the player closes (closing the source list that is still under it).
    var afterPlayer: (() -> Void)?
    @Published var detail: MetaRoute?
    /// The list of sources opened from a card of the Home or the Library (Continue watching, Up next). It is shown by the root of the
    /// app: shown by the card itself it vanished when the screen turned for the player (the card is made again), and took the
    /// player's black page with it.
    @Published var picker: StreamPickerRequest?
    /// A section of the Library asked from outside (the widget's «Watchlist» button); the Library takes it and clears it.
    @Published var librarySection: String?
    /// The poster a title page was opened from (one title can be in several rows): the page zooms out of that one.
    var zoomSourceID: String?
    @Published var pendingAddonInput: String?
    /// A page of the Profile tab that something else asked for (the addons, the services, the settings); consumed by the tab.
    @Published var profileRoute: ProfileRoute?

    func open(_ route: ProfileRoute) {
        profileRoute = route
        tab = usesGlassHome ? .settings : .profile
    }

    /// The glass Home is chosen: the bar is Home, Cerca, Libreria, Download, Impostazioni, and Scopri and the profile open over it.
    @Published var usesGlassHome = false
    /// The profile, opened from the picture of the glass Home.
    @Published var profileSheet = false
    /// The content type Scopri should show when it appears (a category of the glass Home); consumed by Scopri.
    @Published var discoverType: String?
    @Published var pendingSearch: String?

    func openDetail(_ meta: MetaItem) {
        detail = MetaRoute(meta: meta)
    }

    func play(_ request: PlayerRequest) {
        player = request
    }

    /// Starts playing: with the start screen of its kind it opens black at once, shows the logo and waits for «Guarda»; without, plays.
    func playWithIntro(_ request: PlayerRequest, enabled: Bool) {
        guard enabled, launch == nil else { play(request); return }
        let page = PlayerLaunch(meta: request.meta, cancel: { [weak self] in self?.launch = nil })
        page.pending = request
        page.ready = true
        launch = page
    }

    /// Handles `aether://…` and `stremio://…` links.
    func handle(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if let installURL = AddonURL.installURL(fromDeepLink: url) {
            pendingAddonInput = installURL.absoluteString
            open(.addons)
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
            case "live": tab = .live
            case "universe": tab = .universe
            case "library": tab = .library
            // Widget buttons: «Watchlist» opens that list, «Riprendi» the title watched last.
            case "watchlist":
                librarySection = "watchlist"
                tab = .library
            case "resume": QuickActionRouter.shared.receive("app.aether.resume")
            default: break
            }
        }
    }
}
