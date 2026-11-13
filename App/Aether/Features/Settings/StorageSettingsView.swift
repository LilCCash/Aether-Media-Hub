import SwiftUI
import AetherCore

// MARK: - Storage

struct StorageSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var library: LibraryModel
    @State private var report: AppEnvironment.StorageReport?
    @State private var message: String?

    var body: some View {
        Form {
            Section(header: Text("Spazio utilizzato")) {
                StorageOverview(report: report, items: downloads.items, history: library.history, refresh: { await refresh() })
                    .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            }
            Section(header: Text("Cache")) {
                Picker("Limite cache immagini", selection: settings.binding(\.storage.imageCacheLimitMB)) {
                    ForEach([100, 300, 600, 1000, 2000], id: \.self) { Text("\($0) MB").tag($0) }
                }
                Toggle("Salva in cache metadati e cataloghi", isOn: settings.binding(\.storage.cacheMetadata))
                Button("Svuota cache immagini") { Task { await env.clearImageCache(); await refresh(); message = "Cache immagini svuotata." } }
                Button("Svuota cache di cataloghi e metadati") { Task { await env.clearMetadataCache(); await refresh(); message = "Cache dei metadati svuotata." } }
                if let message = message { Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary) }
            }
            Section(header: Text("Download")) {
                Toggle("Scarica anche con dati mobili", isOn: settings.binding(\.storage.downloadOverCellular))
                Stepper("Download simultanei: \(settings.value.storage.maxConcurrentDownloads)", value: settings.binding(\.storage.maxConcurrentDownloads), in: 1...4)
                Toggle("Elimina i download dopo la visione", isOn: settings.binding(\.storage.deleteDownloadsAfterWatching))
                NavigationLink("Gestisci i download") { DownloadsView().navigationTitle("Download") }
            }
            Section(header: Text("Diagnostica downloader"),
                    footer: Text("Il log resta sul dispositivo. Gli URL e le credenziali vengono oscurati prima di essere registrati. Attiva la registrazione prima di riprodurre l'errore, poi esporta il file e allegalo alla segnalazione.")) {
                Toggle("Abilita log del downloader", isOn: settings.binding(\.privacy.keepDiagnosticLog))
                    .accessibilityIdentifier("storage.downloaderLogs")
                Toggle("Log dettagliati", isOn: settings.binding(\.advanced.verboseLogging))
                    .disabled(!settings.value.privacy.keepDiagnosticLog)
                NavigationLink("Visualizza e salva log") {
                    DownloadLogView(diagnostics: env.diagnostics)
                }
                .accessibilityIdentifier("storage.viewDownloaderLogs")
            }
            Section(header: Text("Scarica una stagione"), footer: Text("Aether cerca sorgenti per ogni episodio e prova a mantenere la stessa lingua e una qualità coerente. Se non trova una sorgente compatibile, salta solo quell'episodio e lo segnala. La dimensione è stimata: gli addon non sempre comunicano i GB reali.")) {
                Picker("Qualità", selection: settings.binding(\.storage.seasonDownloadQuality)) {
                    ForEach(VideoQualityCap.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Lingua audio", selection: settings.binding(\.storage.seasonDownloadLanguage)) {
                    Text("Come lingua preferita di Riproduzione").tag("preferred")
                    Text("Italiano").tag("it")
                    Text("Inglese").tag("en")
                    Text("Francese").tag("fr")
                    Text("Spagnolo").tag("es")
                    Text("Tedesco").tag("de")
                    Text("Portoghese").tag("pt")
                    Text("Qualsiasi lingua").tag("any")
                }
                Picker("Gestione dello spazio", selection: settings.binding(\.storage.seasonDownloadSizePolicy)) {
                    ForEach(SeasonDownloadSizePolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NavigationLink {
                    SeasonDownloadAddonsSettingsView()
                } label: {
                    Label("Addon per i download stagionali", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("settings.seasonDownloadAddons")
            }
        }
        .aetherPage()
        .navigationTitle("Archiviazione")
        .task { await refresh() }
    }

    private func refresh() async {
        report = await env.storageReport()
    }
}

// MARK: - Seasonal download addon preferences

struct SeasonDownloadAddonsSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var addons: [AddonHandle] = []

    var body: some View {
        Form {
            Section(footer: Text("Disattivare un addon lo esclude soltanto dalla ricerca dei download stagionali; non cambia la riproduzione normale. I torrent richiedono un provider debrid configurato, ad esempio TorBox.")) {
                if addons.isEmpty {
                    Text("Nessun addon disponibile.")
                        .foregroundStyle(Color.aetherSecondary)
                } else {
                    ForEach(addons, id: \.id) { handle in
                        Toggle(isOn: Binding(
                            get: { !settings.value.storage.seasonDownloadDisabledAddonIDs.contains(handle.id.uuidString) },
                            set: { enabled in
                                var disabled = settings.value.storage.seasonDownloadDisabledAddonIDs
                                if enabled {
                                    disabled.removeAll { $0 == handle.id.uuidString }
                                } else if !disabled.contains(handle.id.uuidString) {
                                    disabled.append(handle.id.uuidString)
                                }
                                settings.value.storage.seasonDownloadDisabledAddonIDs = disabled.sorted()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(handle.addon.displayName)
                                Text("Usa questo addon per i download stagionali")
                                    .font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                    }
                }
            }
        }
        .aetherPage()
        .navigationTitle("Addon download stagionali")
        .task { addons = await env.addons.handles() }
    }
}

private struct DownloadLogView: View {
    let diagnostics: DiagnosticLog
    @State private var entries: [LogEntry] = []
    @State private var exportURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("\(entries.count) eventi registrati")
                        .foregroundStyle(Color.aetherSecondary)
                    Spacer()
                    Button("Aggiorna") { Task { await refresh() } }
                }
                Button("Svuota log", role: .destructive) {
                    Task {
                        await diagnostics.clear()
                        await refresh()
                        exportURL = nil
                        statusMessage = "Log svuotato."
                    }
                }
                Button("Esporta log…") { Task { await export() } }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Condividi file di log", systemImage: "square.and.arrow.up")
                    }
                }
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
            }
            Section("Eventi") {
                if entries.isEmpty {
                    Text("Nessun evento registrato. Abilita i log in Archiviazione e riprova il download.")
                        .foregroundStyle(Color.aetherSecondary)
                } else {
                    ForEach(entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.label).font(.caption.monospaced().weight(.bold))
                                Text(entry.category).font(.caption.monospaced())
                                Spacer()
                                Text(entry.date, style: .time).font(.caption2).foregroundStyle(Color.aetherSecondary)
                            }
                            Text(entry.message).font(.footnote).textSelection(.enabled)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .aetherPage()
        .navigationTitle("Log downloader")
        .task { await refresh() }
    }

    private func refresh() async {
        entries = await diagnostics.entries()
    }

    private func export() async {
        let text = await diagnostics.exportText(header: ["Aether downloader diagnostics"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aether-downloader-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
            statusMessage = "Log pronto da condividere."
        } catch {
            statusMessage = "Impossibile esportare il log: \(error.localizedDescription)"
        }
    }
}
