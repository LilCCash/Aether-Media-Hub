import SwiftUI
import AetherCore

/// Impostazioni as an item of the bar (glass Home). The same settings as from the gear of the profile; pages that something else
/// asks for (the addons after an install link, the services) open here.
struct SettingsTabView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootView()
                .navigationDestination(for: ProfileRoute.self) { route in
                    switch route {
                    case .settings: SettingsRootView()
                    case .addons: AddonsView()
                    case .services: ServicesSettingsView()
                    }
                }
        }
        .onChange(of: router.profileRoute) { _, route in consume(route) }
        .onChange(of: router.pendingAddonInput) { _, input in
            if input != nil { router.open(.addons) }
        }
        .onAppear {
            consume(router.profileRoute)
            if router.pendingAddonInput != nil { router.open(.addons) }
        }
    }

    private func consume(_ route: ProfileRoute?) {
        guard let route = route, router.usesGlassHome else { return }
        router.profileRoute = nil
        path = NavigationPath()
        if route != .settings { path.append(route) }
    }
}
