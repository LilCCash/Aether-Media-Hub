import SwiftUI
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

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.backgroundCompletionHandler = completionHandler
    }
}

struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { env.persistForBackground() }
        }
        .fullScreenCover(item: $router.player) { request in
            PlayerView(request: request, env: env)
        }
        .sheet(item: $router.detail) { route in
            NavigationStack { DetailView(route: route) }
        }
    }
}
