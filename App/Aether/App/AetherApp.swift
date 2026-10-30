import Combine
import CoreSpotlight
import SwiftUI
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
                .environment(\.imageLoader, env.images)
                .task { await env.bootstrap() }
                .onOpenURL { env.router.handle(url: $0) }
        }
    }
}

/// UIKit hooks SwiftUI does not cover: the orientation lock used by the player and the completion handler iOS
/// hands over when a background download session wakes the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientationMask: UIInterfaceOrientationMask = .portrait

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
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
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
            MoreView()
                .tabItem { Label("Altro", systemImage: "ellipsis.circle.fill") }
                .tag(AppTab.more)
        }
        .tint(settings.accentColor)
        .preferredColorScheme(settings.colorScheme)
        .onAppear { InterfaceStyle.apply(settings.colorScheme) }
        .onChange(of: settings.colorScheme) { _, scheme in InterfaceStyle.apply(scheme) }
        .task {
            QuickActionRouter.shared.handler = { [router] type in
                switch type {
                case "app.aether.continue": router.tab = .home
                case "app.aether.search": router.tab = .search
                case "app.aether.library": router.tab = .library
                case "app.aether.downloads": router.tab = .more
                default: break
                }
            }
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
               let url = SpotlightIndexer.url(forIdentifier: identifier) {
                router.handle(url: url)
            }
        }
        .onReceive(library.$watchlist.combineLatest(library.$favorites).debounce(for: .seconds(2), scheduler: DispatchQueue.main)) { watchlist, favorites in
            SpotlightIndexer.reindex(watchlist + favorites)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { env.persistForBackground() }
            env.relay.appPhaseChanged(phase)
        }
        // While Theater Mode is open it presents the player itself (one full-screen cover cannot present another from the same view).
        .landscapePlayer(Binding(get: { router.theater ? nil : router.player }, set: { router.player = $0 }))
        .fullScreenCover(isPresented: $router.theater) { TheaterView() }
        .sheet(item: $router.detail) { route in
            NavigationStack { DetailView(route: route) }
        }
    }
}
