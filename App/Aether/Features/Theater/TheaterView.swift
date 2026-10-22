import SwiftUI
import AetherCore

/// Theater Mode: a landscape, cinema-style browser of the same catalogues the Home shows. Titles open the normal details screen
/// inside this mode, so going back returns here; "Esci" leaves it and gives the orientation back.
struct TheaterView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model = HomeViewModel()
    @StateObject private var selection = TheaterSelection()
    @State private var path: [MetaRoute] = []
    @State private var curtain = true

    private var animated: Bool { settings.animationsEnabled && !reduceMotion }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()
                if addons.enabledAddons.isEmpty {
                    emptyState
                } else {
                    stage
                }
                exitButton
                // The lights come up: a curtain of black that fades (instantly with reduced motion).
                Color.black.ignoresSafeArea().opacity(curtain ? 1 : 0).allowsHitTesting(false)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(addons.revision)#\(network.reconnectToken)") { await model.reload(env: env, mode: .normal) }
        .onAppear {
            OrientationController.set(.landscape)
            withAnimation(animated ? .easeOut(duration: 0.9).delay(0.25) : nil) { curtain = false }
        }
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

    private var stage: some View {
        VStack(spacing: 0) {
            Group {
                if let meta = selection.selected ?? model.heroItems.first {
                    TheaterFeature(meta: meta) { path.append(MetaRoute(meta: meta)) }
                } else {
                    Color.clear
                }
            }
            .frame(height: 230)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if !library.watchlist.isEmpty {
                        TheaterRow(title: "La mia watchlist", items: library.watchlist.map { $0.asMeta },
                                   selection: selection) { path.append(MetaRoute(meta: $0)) }
                    }
                    ForEach(model.catalogRefs) { ref in
                        TheaterCatalogRow(ref: ref, selection: selection) { path.append(MetaRoute(meta: $0)) }
                            .id("\(ref.id)#\(addons.revision)#\(network.reconnectToken)")
                    }
                    Color.clear.frame(height: 24)
                }
                .padding(.top, 6)
            }
        }
        .background(
            LinearGradient(colors: [Color.black, settings.accentColor.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .scaleEffect(curtain && animated ? 1.04 : 1)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 36))
            Text("Nessun addon installato").font(.headline)
            Text("Installa un addon di cataloghi per riempire Theater Mode.").font(.footnote).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
    }

    private var exitButton: some View {
        VStack {
            HStack {
                Button { OrientationController.set(.portrait); router.theater = false } label: {
                    Label("Esci", systemImage: "xmark")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .foregroundStyle(.white)
                .accessibilityIdentifier("theater.exit")
                Spacer()
            }
            Spacer()
        }
        .padding(.leading, 20).padding(.top, 10)
    }
}
