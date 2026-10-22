import SwiftUI
import AetherCore

/// A title card: wide (the backdrop) or tall (the poster) as the viewer chose, with year and genre under the name.
struct TheaterCard: View {
    let meta: MetaItem
    @AppStorage(TheaterPrefs.size) private var sizeChoice = 1
    @AppStorage(TheaterPrefs.portrait) private var portrait = false
    @AppStorage(TheaterPrefs.titles) private var showsTitle = true
    @AppStorage(TheaterPrefs.details) private var showsDetails = true
    @AppStorage(TheaterPrefs.corners) private var corners = 1
    @AppStorage(TheaterPrefs.border) private var border = 1
    @AppStorage(TheaterPrefs.palette) private var palette = 0

    private var width: CGFloat {
        let base: [CGFloat] = portrait ? [100, 124, 150] : [170, 210, 260]
        return base[min(max(sizeChoice, 0), 2)]
    }
    private var height: CGFloat { portrait ? width * 1.5 : width * 9 / 16 }
    private var radius: CGFloat { [2, 10, 20][min(max(corners, 0), 2)] }

    private var details: String {
        var parts: [String] = []
        if let year = meta.releaseInfo, !year.isEmpty { parts.append(String(year.prefix(4))) }
        if let genre = meta.genres.first, !genre.isEmpty { parts.append(genre) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(urlString: portrait ? (meta.poster ?? meta.background) : (meta.background ?? meta.poster),
                        width: width, placeholderSeed: meta.name)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border == 2 ? TheaterPalette.color(palette).opacity(0.85) : .white.opacity(border == 1 ? 0.16 : 0),
                                  lineWidth: border == 2 ? 1.6 : 1))
                .overlay(alignment: .topTrailing) {
                    if let rating = meta.imdbRating, !rating.isEmpty {
                        Text("★ \(rating)").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.65), in: Capsule()).foregroundStyle(TheaterPalette.color(palette)).padding(6)
                    }
                }
            if showsTitle {
                Text(meta.name).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1).frame(width: width, alignment: .leading)
            }
            if showsDetails && !details.isEmpty {
                Text(details).font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(details.isEmpty ? meta.name : "\(meta.name), \(details)")
        .accessibilityAddTraits(.isButton)
    }
}

struct TheaterCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TheaterPrefs.glow) private var glow = true
    @AppStorage(TheaterPrefs.palette) private var palette = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.06 : 1)
            .shadow(color: TheaterPalette.color(palette).opacity(glow && configuration.isPressed ? 0.7 : 0), radius: 14)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// The heading of a row, in the style the viewer chose.
struct TheaterHeading: View {
    let title: String
    @AppStorage(TheaterPrefs.rowStyle) private var style = 0
    @AppStorage(TheaterPrefs.palette) private var palette = 0

    var body: some View {
        switch style {
        case 1: Text(title).font(.system(.title3, design: .serif).weight(.bold)).foregroundStyle(.white)
        case 2: Text(title.uppercased()).font(.caption.weight(.bold)).tracking(3).foregroundStyle(TheaterPalette.color(palette))
        default: Text(title).font(.title3.weight(.bold)).foregroundStyle(.white)
        }
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
            TheaterHeading(title: title).padding(.leading, 24)
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
                        TheaterHeading(title: ref.title)
                        ProgressView().tint(.white)
                    }
                    .padding(.leading, 24)
                case .loaded(let items):
                    if !items.isEmpty { TheaterRow(title: ref.title, items: items, open: open) }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        TheaterHeading(title: ref.title)
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

/// The backdrop of every Theater screen, in the style the viewer chose.
struct TheaterBackground: View {
    @AppStorage(TheaterPrefs.background) private var style = 1
    @AppStorage(TheaterPrefs.palette) private var palette = 0

    var body: some View {
        let accent = TheaterPalette.color(palette)
        ZStack {
            Color.black
            if style == 1 {
                LinearGradient(colors: [.clear, accent.opacity(0.14)], startPoint: .top, endPoint: .bottom)
            } else if style == 2 {
                RadialGradient(colors: [accent.opacity(0.22), .clear], center: .topLeading, startRadius: 10, endRadius: 520)
                RadialGradient(colors: [accent.opacity(0.10), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 420)
            }
        }
        .ignoresSafeArea()
    }
}
