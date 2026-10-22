import SwiftUI
import AetherCore

/// Theater Mode: a landscape, cinema-style version of the app. A rail of icons on the left switches between its sections; titles open
/// the normal details screen inside this mode, so going back returns here.
struct TheaterView: View {
    enum Section: Hashable { case home, series, discover, library, search, settings }

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TheaterPrefs.intro) private var introEnabled = true
    @AppStorage(TheaterPrefs.sound) private var soundEnabled = true
    @AppStorage(TheaterPrefs.palette) private var palette = 0
    @AppStorage(TheaterPrefs.railLabels) private var railLabels = false
    @StateObject private var model = HomeViewModel()
    @State private var section: Section = .home
    @State private var introDone = false
    @State private var logoPresses = 0
    @State private var clapper = false
    @State private var openMeta: MetaItem?
    @State private var picker: StreamPickerRequest?

    private var animated: Bool { settings.animationsEnabled && !reduceMotion }
    private var accent: Color { TheaterPalette.color(palette) }

    var body: some View {
        HStack(spacing: 0) {
            rail
            // One screen per section: leaving a section (for example from deep inside the settings) starts the next one from its top.
            Group {
                if section == .settings { TheaterMore() } else { page }
            }
            .id(section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) { if section != .settings { topActions } }
        }
        .background(TheaterBackground())
        .overlay {
            if let meta = openMeta {
                TheaterDetail(meta: meta, close: { closeTitle() }, pick: { picked, video in
                    picker = StreamPickerRequest(meta: picked, video: video, resumeAt: nil)
                })
                .id(meta.id)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .overlay {
            if let request = picker {
                TheaterStreamPicker(request: request, close: { picker = nil })
                    .id(request.id)
                    .transition(.opacity)
            }
        }
        .overlay { if clapper { clapperBoard } }
        .overlay {
            if introEnabled && !introDone {
                TheaterIntro(animated: animated, sound: soundEnabled, accent: accent) { introDone = true }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: "\(addons.revision)#\(network.reconnectToken)") { await model.reload(env: env, mode: .normal) }
        // Theater Mode is landscape: the player gives the orientation back to this when it closes, not to portrait.
        .onAppear { OrientationController.base = .landscape; OrientationController.set(.landscape) }
        .onDisappear { OrientationController.base = .portrait; OrientationController.set(.portrait); TheaterSound.stop() }
        .fullScreenCover(item: Binding(get: { router.player }, set: { router.player = $0 })) { request in
            PlayerView(request: request, env: env)
        }
        // A marker, not an identifier on the container: an identifier on a container replaces those of everything inside it.
        .background(Color.clear.accessibilityElement().accessibilityIdentifier("theater.root"))
    }

    private func openTitle(_ meta: MetaItem) {
        withAnimation(animated ? .easeOut(duration: 0.3) : nil) { openMeta = meta }
    }

    private func closeTitle() {
        withAnimation(animated ? .easeIn(duration: 0.22) : nil) { openMeta = nil }
    }

    // MARK: Sections

    @ViewBuilder
    private var page: some View {
        if addons.enabledAddons.isEmpty && section != .settings {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 36))
                Text("Nessun addon installato").font(.headline)
                Text("Installa un addon di cataloghi per riempire Theater Mode.").font(.footnote).foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch section {
            case .home:
                TheaterPage(title: "Film") {
                    ForEach(model.catalogRefs.filter { $0.type == ContentType.movie }) { ref in
                        TheaterCatalogRow(ref: ref, open: openTitle).id("\(ref.id)#\(addons.revision)#\(network.reconnectToken)")
                    }
                }
            case .series:
                TheaterPage(title: "Serie") {
                    ForEach(model.catalogRefs.filter { $0.type == ContentType.series }) { ref in
                        TheaterCatalogRow(ref: ref, open: openTitle).id("\(ref.id)#\(addons.revision)#\(network.reconnectToken)")
                    }
                }
            case .discover: TheaterDiscover(refs: model.catalogRefs, open: openTitle)
            case .library: TheaterLibrary(open: openTitle)
            case .search: TheaterSearch(open: openTitle)
            case .settings: EmptyView()
            }
        }
    }

    // MARK: Rail

    private var rail: some View {
        VStack(spacing: 6) {
            logo
            railButton(.home, "film.fill", "Film")
            railButton(.series, "tv.fill", "Serie")
            railButton(.discover, "square.grid.2x2.fill", "Scopri")
            railButton(.library, "heart.fill", "Libreria")
            Spacer()
            railButton(.settings, "gearshape.fill", "Impostazioni")
            Button {
                OrientationController.base = .portrait
                OrientationController.set(.portrait)
                router.theater = false
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 40, height: 40).foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityLabel("Esci da Theater Mode")
            .accessibilityIdentifier("theater.exit")
        }
        .padding(.vertical, 6)
        .frame(width: railLabels ? 108 : 66)
        .background(Color.white.opacity(0.06))
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.1)).frame(width: 1) }
    }

    private var logo: some View {
        Image(systemName: "film.stack.fill").font(.title3).foregroundStyle(accent).frame(width: 46, height: 34)
            .onLongPressGesture(minimumDuration: 1.1) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                clapper = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { clapper = false }
            }
            .accessibilityHidden(true)
    }

    private func railButton(_ target: Section, _ symbol: String, _ label: String) -> some View {
        let active = section == target
        return Button {
            section = target
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title3).frame(width: 26)
                if railLabels { Text(label).font(.caption.weight(.semibold)).lineLimit(1) }
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .foregroundStyle(active ? Color.black : .white.opacity(0.75))
            .background(active ? accent : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 8)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("theater.rail.\(target)")
    }

    /// Search and settings, always within reach at the top right.
    private var topActions: some View {
        HStack(spacing: 6) {
            topButton("magnifyingglass", "Cerca") { section = .search }
            topButton("gearshape", "Impostazioni") { section = .settings }
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

    // MARK: A small surprise

    private var clapperBoard: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "movieclapper.fill").font(.system(size: 54)).foregroundStyle(accent)
                Text("CIAK, SI GIRA!").font(.system(size: 34, weight: .black, design: .serif)).tracking(6).foregroundStyle(.white)
            }
            .transition(.scale.combined(with: .opacity))
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: clapper)
        .allowsHitTesting(false)
    }
}
