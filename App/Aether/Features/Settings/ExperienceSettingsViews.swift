import SwiftUI
import AetherCore

// MARK: - Catalogs: visibility, names, order

/// Settings > Aspetto > Cataloghi: every catalog of every installed addon, with an on/off switch, an optional name of the
/// viewer's own and its place in the list. Home, Scopri and Cerca all follow the same names and order.
struct CatalogLayoutSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @State private var rows: [Row] = []
    @State private var editing: Row?
    @State private var draftName = ""

    struct Row: Identifiable, Equatable {
        var ref: CatalogRef
        var visible: Bool
        var id: String { ref.id }
    }

    private var layout: CatalogLayoutSettings { settings.value.content.catalogLayout }

    var body: some View {
        let ordered = layout.sorted(rows, id: { $0.id })
        let ids = ordered.map { $0.id }
        Form {
            Section(footer: Text("Interruttore: mostra o nasconde il catalogo. Frecce: ne cambiano il posto. Tocca il nome per rinominarlo: Home, Scopri e Cerca useranno il tuo nome. L'ordine vale per tutte le schermate.")) {
                if ordered.isEmpty {
                    Text("Nessun catalogo: installa un addon dalla scheda Addon.").foregroundStyle(.secondary)
                }
                ForEach(ordered) { row in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(get: { row.visible }, set: { value in setVisible(row, value) }))
                            .labelsHidden()
                        Button {
                            editing = row
                            draftName = layout.customTitle(forID: row.id) ?? ""
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(layout.title(forID: row.id, fallback: row.ref.title)).foregroundStyle(.primary)
                                Text("\(row.ref.addonName) · \(RequestPlanner.friendlyTypeName(row.ref.type))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button { settings.value.content.catalogLayout.move(id: row.id, by: -1, among: ids) } label: { Image(systemName: "chevron.up") }
                            .disabled(!layout.canMove(id: row.id, by: -1, among: ids))
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Sposta su")
                        Button { settings.value.content.catalogLayout.move(id: row.id, by: 1, among: ids) } label: { Image(systemName: "chevron.down") }
                            .disabled(!layout.canMove(id: row.id, by: 1, among: ids))
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Sposta giù")
                    }
                }
            }
            Section {
                Button("Ripristina nomi e ordine", role: .destructive) {
                    settings.value.content.catalogLayout = CatalogLayoutSettings()
                }
                .disabled(layout == CatalogLayoutSettings())
            }
        }
        .navigationTitle("Cataloghi")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Rinomina il catalogo", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Nome", text: $draftName)
            Button("Salva") {
                if let row = editing { settings.value.content.catalogLayout.setTitle(draftName, forID: row.id) }
                editing = nil
            }
            Button("Nome originale") {
                if let row = editing { settings.value.content.catalogLayout.setTitle(nil, forID: row.id) }
                editing = nil
            }
            Button("Annulla", role: .cancel) { editing = nil }
        } message: {
            Text(editing.map { "Nome dell'addon: \($0.ref.title)" } ?? "")
        }
    }

    private func load() async {
        let handles = await env.addons.handles()
        var seen = Set<String>()
        var list: [Row] = []
        for ref in RequestPlanner.feedCatalogs(handles: handles, includeHidden: true) where seen.insert(ref.id).inserted {
            let visible = handles.first(where: { $0.addon.id == ref.addonID })?.addon.isCatalogVisible(ref.catalog) ?? true
            list.append(Row(ref: ref, visible: visible))
        }
        rows = list
    }

    private func setVisible(_ row: Row, _ value: Bool) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index].visible = value }
        Task { await env.addons.setCatalogVisible(value, catalogKey: row.ref.catalog.key, id: row.ref.addonID) }
    }
}

// MARK: - Sources: badges, addon logo, text format

