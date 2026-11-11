import Combine
import CoreSpotlight
import SwiftUI
import UserNotifications
import UIKit
import AetherCore

@main
struct AetherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environmentObject(env)
                .environmentObject(env.settings)
                .environmentObject(env.router)
                .environmentObject(env.addons)
                .environmentObject(env.library)
                .environmentObject(env.network)
                .environmentObject(env.downloads)
                .environmentObject(env.casting)
                .environmentObject(env.relay)
                .environmentObject(env.extras)
                .environmentObject(env.livePlaylists)
                .environmentObject(env.tvGuide)
                .environment(\.imageLoader, env.images)
                .task { await env.bootstrap() }
                .onOpenURL { env.router.handle(url: $0) }
        }
    }
}

/// UIKit hooks SwiftUI does not cover: the orientation lock used by the player and the completion handler iOS
/// hands over when a background download session wakes the app.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Dock: a translucent blurred bar with a hairline, the selected item in the accent colour (iOS 26 draws its own glass on top).
        let bar = UITabBarAppearance()
        bar.configureWithDefaultBackground()
        // Adaptive: the same bar in light and dark (it was always the dark navy one, also with the light theme).
        bar.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        bar.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.04, blue: 0.14, alpha: 0.55)
                : UIColor(white: 1, alpha: 0.55)
        }
        bar.shadowColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.08)
        }
        UITabBar.appearance().standardAppearance = bar
        UITabBar.appearance().scrollEdgeAppearance = bar
        return true
    }

    // Notifications are shown even with the app open; a tap on an invitation that suggests a title opens its page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let type = info["type"] as? String, let id = info["id"] as? String else { return }
        await MainActor.run { QuickActionRouter.shared.receive("detail:\(type)/\(id)") }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationMask
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // A quick action that launches the app arrives here; one used while it runs goes to the scene delegate.
        if let item = options.shortcutItem {
            let type = item.type
            Task { @MainActor in QuickActionRouter.shared.receive(type) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = AetherSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.backgroundCompletionHandler = completionHandler
    }
}

/// The Home-screen quick actions (long press on the icon): the app opens the section the action names.
@MainActor
final class QuickActionRouter {
    static let shared = QuickActionRouter()
    private var pending: String?
    var handler: ((String) -> Void)? {
        didSet {
            if let type = pending, let handler = handler {
                pending = nil
                handler(type)
            }
        }
    }

    func receive(_ type: String) {
        if let handler = handler { handler(type) } else { pending = type }
    }
}

final class AetherSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let type = shortcutItem.type
        Task { @MainActor in QuickActionRouter.shared.receive(type) }
        completionHandler(true)
    }
}

/// SwiftUI's `preferredColorScheme` does not always reach what is presented over the tabs (sheets, covers): the window itself is told too.
enum InterfaceStyle {
    @MainActor static func apply(_ scheme: ColorScheme?) {
        let style: UIUserInterfaceStyle = scheme == .light ? .light : (scheme == .dark ? .dark : .unspecified)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

struct RootView: View {
    /// The bar of the system (iOS 26 draws it in Liquid Glass): four items on the left and the search apart on the right, as the
    /// system does for a tab with the search role (before iOS 18 the five items in a row).
    @ViewBuilder
    private var tabs: some View {
        if settings.value.appearance.homeLayout == .glass {
            glassTabs
        } else {
            if #available(iOS 18.0, *) {
                modernTabs
            } else {
                legacyTabs
            }
        }
    }

    /// The bar of the glass Home: Home, Cerca, Libreria, Download, Impostazioni. Scopri opens from the categories of the Home and
    /// the profile from its picture.
    private var glassTabs: some View {
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            SearchView()
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            LibraryView()
                .tabItem { Label("Libreria", systemImage: "books.vertical.fill") }
                .tag(AppTab.library)
            NavigationStack { DownloadsView().navigationTitle("Download").aetherPage() }
                .tabItem { Label("Download", systemImage: "arrow.down.circle.fill") }
                .tag(AppTab.downloads)
            SettingsTabView()
                .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }

    private var legacyTabs: some View {
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)
            DiscoverView()
                .tabItem { Label("Scopri", systemImage: "safari.fill") }
                .tag(AppTab.discover)
            LibraryView()
                .tabItem { Label("Libreria", systemImage: "books.vertical.fill") }
                .tag(AppTab.library)
            SearchView()
                .tabItem { Label("Cerca", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            ProfileTabView()
                .tabItem { Label("Profilo", systemImage: "person.crop.circle.fill") }
                .tag(AppTab.profile)
        }
    }

    @available(iOS 18.0, *)
    private var modernTabs: some View {
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
            Tab("Scopri", systemImage: "safari.fill", value: AppTab.discover) { DiscoverView() }
            Tab("Libreria", systemImage: "books.vertical.fill", value: AppTab.library) { LibraryView() }
            Tab("Profilo", systemImage: "person.crop.circle.fill", value: AppTab.profile) { ProfileTabView() }
            Tab("Cerca", systemImage: "magnifyingglass", value: AppTab.search, role: .search) { SearchView() }
        }
    }

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var extras: ExtrasService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var titleZoom

