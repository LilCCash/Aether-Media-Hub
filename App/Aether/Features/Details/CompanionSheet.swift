import SwiftUI
import AetherCore

/// Companion: who is in the film and where it sits in its universe, at the level of detail the viewer picks (nothing about the plot at the first one).
struct CompanionSheet: View {
    let meta: MetaItem
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("aether.pro.companion.level") private var levelRaw = SpoilerLevel.none.rawValue

    private var level: SpoilerLevel { return SpoilerLevel(rawValue: levelRaw) ?? .none }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Livello", selection: $levelRaw) {
                                ForEach(SpoilerLevel.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                            .pickerStyle(.segmented)
                            Text(level.explanation).font(.caption).foregroundStyle(Color.aetherSecondary)
                        }
                        let watched = Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys)
                        ForEach(CompanionPlanner.cards(for: meta, level: level, watched: watched)) { card in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.heading).font(.headline)
                                ForEach(card.lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(Color.primary.opacity(0.85)) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
                        }
                        Text("Tutto viene dai dati dell'addon e dagli universi di Aether: niente curiosità inventate.").font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// «Companion» button for a title page.
struct CompanionButton: View {
    let meta: MetaItem
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: { Label("Companion", systemImage: "person.2.crop.square.stack").font(.subheadline.weight(.semibold)) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("detail.companion")
            .sheet(isPresented: $shown) { CompanionSheet(meta: meta) }
    }
}
