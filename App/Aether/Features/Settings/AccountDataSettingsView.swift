import SwiftUI
import AetherCore

// MARK: - Account & data

struct AccountDataSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var includeURLs = false
    @State private var includeKeys = false
    @State private var exportURL: URL?
    @State private var showingImporter = false
    /// The backup the viewer picked, read and checked, waiting for the choice of how to restore it.
    @State private var pendingRestore: PickedBackup?
    @State private var resultMessage: String?
    @State private var confirmDelete = false
    @State private var confirmReplace = false
    @State private var applySettings = true

    struct PickedBackup {
        var name: String
        var data: Data
        var preview: BackupPreview
    }

    var body: some View {
        Form {
            Section(header: Text("Account e sincronizzazione")) {
                Label("Nessun account", systemImage: "person.crop.circle.badge.xmark")
                Text("Aether non usa account cloud e non sincronizza tra dispositivi: le API di Stremio e Nuvio non sono pubbliche per client di terze parti. Per spostare i dati usa il backup qui sotto.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            Section(header: Text("Privacy")) {
                Toggle("Registra cronologia e punti di ripresa", isOn: settings.binding(\.privacy.recordHistory))
                    .accessibilityIdentifier("settings.recordHistory")
                Toggle("Consenti rete locale (addon, sorgenti, Cast)", isOn: settings.binding(\.privacy.allowLocalNetwork))
                    .accessibilityIdentifier("settings.allowLocal")
                Toggle("Conserva il log diagnostico (solo su questo dispositivo)", isOn: settings.binding(\.privacy.keepDiagnosticLog))
                Text("Aether non invia nessun dato a server propri: niente analytics, niente crash reporting. Le richieste partono verso gli addon che installi, verso gli indirizzi delle immagini e dei video che questi restituiscono, verso IntroDB per i tempi di «Salta intro» (codice IMDb, stagione ed episodio; si spegne in Riproduzione ▸ Episodi) e, solo se inserisci una tua chiave in Servizi, verso TorBox, TMDB e TheTVDB. Per cercare i sottotitoli gli addon di sottotitoli ricevono il nome del file e, quando è calcolabile, l'impronta (hash) del video.")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            Section(header: Text("Backup e ripristino"), footer: Text("Il backup contiene libreria, cronologia, impostazioni e l'elenco degli addon. Gli indirizzi degli addon e le chiavi dei servizi (TorBox, Real-Debrid, TMDB, TheTVDB, fanart.tv, MDBList, AI) sono personali: inclusi solo se lo scegli, e il file non è cifrato. Ripristinando un backup con le chiavi, i servizi si configurano da soli.")) {
                Toggle("Includi gli indirizzi degli addon", isOn: $includeURLs)
                Toggle("Includi le chiavi dei servizi", isOn: $includeKeys)
                    .accessibilityIdentifier("backup.includeKeys")
                Button("Crea backup…") { Task { await export() } }
                    .accessibilityIdentifier("backup.export")
                if let url = exportURL {
                    ShareLink(item: url) { Label("Condividi \(url.lastPathComponent)", systemImage: "square.and.arrow.up") }
                }
                Button("Ripristina da file…") {
                    resultMessage = nil
                    pendingRestore = nil
                    showingImporter = true
                }
                .accessibilityIdentifier("backup.import")
            }
            if let picked = pendingRestore {
                // Shown in the page itself, not in a dialog: a dialog asked for while the file picker is still closing is dropped by iOS.
                Section(header: Text("Backup scelto"), footer: Text("«Unisci» tiene la versione più recente di ogni elemento. «Sostituisci» cancella prima libreria, cronologia e addon attuali.")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(picked.name).font(.subheadline.weight(.semibold))
                        Text(picked.preview.summary).font(.footnote).foregroundStyle(Color.aetherSecondary)
                        Text("Creato il \(picked.preview.createdAt.formatted(date: .abbreviated, time: .shortened)) con Aether \(picked.preview.appVersion)")
                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("backup.picked")
                    if picked.preview.hasSettings {
                        Toggle("Ripristina anche le impostazioni", isOn: $applySettings)
                            .accessibilityIdentifier("backup.applySettings")
                    }
                    Button("Unisci ai dati attuali") { Task { await restore(.merge) } }
                        .accessibilityIdentifier("backup.merge")
                    Button("Sostituisci tutto…", role: .destructive) { confirmReplace = true }
                        .accessibilityIdentifier("backup.replace")
                        .confirmationDialog("Sostituire i dati attuali?", isPresented: $confirmReplace, titleVisibility: .visible) {
                            Button("Sostituisci tutto", role: .destructive) { Task { await restore(.replace) } }
                            Button("Annulla", role: .cancel) {}
                        } message: {
                            Text("Libreria, cronologia e addon di questo telefono vengono cancellati e rimpiazzati da quelli del backup.")
                        }
                    Button("Annulla") { pendingRestore = nil }
                        .accessibilityIdentifier("backup.cancel")
                }
            }
            if let message = resultMessage {
                Section { Text(message).font(.footnote).accessibilityIdentifier("backup.message") }
            }
            Section(header: Text("Esporta i miei dati"), footer: Text("Il backup è anche l'esportazione completa dei tuoi dati in JSON leggibile.")) {
                EmptyView()
            }
            Section {
                Button("Elimina tutti i dati locali…", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("data.delete")
                    // One dialog per button: several on the same view make iOS drop all but one.
                    .confirmationDialog("Eliminare tutti i dati locali?", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("Elimina tutto", role: .destructive) { Task { await env.deleteAllLocalData(); resultMessage = "Dati locali eliminati." } }
                    } message: {
                        Text("L'operazione non si può annullare.")
                    }
            } footer: {
                Text("Rimuove libreria, cronologia, addon (anche dal Portachiavi), download, cache e impostazioni.")
            }
        }
        .aetherPage()
        .navigationTitle("Account e dati")
        // Any file can be picked: a backup saved or renamed by another app may not be typed as JSON, and the check is the content.
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .plainText, .data, .item]) { result in
            switch result {
            case .success(let url):
                loadBackup(from: url)
            case .failure(let error):
                resultMessage = "Non riesco ad aprire il file: \(error.localizedDescription)"
            }
        }
    }

    private func export() async {
        do {
            exportURL = try await BackupService.makeBackup(env: env, includeAddonURLs: includeURLs, includeServiceKeys: includeKeys)
            resultMessage = (includeURLs || includeKeys) ? "Backup creato con dati personali (indirizzi degli addon o chiavi): conservalo con cura." : "Backup creato."
        } catch {
            resultMessage = "Backup non riuscito: \(error.localizedDescription)"
        }
    }

    /// Reads and checks the picked file now, so a file that is not a backup is said so at once and a good one shows what it holds.
    private func loadBackup(from url: URL) {
        do {
            let data = try BackupFileReader.read(url)
            let backup = try BackupCodec.decode(data)
            pendingRestore = PickedBackup(name: url.lastPathComponent, data: data, preview: BackupPreview(backup))
            resultMessage = nil
        } catch let error as BackupError {
            pendingRestore = nil
            resultMessage = "«\(url.lastPathComponent)»: \(error.message)"
        } catch let error as BackupFileError {
            pendingRestore = nil
            resultMessage = error.message
        } catch {
            pendingRestore = nil
            resultMessage = "Non riesco ad aprire il file: \(error.localizedDescription)"
        }
    }

    private func restore(_ mode: RestoreMode) async {
        guard let picked = pendingRestore else { return }
        pendingRestore = nil
        do {
            let summary = try await BackupService.restore(data: picked.data, env: env, mode: mode, applySettings: applySettings)
            resultMessage = "Ripristino completato: \(summary.entries) titoli salvati, \(summary.progressRecords) punti di visione, \(summary.addonsAdded) addon\(summary.addonsWithoutURL > 0 ? " (\(summary.addonsWithoutURL) senza indirizzo: da reinstallare)" : "")." + (summary.keysRestored.isEmpty ? "" : " Chiavi configurate: \(summary.keysRestored.joined(separator: ", ")).")
        } catch let error as BackupError {
            resultMessage = error.message
        } catch {
            resultMessage = error.localizedDescription
        }
    }
}
