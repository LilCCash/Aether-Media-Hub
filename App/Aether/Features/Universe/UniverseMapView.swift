import SwiftUI
import AetherCore

/// The whole universe on one line: every title is a dot on a long horizontal timeline, in the order of release or of the story,
/// with its poster above or below, a ring when it has been watched, and a tap to open it.
struct UniverseMapView: View {
    let universe: UniverseDefinition
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var order: UniverseOrder = .release

    private let nodeWidth: CGFloat = 112
    private let half: CGFloat = 190

    private var custom: [String]? { return settings.value.content.universes.customOrders[universe.id] }
    private var watched: Set<String> { return Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys) }
    private var orders: [UniverseOrder] { return universe.chronological == nil ? [.release] : [.release, .chronological] }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                VStack(spacing: 12) {
                    if orders.count > 1 {
                        Picker("Ordine", selection: $order) { ForEach(orders, id: \.self) { Text($0.title).tag($0) } }
                            .pickerStyle(.segmented).padding(.horizontal, Theme.pageMargin)
                    }
                    let entries = universe.ordered(order, custom: custom)
                    let seen = watched
                    ScrollView(.horizontal, showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            Capsule()
                                .fill(LinearGradient(colors: universe.gradient, startPoint: .leading, endPoint: .trailing))
                                .frame(width: CGFloat(entries.count) * nodeWidth, height: 4)
                                .offset(y: half - 2)
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    node(entry, index: index, isWatched: seen.contains(entry.id))
                                        .frame(width: nodeWidth, height: half * 2)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    Text("\(entries.filter { seen.contains($0.id) }.count) di \(entries.count) visti · tocca un titolo per aprirlo")
                        .font(.footnote).foregroundStyle(Color.aetherSecondary)
                    if order == .chronological, let note = universe.chronologicalNote {
                        Text(note).font(.caption2).foregroundStyle(Color.aetherSecondary).padding(.horizontal, Theme.pageMargin).multilineTextAlignment(.center)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Mappa · \(universe.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() }.fontWeight(.semibold) } }
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
        }
    }

    private func node(_ entry: UniverseEntry, index: Int, isWatched: Bool) -> some View {
        let above = index % 2 == 0
        let route = MetaRoute(type: entry.type, id: entry.id, preview: MetaItem(id: entry.id, type: entry.type, name: entry.name, poster: UniverseArt.poster(entry.id)))
        return ZStack {
            Circle().fill(isWatched ? Color.accentColor : Color.primary.opacity(0.35)).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 2))
                .position(x: nodeWidth / 2, y: half)
            NavigationLink(value: route) {
                VStack(spacing: 6) {
                    if !above { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5, height: 22) }
                    ZStack(alignment: .bottomTrailing) {
                        RemoteImage(urlString: UniverseArt.poster(entry.id), width: 200, placeholderSeed: entry.name, systemPlaceholder: "film")
                            .frame(width: 82, height: 123)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isWatched ? Color.accentColor : Color.clear, lineWidth: 2.5))
                            .opacity(isWatched ? 1 : 0.82)
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).font(.system(size: 20)).offset(x: 6, y: 6)
                        }
                    }
                    Text(entry.name).font(.system(size: 11, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2).frame(width: nodeWidth - 12)
                    Text(String(entry.year)).font(.system(size: 10)).foregroundStyle(Color.aetherSecondary)
                    if above { Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 1.5, height: 22) }
                }
                .frame(width: nodeWidth, height: half - 8, alignment: above ? .bottom : .top)
            }
            .buttonStyle(.pressable)
            .position(x: nodeWidth / 2, y: above ? (half - 8) / 2 : half + 8 + (half - 8) / 2)
        }
        .frame(width: nodeWidth, height: half * 2)
    }
}
