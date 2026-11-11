import SwiftUI
import UniformTypeIdentifiers
import AetherCore

/// Impostazioni ▸ Live TV: la voce nella barra in basso, le playlist M3U, i cataloghi degli addon che contano come TV in diretta
/// e, in fondo, quali di essi compaiono in Scopri e Home.
struct LiveTVSettingsView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var playlists: LivePlaylistService
    @EnvironmentObject private var tvGuide: TVGuideService
    @State private var adding = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var importing = false
    @State private var importError: String?

    private struct Row: Identifiable {
        let addon: InstalledAddon
        let catalog: ManifestCatalog
        var id: String { return addon.id.uuidString + "/" + catalog.key }
        var isTV: Bool { return ContentTypes.canonicalID(catalog.type) == "tv" }
        /// A catalog that only answers a search is not a list of channels.
        var isSearchOnly: Bool { return catalog.supportsSearch && !catalog.isPlainFeed && DiscoverFiltering.serverFilter(for: catalog) == nil }
    }

    private var allRows: [Row] {
        var found: [Row] = []
        for addon in addons.addons where addon.isEnabled {
            for catalog in addon.manifest.catalogs { found.append(Row(addon: addon, catalog: catalog)) }
        }
        return found
    }

    private var live: LiveTVSettings { return settings.value.content.liveTV }

    var body: some View {
        Form {
            Section(footer: Text("Live TV si apre dal pulsante con la TV in alto a sinistra in Scopri.")) {
                Label("Live TV", systemImage: "tv.fill")
            }

            Section(header: Text("Playlist M3U"),
                    footer: Text("Una playlist è un elenco di canali (file .m3u o .m3u8) che ti dà il tuo fornitore o che trovi online. Aether la scarica e la tiene sul telefono. Servono indirizzi https: iOS blocca http per i download delle liste.")) {
                if live.playlists.isEmpty { Text("Nessuna playlist.").foregroundStyle(Color.aetherSecondary) }
                ForEach(live.playlists) { playlist in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(playlist.name).font(.body.weight(.semibold))
                            Spacer()
                            if playlists.loading.contains(playlist.id) { ProgressView() }
                        }
                        let count = playlists.cached(playlist.id).count
                        Text(count > 0 ? "\(count) canali" + (playlists.updated[playlist.id].map { " · aggiornata \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "") : "Nessun canale scaricato")
                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                        if let message = playlists.messages[playlist.id] { Text(message).font(.caption).foregroundStyle(.orange) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { remove(playlist) } label: { Label("Elimina", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        if playlist.url != nil { Button { Task { await playlists.load(playlist, force: true) } } label: { Label("Aggiorna", systemImage: "arrow.clockwise") }.tint(.blue) }
                    }
                }
                Button { adding = true } label: { Label("Aggiungi da indirizzo", systemImage: "link.badge.plus") }
                Button { importing = true } label: { Label("Importa da file", systemImage: "doc.badge.plus") }
                if let importError = importError { Text(importError).font(.caption).foregroundStyle(.orange) }
            }

            Section(header: Text("Cataloghi degli addon in Live TV"),
                    footer: Text("I cataloghi di tipo «tv» compaiono da soli. Qui puoi spegnerne qualcuno oppure considerare TV in diretta un catalogo di un altro tipo (per esempio un catalogo sportivo). I moduli che servono solo per la ricerca non sono elencati.")) {
                let rows = allRows.filter { !$0.isSearchOnly }
                if rows.isEmpty { Text("Nessun addon installato offre cataloghi.").foregroundStyle(Color.aetherSecondary) }
                ForEach(addons.addons.filter { addon in rows.contains { $0.addon.id == addon.id } }) { addon in
                    DisclosureGroup(addon.displayName) {
                        ForEach(rows.filter { $0.addon.id == addon.id }) { row in
                            Toggle(isOn: Binding(
                                get: { live.includes(catalogKey: row.id, isTVType: row.isTV) },
                                set: { settings.value.content.liveTV.setIncluded($0, catalogKey: row.id, isTVType: row.isTV) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.catalog.name)
                                    Text(row.isTV ? "TV in diretta" : "tipo «\(row.catalog.type)»").font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                    }
                }
            }

            Section(header: Text("Guida TV"),
                    footer: Text("Sotto i canali delle playlist compare cosa va in onda ora e dopo; tieni premuto un canale per la sua guida. Senza un indirizzo, Aether usa la guida indicata dalla playlist o, se manca, una guida pubblica dei canali italiani (epgshare01). Accetta file XMLTV, anche compressi (.xml.gz). Si aggiorna ogni 12 ore.")) {
                Toggle("Mostra la guida TV", isOn: settings.binding(\.content.liveTV.guideEnabled))
                if live.guideEnabled {
                    TextField("Indirizzo della guida (facoltativo)", text: settings.binding(\.content.liveTV.guideURL))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tvGuide.guide.isEmpty ? "Guida non ancora scaricata" : "\(tvGuide.guide.programmes.count) canali nella guida")
                            if !tvGuide.guide.isEmpty {
                                Text("Aggiornata \(tvGuide.guide.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                        Spacer()
                        if tvGuide.isLoading { ProgressView() } else {
                            Button("Aggiorna") {
                                Task { await tvGuide.refresh(settings: live, announced: playlists.announcedGuides(live.playlists), force: true) }
                            }
                        }
                    }
                    if let message = tvGuide.message { Text(message).font(.caption).foregroundStyle(.orange) }
                }
            }

            let tvRows = allRows.filter { $0.isTV }
            if !tvRows.isEmpty {
                Section(header: Text("In Scopri e Home"),
                        footer: Text("Spegnere un catalogo lo nasconde da Scopri e Home; per i moduli di ricerca l'interruttore decide se partecipano alla ricerca. Il lettore per le dirette si sceglie in Riproduzione ▸ Motore.")) {
                    ForEach(tvRows) { row in
                        if row.catalog.supportsSearch && !row.catalog.isPlainFeed && DiscoverFiltering.serverFilter(for: row.catalog) == nil {
                            Toggle(isOn: Binding(
                                get: { row.addon.isCatalogSearchable(row.catalog) },
                                set: { value in Task { await addons.setCatalogVisible(value, catalogKey: InstalledAddon.searchKey(row.catalog), id: row.addon.id) } })) {
                                label(row, detail: "usato nella ricerca")
                            }
                        } else {
                            Toggle(isOn: Binding(
                                get: { row.addon.isCatalogVisible(row.catalog) },
                                set: { value in Task { await addons.setCatalogVisible(value, catalogKey: row.catalog.key, id: row.addon.id) } })) {
                                label(row, detail: DiscoverFiltering.serverFilter(for: row.catalog)?.isRequired == true
                                      ? "in Scopri, scelta del gruppo obbligatoria" : "in Scopri e Home")
                            }
                        }
                    }
                }
            }
        }
        .aetherPage()
        .navigationTitle("Live TV")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Aggiungi una playlist", isPresented: $adding) {
            TextField("Nome", text: $newName)
            TextField("https://…/lista.m3u", text: $newURL).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("Aggiungi") { addPlaylist() }
            Button("Annulla", role: .cancel) { newName = ""; newURL = "" }
        } message: { Text("Incolla l'indirizzo della lista (https).") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .plainText], allowsMultipleSelection: false) { result in
            importFile(result)
        }
    }

    private func label(_ row: Row, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.catalog.name)
            Text(row.addon.displayName + " · " + detail).font(.caption).foregroundStyle(Color.aetherSecondary)
        }
    }

    private func addPlaylist() {
        let address = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { newName = ""; newURL = "" }
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
            importError = "Indirizzo non valido: deve cominciare con https://"
            return
        }
        importError = nil
        let name = newName.trimmingCharacters(in: .whitespaces).isEmpty ? (url.host ?? "Playlist") : newName.trimmingCharacters(in: .whitespaces)
        let playlist = LivePlaylist(name: name, url: address)
        settings.value.content.liveTV.playlists.append(playlist)
        Task { await playlists.load(playlist, force: true) }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= 30 * 1024 * 1024 else {
            importError = "Non riesco a leggere il file (o è oltre 30 MB)."
            return
        }
        let playlist = LivePlaylist(name: url.deletingPathExtension().lastPathComponent, url: nil)
        playlists.importText(data, into: playlist.id)
        if playlists.cached(playlist.id).isEmpty {
            importError = playlists.messages[playlist.id] ?? "Nessun canale trovato nel file."
            playlists.remove(playlist.id)
            return
        }
        importError = nil
        settings.value.content.liveTV.playlists.append(playlist)
    }

    private func remove(_ playlist: LivePlaylist) {
        settings.value.content.liveTV.playlists.removeAll { $0.id == playlist.id }
        playlists.remove(playlist.id)
    }
}