/// Settings > Aspetto > Sorgenti: how the lines of the source list are written.
struct StreamDisplaySettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var display: StreamDisplaySettings { settings.value.content.streamDisplay }
    @State private var importing = false
    @State private var importMessage: String?

    var body: some View {
        Form {
            Section(header: Text("Addon"), footer: Text("Mostra il logo dell'addon accanto a ogni sorgente (se l'addon ne ha uno).")) {
                Toggle("Logo dell'addon", isOn: settings.binding(\.content.streamDisplay.showAddonLogo))
                    .accessibilityIdentifier("settings.streams.logo")
            }
            Section(header: Text("Badge"), footer: Text("I badge nascono dai dati della sorgente: 4K, HDR10, Dolby Vision, Atmos, codec, lingue, dimensione e formato.")) {
                Picker("Stile", selection: settings.binding(\.content.streamDisplay.badgeStyle)) {
                    ForEach(StreamBadgeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                ForEach(StreamBadgeKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(get: { display.isShown(kind) },
                                                     set: { settings.value.content.streamDisplay.setShown($0, kind) }))
                }
            }
            Section(header: Text("Badge personalizzati"),
                    footer: Text("Importa da un link (https) un elenco JSON di badge: ogni badge compare sulle sorgenti il cui testo contiene una delle parole. Esempio: [{\"label\":\"Remux\",\"match\":[\"remux\"],\"color\":\"#FF9500\"}] oppure {\"badges\":[…]}. Una parola che inizia con re: è un'espressione regolare.")) {
                TextField("https://…/badge.json", text: settings.binding(\.content.streamDisplay.customBadgesURL))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityIdentifier("settings.streams.badgeURL")
                Button(importing ? "Importo…" : "Importa i badge") { Task { await importBadges() } }
                    .disabled(importing || display.customBadgesURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("settings.streams.badgeImport")
                if let importMessage { Text(importMessage).font(.footnote).foregroundStyle(.secondary) }
                ForEach(display.customBadges) { rule in
                    HStack {
                        Text(rule.label).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background((rule.colorHex.map { Color(hex: $0) } ?? Color.gray).opacity(0.25), in: Capsule())
                        Text(rule.match.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !display.customBadges.isEmpty {
                    Button("Rimuovi i badge importati", role: .destructive) {
                        settings.value.content.streamDisplay.customBadges = []
                        importMessage = nil
                    }
                }
            }
            Section(header: Text("Formato del testo"),
                    footer: Text("Vuoto = testo originale dell'addon. Segnaposto: \(StreamDisplaySettings.tokens.joined(separator: " "))")) {
                ForEach(StreamDisplaySettings.presets, id: \.title) { preset in
                    Button(preset.title) { settings.value.content.streamDisplay.template = preset.template }
                }
                TextField("Modello personalizzato", text: settings.binding(\.content.streamDisplay.template), axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
            }
        }
        .navigationTitle("Sorgenti")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension StreamDisplaySettingsView {
    fileprivate func importBadges() async {
        let text = display.customBadgesURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
            importMessage = "Il link deve iniziare con https://"
            return
        }
        importing = true
        defer { importing = false }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            importMessage = "Non riesco a scaricare il file."
            return
        }
        let rules = CustomBadgePack.parse(data)
        guard !rules.isEmpty else {
            importMessage = "Nel file non ho trovato badge validi."
            return
        }
        settings.value.content.streamDisplay.customBadges = rules
        importMessage = "Importati \(rules.count) badge."
    }
}

// MARK: - Title page: TMDB modules, saga, ratings

struct TitlePageSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject var credentials: ServiceCredentials

    var body: some View {
        Form {
            Section(header: Text("Moduli TMDB"), footer: Text("Scegli quali blocchi mostra la scheda di un film o di una serie. Servono la chiave TMDB.")) {
                Toggle("Cast e troupe", isOn: settings.binding(\.content.titleModules.cast))
                Toggle("Trailer", isOn: settings.binding(\.content.titleModules.trailers))
                Toggle("Produzione", isOn: settings.binding(\.content.titleModules.companies))
                Toggle("Incassi e budget", isOn: settings.binding(\.content.titleModules.financials))
                Toggle("Dettagli", isOn: settings.binding(\.content.titleModules.facts))
                Toggle("Titoli simili", isOn: settings.binding(\.content.titleModules.similar))
                Toggle("Saga / collezione", isOn: settings.binding(\.content.titleModules.collection))
            }
            Section(header: Text("Voti"), footer: Text(credentials.isConfigured(.mdblist)
                    ? "Scegli i servizi da mostrare nella scheda del titolo."
                    : "Per vedere i voti serve la chiave MDBList (Impostazioni ▸ Servizi).")) {
                Toggle("Mostra i voti", isOn: settings.binding(\.content.ratings.enabled))
                if settings.value.content.ratings.enabled {
                    ForEach(RatingSource.allCases, id: \.self) { source in
                        Toggle(source.title, isOn: Binding(get: { settings.value.content.ratings.isShown(source) },
                                                           set: { settings.value.content.ratings.setShown($0, source) }))
                    }
                }
            }
        }
        .navigationTitle("Scheda del titolo")
        .navigationBarTitleDisplayMode(.inline)
    }
}
