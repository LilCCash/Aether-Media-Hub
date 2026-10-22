import SwiftUI
import AetherCore

/// A title card: wide (the backdrop) or tall (the poster) as the viewer chose, lifting and glowing while pressed.
struct TheaterCard: View {
    let meta: MetaItem
    @AppStorage(TheaterPrefs.size) private var sizeChoice = 1
    @AppStorage(TheaterPrefs.portrait) private var portrait = false
    @AppStorage(TheaterPrefs.titles) private var showsTitle = true

    private var width: CGFloat {
        let base: [CGFloat] = portrait ? [100, 124, 150] : [170, 210, 260]
        return base[min(max(sizeChoice, 0), 2)]
    }
    private var height: CGFloat { portrait ? width * 1.5 : width * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(urlString: portrait ? (meta.poster ?? meta.background) : (meta.background ?? meta.poster),
                        width: width, placeholderSeed: meta.name)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            if showsTitle {
                Text(meta.name).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meta.name)
        .accessibilityAddTraits(.isButton)
    }
}

struct TheaterCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.06 : 1)
            .shadow(color: TheaterPrefs.gold.opacity(configuration.isPressed ? 0.7 : 0), radius: 14)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// One horizontal row of titles with its heading.
struct TheaterRow: View {
    let title: String
    let items: [MetaItem]
    let open: (MetaItem) -> Void
    @AppStorage(TheaterPrefs.sprockets) private var sprockets = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.white).padding(.leading, 24)
            if sprockets { FilmSprockets() }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(Array(items.prefix(40).enumerated()), id: \.offset) { _, item in
                        Button { open(item) } label: { TheaterCard(meta: item) }
                            .buttonStyle(TheaterCardStyle())
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 6)
            }
            .scrollClipDisabled()
            if sprockets { FilmSprockets() }
        }
    }
}

/// A catalogue of the installed addons as a Theater row; loads with the same model as the Home rows.
struct TheaterCatalogRow: View {
    let ref: CatalogRef
    let open: (MetaItem) -> Void
    @EnvironmentObject private var env: AppEnvironment

    var body: some View { Loaded(ref: ref, open: open, env: env) }

    private struct Loaded: View {
        let ref: CatalogRef
        let open: (MetaItem) -> Void
        @StateObject private var model: CatalogRowModel

        init(ref: CatalogRef, open: @escaping (MetaItem) -> Void, env: AppEnvironment) {
            self.ref = ref
            self.open = open
            _model = StateObject(wrappedValue: CatalogRowModel(ref: ref, env: env))
        }

        var body: some View {
            Group {
                switch model.state {
                case .idle, .loading:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                        ProgressView().tint(.white)
                    }
                    .padding(.leading, 24)
                case .loaded(let items):
                    if !items.isEmpty { TheaterRow(title: ref.title, items: items, open: open) }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.title).font(.title3.weight(.bold)).foregroundStyle(.white)
                        Text(message).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        Button("Riprova") { Task { await model.load(force: true) } }.font(.footnote.weight(.semibold))
                    }
                    .padding(.leading, 24)
                }
            }
            .task { await model.load() }
        }
    }
}
