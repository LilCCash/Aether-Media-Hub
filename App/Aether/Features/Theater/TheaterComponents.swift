import SwiftUI
import AetherCore

/// What Theater Mode has highlighted: the title shown large above the rows. Tapping a poster highlights it; tapping the
/// highlighted one (or "Apri") opens its details.
@MainActor
final class TheaterSelection: ObservableObject {
    @Published var selected: MetaItem?

    /// A row offers its first title when nothing has been highlighted yet.
    func offer(_ item: MetaItem?) {
        if selected == nil { selected = item }
    }
}

/// The large artwork, title, facts and description of the highlighted title.
struct TheaterFeature: View {
    let meta: MetaItem
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: SettingsStore

    private var facts: [String] {
        var parts: [String] = [RequestPlanner.friendlyTypeName(meta.type)]
        if let year = meta.releaseInfo, !year.isEmpty { parts.append(year) }
        if let runtime = meta.runtime, !runtime.isEmpty { parts.append(runtime) }
        if let genres = Optional(meta.genres.prefix(3)), !genres.isEmpty { parts.append(genres.joined(separator: " · ")) }
        return parts
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                RemoteImage(urlString: meta.background ?? meta.poster, width: proxy.size.width, placeholderSeed: meta.name)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .overlay(
                        LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay(
                        LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                    )
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(meta.name)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    if let rating = meta.imdbRating, !rating.isEmpty { RatingBadge(rating: rating) }
                    Text(facts.joined(separator: "  ·  ")).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
                if let text = meta.description, !text.isEmpty {
                    Text(text).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                }
                Button(action: open) {
                    Label("Apri", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 22).frame(height: 40)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
                .padding(.top, 4)
                .accessibilityIdentifier("theater.open")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.leading, 28).padding(.bottom, 18)
            .id(meta.id)
            .transition(.opacity)
        }
        .foregroundStyle(.white)
        .id(meta.id)
        .transition(.opacity)
        .animation(settings.animationsEnabled && !reduceMotion ? .easeInOut(duration: 0.35) : nil, value: meta.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater.feature")
    }
}

/// A poster that lifts and glows when highlighted.
struct TheaterPoster: View {
    let meta: MetaItem
    let isSelected: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        let animated = settings.animationsEnabled && !reduceMotion
        RemoteImage(urlString: meta.poster ?? meta.background, width: width, placeholderSeed: meta.name)
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.95 : 0), lineWidth: 2.5))
            .shadow(color: settings.accentColor.opacity(isSelected ? 0.65 : 0), radius: 16)
            .scaleEffect(isSelected ? 1.08 : 1)
            .opacity(isSelected ? 1 : 0.72)
            .animation(animated ? .spring(response: 0.3, dampingFraction: 0.8) : nil, value: isSelected)
            .padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(meta.name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One horizontal row of titles with its heading. Tap highlights; tap on the highlighted title opens it.
struct TheaterRow: View {
    let title: String
    let items: [MetaItem]
    @ObservedObject var selection: TheaterSelection
    let open: (MetaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.9)).padding(.leading, 28)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(items.prefix(40).enumerated()), id: \.offset) { _, item in
                        TheaterPoster(meta: item, isSelected: selection.selected?.id == item.id, width: 104)
                            .onTapGesture {
                                if selection.selected?.id == item.id { open(item) } else { selection.selected = item }
                            }
                    }
                }
                .padding(.horizontal, 28)
            }
            .scrollClipDisabled()
        }
        .onAppear { selection.offer(items.first) }
    }
}

/// A catalogue of the installed addons as a Theater row; loads with the same model as the Home rows.
struct TheaterCatalogRow: View {
    let ref: CatalogRef
    @ObservedObject var selection: TheaterSelection
    let open: (MetaItem) -> Void
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Loaded(ref: ref, selection: selection, open: open, env: env)
    }

    private struct Loaded: View {
        let ref: CatalogRef
        @ObservedObject var selection: TheaterSelection
        let open: (MetaItem) -> Void
        @StateObject private var model: CatalogRowModel

        init(ref: CatalogRef, selection: TheaterSelection, open: @escaping (MetaItem) -> Void, env: AppEnvironment) {
            self.ref = ref
            self.selection = selection
            self.open = open
            _model = StateObject(wrappedValue: CatalogRowModel(ref: ref, env: env))
        }

        var body: some View {
            Group {
                switch model.state {
                case .idle, .loading:
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.title).font(.headline).foregroundStyle(.white.opacity(0.9)).padding(.leading, 28)
                        ProgressView().tint(.white).padding(.leading, 28)
                    }
                case .loaded(let items):
                    if !items.isEmpty { TheaterRow(title: ref.title, items: items, selection: selection, open: open) }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ref.title).font(.headline).foregroundStyle(.white.opacity(0.9))
                        Text(message).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        Button("Riprova") { Task { await model.load(force: true) } }.font(.footnote.weight(.semibold))
                    }
                    .padding(.leading, 28)
                }
            }
            .task { await model.load() }
        }
    }
}
