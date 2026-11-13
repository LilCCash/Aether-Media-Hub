import SwiftUI
import AetherCore

struct SettingsRootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var query = ""
    @State private var showsAll = false

    /// The pages «Impostazioni essenziali» keeps on the first screen; the others are one tap away.
    static let essentialPages: Set<String> = ["Aspetto", "Riproduzione", "Addon", "Servizi e chiavi", "Casting", "Archiviazione",
                                              "Informazioni e licenze"]
    private var essentialOnly: Bool { settings.value.appearance.essentialSettings && !showsAll }

    var body: some View {
        List {
            if settings.value.appearance.settingsSearch && !query.trimmingCharacters(in: .whitespaces).isEmpty {
                searchResults
            } else {
                sections
                if essentialOnly {
                    Section(footer: Text("Stai vedendo solo le impostazioni principali (Aspetto › Scorciatoie › «Impostazioni essenziali»).")) {
                        Button("Mostra tutte le impostazioni") { showsAll = true }
                            .accessibilityIdentifier("settings.showAll")
                    }
                }
            }
        }
        .modifier(SettingsSearchField(enabled: settings.value.appearance.settingsSearch, query: $query))
        .aetherPage()
        .navigationTitle("Impostazioni")
        .accessibilityIdentifier("settings.root")
    }

    @ViewBuilder
    private var searchResults: some View {
        let hits = SettingsIndex.search(query)
        if hits.isEmpty {
            Text("Nessuna impostazione corrisponde a «\(query)».")
                .foregroundStyle(Color.aetherSecondary)
                .accessibilityIdentifier("settings.search.empty")
        } else {
            ForEach(hits) { hit in
                NavigationLink {
                    destination(for: hit.page).labelStyle(SettingsIconLabelStyle())
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title)
                        Text(hit.page.title).font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                }
                .accessibilityIdentifier("settings.search.\(hit.id)")
            }
        }
    }

    @ViewBuilder
    private func destination(for page: SettingsIndex.Page) -> some View {
        switch page {
        case .appearance: AppearanceSettingsView()
        case .playback: PlaybackSettingsView()
        case .sourceScoring: SourceScoringSettingsView()
        case .addons: AddonsView()
        case .content: ContentSettingsView()
        case .liveTV: LiveTVSettingsView()
        case .advancedSearch: AdvancedSearchSettingsView()
        case .indexing: IndexingSettingsView()
        case .services: ServicesSettingsView()
        case .trakt: TraktSettingsView(trakt: env.trakt)
        case .sync: SyncSettingsView()
        case .account: AccountDataSettingsView()
        case .casting: CastingSettingsView()
        case .storage: StorageSettingsView()
        case .extras: ExtrasSettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutView()
        }
    }

    @ViewBuilder
    private var sections: some View {
            Section(header: Text("Aspetto e riproduzione")) {
                link("Aspetto", "paintpalette.fill", .pink) { AppearanceSettingsView() }
                link("Riproduzione", "play.rectangle.fill", .orange) { PlaybackSettingsView() }
                link("Intelligenza delle fonti", "wand.and.stars", .purple) { SourceScoringSettingsView() }
            }
            Section(header: Text("Contenuti")) {
                link("Addon", "puzzlepiece.extension.fill", .indigo) { AddonsView() }
                link("Cataloghi e scoperta", "square.grid.2x2.fill", .green) { ContentSettingsView() }
                link("Live TV", "tv.fill", .red) { LiveTVSettingsView() }
                link("Ricerca avanzata", "sparkle.magnifyingglass", .mint) { AdvancedSearchSettingsView() }
                link("Indicizzazione", "magnifyingglass.circle.fill", .blue) { IndexingSettingsView() }
            }
            Section(header: Text("Account e servizi")) {
                link("Servizi e chiavi", "key.fill", .purple) { ServicesSettingsView() }
                link("Trakt", "play.square.stack.fill", .red) { TraktSettingsView(trakt: env.trakt) }
                link("Sincronizzazione", "icloud.fill", .cyan) { SyncSettingsView() }
                link("Account e dati", "person.crop.circle.fill", .blue) { AccountDataSettingsView() }
            }
            Section(header: Text("Dispositivo")) {
                link("Casting", "tv.and.mediabox.fill", .teal) { CastingSettingsView() }
                link("Archiviazione", "internaldrive.fill", .brown) { StorageSettingsView() }
                link("Funzioni extra", "sparkles", .cyan) { ExtrasSettingsView() }
                link("Avanzate", "wrench.and.screwdriver.fill", .gray) { AdvancedSettingsView() }
            }
            Section {
                link("Informazioni e licenze", "info.circle.fill", .blue) { AboutView() }
            }
    }

    @ViewBuilder
    private func link<Destination: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: () -> Destination) -> some View {
        if !essentialOnly || SettingsRootView.essentialPages.contains(title) {
        NavigationLink {
            destination().labelStyle(SettingsIconLabelStyle())
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(color.gradient, in: RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                    .overlay(Sheen(shape: RoundedRectangle(cornerRadius: Corner.chip, style: .continuous), strength: 1.3))
                    .shadow(color: color.opacity(0.35), radius: 4, y: 2)
                Text(title)
            }
        }
        .accessibilityIdentifier("settings.\(title)")
        }
    }
}

/// The search field of Impostazioni, present only while «Ricerca nelle impostazioni» is on.
private struct SettingsSearchField: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca nelle impostazioni")
        } else {
            content
        }
    }
}