    private var detailAsSheet: Bool { return settings.value.appearance.detailAsCard }

    var body: some View {
        tabs
        .overlay(alignment: .top) { SaveProblemBanner(monitor: env.saveProblems) }
        // Symbols and labels in the accent (the bar, the buttons of the bars, links) in a shade that reads on the page.
        .tint(settings.accentColor.legible(on: colorScheme))
        .onAppear { router.usesGlassHome = settings.value.appearance.homeLayout == .glass }
        .onChange(of: settings.value.appearance.homeLayout) { _, layout in
            router.usesGlassHome = layout == .glass
            // A tab of the other bar is not there any more: back to the Home.
            let glassOnly: Set<AppTab> = [.downloads, .settings]
            let classicOnly: Set<AppTab> = [.discover, .profile]
            if (layout == .glass && classicOnly.contains(router.tab)) || (layout == .classic && glassOnly.contains(router.tab)) {
                router.tab = .home
            }
        }
        .onChange(of: router.tab) { old, new in
            Haptics.select()
            // With the glass Home, Scopri and the profile are not in the bar: asked for (a link, a shortcut), they open over it.
            if router.usesGlassHome && (new == .discover || new == .profile) {
                router.tab = (old == .discover || old == .profile) ? .home : old
                if new == .discover { router.discoverSheet = true } else { router.profileSheet = true }
            }
            if !router.usesGlassHome && new == .settings { router.tab = old == .settings ? .home : old; router.open(.settings) }
            if !router.usesGlassHome && new == .downloads { router.tab = old == .downloads ? .home : old }
            // Universe and Live TV are not in the bar: a request for them (a shortcut) opens them as full pages over the tabs.
            if new == .universe { router.tab = old == .universe ? .home : old; router.universeSheet = true }
            if new == .live { router.tab = old == .live ? .home : old; router.liveSheet = true }
        }
        .fullScreenCover(isPresented: $router.universeSheet) {
            UniverseHubView(onClose: { router.universeSheet = false })
        }
        .fullScreenCover(isPresented: $router.liveSheet) {
            LiveTVView(onClose: { router.liveSheet = false })
        }
        .fullScreenCover(isPresented: $router.discoverSheet) {
            DiscoverView(onClose: { router.discoverSheet = false })
        }
        .sheet(isPresented: $router.profileSheet) {
            ProfileTabView(onClose: { router.profileSheet = false })
        }
        .environment(\.zoomNamespace, titleZoom)
        .preferredColorScheme(settings.colorScheme)
        .onAppear { InterfaceStyle.apply(settings.colorScheme) }
        .onChange(of: settings.colorScheme) { _, scheme in InterfaceStyle.apply(scheme) }
        .task {
            QuickActionRouter.shared.handler = { [router] type in
                switch type {
                case "app.aether.continue": router.tab = .home
                case "app.aether.resume":
                    // The title watched last, on its page; with no history, the Home.
                    router.tab = .home
                    if let last = library.history.first {
                        router.detail = MetaRoute(type: last.type, id: last.metaID, preview: last.asMeta)
                    }
                case "app.aether.search": router.tab = .search
                case "app.aether.library": router.tab = .library
                case "app.aether.downloads": router.tab = .library
                default:
                    // «Cerca in Aether» from Siri or Spotlight: the words come after the prefix.
                    if type.hasPrefix("detail:") {
                        let parts = type.dropFirst("detail:".count).split(separator: "/", maxSplits: 1).map(String.init)
                        if parts.count == 2 { router.detail = MetaRoute(type: parts[0], id: parts[1]) }
                    } else if type.hasPrefix("watchlist:") || type.hasPrefix("open:") {
                        // Siri: the title the viewer named, found in the addons; added to the watchlist when asked; its page opens.
                        let adding = type.hasPrefix("watchlist:")
                        let query = String(type.drop(while: { $0 != ":" }).dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !query.isEmpty else { return }
                        Task { @MainActor in
                            if let meta = await env.searchService.bestMatch(for: query) {
                                if adding && !library.watchlistIDs.contains(meta.id) { library.toggleWatchlist(meta) }
                                router.detail = MetaRoute(type: meta.type, id: meta.id, preview: meta)
                            } else {
                                router.pendingSearch = query
                                router.tab = .search
                            }
                        }
                    } else if type.hasPrefix("search:") {
                        router.pendingSearch = String(type.dropFirst("search:".count))
                        router.tab = .search
                    }
                }
            }
        }
        .onContinueUserActivity("app.aether.title") { activity in
            if let type = activity.userInfo?["type"] as? String, let id = activity.userInfo?["id"] as? String { router.detail = MetaRoute(type: type, id: id) }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let route = SpotlightIndexer.route(forIdentifier: identifier) {
                router.detail = route
            }
        }
        // «Cerca in Aether» under the results of the system search: the words the viewer typed open the Search tab.
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            if let query = activity.userInfo?[CSSearchQueryString] as? String, !query.isEmpty {
                router.pendingSearch = query
                router.tab = .search
            }
        }
        .onReceive(library.$watchlist.combineLatest(library.$favorites)) { watchlist, favorites in
            SpotlightIndexer.setLibrary(watchlist + favorites)
        }
        .onReceive(library.$history) { history in
            SpotlightIndexer.record(history.map { $0.asMeta })
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { env.persistForBackground() }
            if phase == .active { env.extras.appBecameActive(); Task { await FolderSyncService.shared.syncIfDue(env: env) } }
            if phase == .background { Task { await FolderSyncService.shared.syncIfDue(env: env, minimumInterval: 30) } }
            env.relay.appPhaseChanged(phase)
        }
        .landscapePlayer($router.player, showsLaunch: true)
        .sheet(isPresented: $extras.showingWhatsNew) { WhatsNewSheet() }
        .sheet(item: $router.picker) { request in StreamPickerSheet(request: request) }
        .sheet(item: Binding(get: { detailAsSheet ? router.detail : nil }, set: { router.detail = $0 })) { route in
            // The zoom is set on the presented page itself (the stack), not inside it: inside, iOS took it for a push and ignored it.
            NavigationStack { DetailView(route: route) }
                .zoomDestination(id: route.id)
                // For the automated tour only (see the full-screen branch below).
                .overlay(alignment: .topLeading) {
                    if ProcessInfo.processInfo.arguments.contains("-AETHER_UITEST") {
                        Button { router.detail = nil } label: { Color.clear.frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .accessibilityIdentifier("detail.closeCard")
                    }
                }
        }
        .fullScreenCover(item: Binding(get: { detailAsSheet ? nil : router.detail }, set: { router.detail = $0 })) { route in
            NavigationStack {
                DetailView(route: route)
                    .environment(\.pullToDismiss, { router.detail = nil })
                    // The automated tour closes the card with this (a pull down is not reliable there). Not present for viewers.
                    .overlay(alignment: .topLeading) {
                        if ProcessInfo.processInfo.arguments.contains("-AETHER_UITEST") {
                            Button { router.detail = nil } label: { Color.clear.frame(width: 44, height: 44).contentShape(Rectangle()) }
                                .accessibilityIdentifier("detail.closeCard")
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { router.detail = nil } label: { Image(systemName: "xmark") }
                                .accessibilityLabel("Chiudi")
                        }
                    }
            }
            .zoomDestination(id: route.id)
        }
    }
}
