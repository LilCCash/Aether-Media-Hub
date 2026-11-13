import SwiftUI
import AetherCore

// MARK: - Content

struct ContentSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var confirmClearHistory = false
    @State private var confirmClearSearch = false

    var body: some View {
        Form {
            Section(header: Text("Cataloghi e Scopri"), footer: Text("Nome, ordine e visibilità dei cataloghi di ogni addon (valgono in Home, Scopri e Cerca) e le categorie di Scopri.")) {
                NavigationLink {
                    CatalogLayoutSettingsView()
                } label: {
                    Label("Cataloghi: nomi, ordine, visibilità", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("settings.catalogs")
                NavigationLink {
                    DiscoverSettingsView()
                } label: {
                    Label("Categorie di Scopri", systemImage: "safari")
                }
                .accessibilityIdentifier("settings.discover")
            }
            Section(header: Text("Addon")) {
                NavigationLink {
                    AddonsView()
                } label: {
                    LabeledContent("Gestisci gli addon", value: "\(addons.enabledAddons.count)/\(addons.addons.count)")
                }
                Toggle("Nascondi i cataloghi per adulti", isOn: settings.binding(\.content.hideAdultCatalogs))
                Toggle("Nascondi i talk show", isOn: settings.binding(\.content.hideTalkShows))
                if settings.value.content.hideTalkShows {
                    Toggle("Nella Home", isOn: settings.binding(\.content.talkHome))
                    Toggle("In Scopri", isOn: settings.binding(\.content.talkDiscover))
                    Toggle("Nella ricerca", isOn: settings.binding(\.content.talkSearch))
                    Toggle("Nelle filmografie degli attori", isOn: settings.binding(\.content.talkCast))
                    Toggle("Nei titoli simili", isOn: settings.binding(\.content.talkSimilar))
                }
            }
            Section(header: Text("Aggiornamento"), footer: Text("Per quanto tempo un catalogo resta valido prima di essere riscaricato (a meno che l'addon non indichi un valore proprio). Tira verso il basso per forzare l'aggiornamento.")) {
                Picker("Aggiorna i cataloghi ogni", selection: settings.binding(\.content.catalogRefreshMinutes)) {
                    ForEach([1, 5, 10, 30, 60, 360, 1440], id: \.self) { minutes in
                        Text(minutes >= 60 ? "\(minutes / 60) h" : "\(minutes) min").tag(minutes)
                    }
                }
            }
            Section(header: Text("Ricerca")) {
                Toggle("Cerca negli addon", isOn: settings.binding(\.content.searchRemote))
                Toggle("Cerca anche nella libreria", isOn: settings.binding(\.content.searchLocal))
                Toggle("Salva le ricerche recenti", isOn: settings.binding(\.content.saveSearchHistory))
                Picker("Ordinamento predefinito", selection: settings.binding(\.content.searchSort)) {
                    ForEach(SearchSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(header: Text("Lingua di trama e dettagli"), footer: Text("Con la chiave TMDB, trama, generi, cast e titoli arrivano in questa lingua anche quando l'addon li fornisce in inglese.")) {
                Picker("Lingua preferita", selection: settings.binding(\.content.preferredLanguage)) {
                    Text("Lingua del sistema").tag("system")
                    Text("Italiano").tag("it")
                    Text("Inglese").tag("en")
                    Text("Francese").tag("fr")
                    Text("Spagnolo").tag("es")
                    Text("Tedesco").tag("de")
                    Text("Portoghese").tag("pt")
                }
                .accessibilityIdentifier("settings.contentLanguage")
            }
            Section(header: Text("Cronologia")) {
                Button("Cancella cronologia di visione", role: .destructive) { confirmClearHistory = true }
                Button("Cancella ricerche recenti", role: .destructive) { confirmClearSearch = true }
            }
        }
        .aetherPage()
        .navigationTitle("Contenuti e scoperta")
        .confirmationDialog("Cancellare la cronologia di visione?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Cancella", role: .destructive) { Task { await env.libraryStore.clearHistory() } }
        }
        .confirmationDialog("Cancellare le ricerche recenti?", isPresented: $confirmClearSearch, titleVisibility: .visible) {
            Button("Cancella", role: .destructive) { Task { await env.libraryStore.clearSearchHistory() } }
        }
    }
}
