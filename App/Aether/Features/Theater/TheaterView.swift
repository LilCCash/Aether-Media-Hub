import SwiftUI
import AetherCore

/// Theater Mode: a landscape, cinema-style version of the app. A rail of icons on the left switches between its sections (Home,
/// Scopri, Libreria, Cerca, Impostazioni); titles open the normal details screen inside this mode, so going back returns here.
struct TheaterView: View {
    enum Section: Hashable { case home, discover, library, search, settings }

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TheaterPrefs.intro) private var introEnabled = true
    @StateObject private var model = HomeViewModel()
    @State private var section: Section = .home
    @State private var path: [MetaRoute] = []
    @State private var introDone = false

    private var animated: Bool { settings.animationsEnabled && !reduceMotion }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HStack(spacing: 0) {
                rail
                Group {
                    switch section {
                    case .home: homeSection
                    case .discover: DiscoverView()
                    case .library: LibraryView()
                    case .search: SearchView()
                    case .settings: NavigationStack { TheaterSettingsView() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if introEnabled && !introDone { TheaterIntro(animated: animated) { introDone = true } }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(addons.revision)#\(network.reconnectToken)") { await model.reload(env: env, mode: .normal) }
        .onAppear { OrientationController.set(.landscape) }
        .onDisappear { OrientationController.set(.portrait) }
        // The player gives the orientation back to portrait when it closes: Theater Mode asks for landscape again.
        .onChange(of: router.player == nil) { _, closed in
            if closed { OrientationController.set(.landscape) }
        }
        .fullScreenCover(item: Binding(get: { router.player }, set: { router.player = $0 })) { request in
            PlayerView(request: request, env: env)
        }
        .accessibilityIdentifier("theater.root")
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack.fill").font(.title3).foregroundStyle(TheaterPrefs.gold).padding(.top, 6)
            railButton(.home, "house.fill", "Home")
            railButton(.discover, "square.grid.2x2.fill", "Scopri")
            railButton(.library, "heart.fill", "Libreria")
            railButton(.search, "magnifyingglass", "Cerca")
            Spacer()
            railButton(.settings, "gearshape.fill", "Impostazioni di Theater Mode")
            Button {
                OrientationController.set(.portrait)
                router.theater = false
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityLabel("Esci da Theater Mode")
            .accessibilityIdentifier("theater.exit")
        }
        .padding(.vertical, 10)
        .frame(width: 66)
        .background(Color.white.opacity(0.06))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
    }

    private func railButton(_ target: Section, _ symbol: String, _ label: String) -> some View {
        let active = section == target
        return Button { section = target } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 46, height: 46)
                .foregroundStyle(active ? Color.black : .white.opacity(0.75))
                .background(active ? TheaterPrefs.gold : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("theater.rail.\(target)")
    }

    // MARK: Home

    @ViewBuilder
    private var homeSection: some View {
        NavigationStack(path: $path) {
            ZStack {
                LinearGradient(colors: [Color.black, settings.accentColor.opacity(0.16)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                if addons.enabledAddons.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 36))
                        Text("Nessun addon installato").font(.headline)
                        Text("Installa un addon di cataloghi per riempire Theater Mode.").font(.footnote).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if !library.watchlist.isEmpty {
                                TheaterRow(title: "La mia watchlist", items: library.watchlist.map { $0.asMeta }) { path.append(MetaRoute(meta: $0)) }
                            }
                            ForEach(model.catalogRefs) { ref in
                                TheaterCatalogRow(ref: ref) { path.append(MetaRoute(meta: $0)) }
                                    .id("\(ref.id)#\(addons.revision)#\(network.reconnectToken)")
                            }
                            Color.clear.frame(height: 24)
                        }
                        .padding(.top, 16)
                    }
                }
            }
            .overlay(alignment: .topTrailing) { topActions }
            .navigationBarHidden(true)
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
        }
    }

    /// Search and settings, always within reach at the top right.
    private var topActions: some View {
        HStack(spacing: 6) {
            topButton("magnifyingglass", "Cerca") { section = .search }
            topButton("gearshape", "Impostazioni di Theater Mode") { section = .settings }
        }
        .padding(.trailing, 14).padding(.top, 8)
    }

    private func topButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 40, height: 40)
                .foregroundStyle(.white).background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}
