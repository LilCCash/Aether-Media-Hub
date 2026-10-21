import SwiftUI
import AetherCore

struct AddonsView: View {
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    @State private var showingInstall = false
    @State private var installPrefill: String?
    @State private var toast: String?

    /// Cinemeta is offered until the official one is installed.
    private var showsCinemetaRecommendation: Bool {
        let installed = addons.addons.contains(where: { (addon: InstalledAddon) -> Bool in
            return KnownAddons.isOfficial(manifest: addon.manifest, url: KnownAddons.cinemetaManifestURL) && addon.isOfficial
        })
        return !installed
    }

    /// OpenSubtitles v3 is offered until an addon with its id is installed (whoever installed it).
    private var showsOpenSubtitlesRecommendation: Bool {
        return !RecommendedSubtitleAddon.isInstalled(in: addons.addons)
    }

    var body: some View {
        List {
            if addons.addons.isEmpty {
                Section {
                    EmptyStateView(systemImage: "puzzlepiece.extension", title: "Nessun addon",
                                   message: "Gli addon sono servizi di terze parti che forniscono cataloghi, metadati, sorgenti e sottotitoli. Incolla l'URL del loro manifest.json.",
                                   actionTitle: "Installa un addon", action: { showingInstall = true })
                }
                .listRowBackground(Color.clear)
            } else {
                Section(footer: Text("L'ordine conta: per i metadati vince il primo addon in elenco, e a parità di sorgenti i primi sono preferiti. Trascina per riordinare.")) {
                    ForEach(addons.addons) { addon in
                        NavigationLink {
                            AddonDetailView(addonID: addon.id)
                        } label: {
                            AddonRow(addon: addon)
                        }
                        .accessibilityIdentifier("addon.row.\(addon.manifest.id)")
                    }
                    .onMove { source, destination in
                        Task { await addons.move(from: source, to: destination) }
                    }
                }
            }
            if showsCinemetaRecommendation || showsOpenSubtitlesRecommendation {
                Section(header: Text("Consigliato"), footer: Text("Facoltativi: Aether non installa nulla da solo. Si apre l'anteprima e decidi tu.")) {
                    if showsCinemetaRecommendation {
                        Button {
                            installPrefill = KnownAddons.cinemetaManifestURL.absoluteString
                            showingInstall = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles.rectangle.stack").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Cinemeta").font(.headline)
                                    Text("Metadati ufficiali di Stremio (poster, trame, episodi). Non fornisce sorgenti video.")
                                        .font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("addons.recommended")
                    }
                    if showsOpenSubtitlesRecommendation {
                        Button {
                            installPrefill = RecommendedSubtitleAddon.manifestURL.absoluteString
                            showingInstall = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "captions.bubble").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(RecommendedSubtitleAddon.name).font(.headline)
                                    Text("Sottotitoli da OpenSubtitles: addon ufficiale di Stremio, senza account né chiave. Per cercarli invia al suo server il codice IMDb del titolo e, se disponibili, nome, dimensione e impronta del file video.")
                                        .font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("addons.recommended.opensubtitles")
                    }
                }
            }
            Section(footer: Text("Aether non include né consiglia addon che forniscono contenuti protetti: verifica di avere i diritti sui contenuti che riproduci. Gli addon sono trattati come servizi non fidati.")) {
                if addons.isRefreshing {
                    HStack { ProgressView(); Text("Aggiorno i manifest…").font(.subheadline) }
                }
            }
        }
        .navigationTitle("Addon")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !addons.addons.isEmpty { EditButton() }
                Menu {
                    Button { showingInstall = true } label: { Label("Installa da URL", systemImage: "link.badge.plus") }
                    if !addons.addons.isEmpty {
                        Button { Task { await refreshAll() } } label: { Label("Aggiorna tutti", systemImage: "arrow.clockwise") }
                    }
                } label: { Image(systemName: "plus.circle") }
                .accessibilityLabel("Aggiungi o aggiorna addon")
                .accessibilityIdentifier("addons.add")
            }
        }
        .sheet(isPresented: $showingInstall, onDismiss: { installPrefill = nil }) {
            AddonInstallSheet(prefill: installPrefill)
        }
        .onChange(of: router.pendingAddonInput) { _, input in
            if let input = input {
                installPrefill = input
                showingInstall = true
                router.pendingAddonInput = nil
            }
        }
        .onAppear {
            if let input = router.pendingAddonInput {
                installPrefill = input
                showingInstall = true
                router.pendingAddonInput = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast).font(.footnote.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .aetherGlassCapsule().padding(.bottom, 16).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func refreshAll() async {
        let outcomes = await addons.refreshAll()
        let updated = outcomes.filter { $0.versionChanged }.count
        let failed = outcomes.filter { $0.error != nil }.count
        withAnimation { toast = "Aggiornati: \(updated) · errori: \(failed)" }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        withAnimation { toast = nil }
    }
}

struct AddonRow: View {
    let addon: InstalledAddon

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: addon.manifest.logo, width: 88, contentMode: .fit, placeholderSeed: addon.manifest.id, systemPlaceholder: "puzzlepiece.extension")
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(addon.displayName).font(.system(.body, design: AetherTypography.design).weight(.semibold)).lineLimit(1)
                    Text("v\(addon.manifest.version)").font(.caption2).foregroundStyle(Color.aetherSecondary)
                    if addon.isOfficial { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.blue).accessibilityLabel("Ufficiale") }
                }
                Text(addon.manifest.capabilitySummary.joined(separator: " · ")).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                HStack(spacing: 6) {
                    statusDot
                    Text(statusText).font(.caption2).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                    if addon.isLocalNetwork { Image(systemName: "wifi.router").font(.caption2).foregroundStyle(Color.aetherSecondary).accessibilityLabel("Rete locale") }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusDot: some View {
        Circle().fill(statusColor).frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        if addon.needsReinstall { return .red }
        if !addon.isEnabled { return .gray }
        return addon.lastError == nil ? .green : .orange
    }

    private var statusText: String {
        if addon.needsReinstall { return "Da reinstallare (URL non più disponibile)" }
        if !addon.isEnabled { return "Disattivato" }
        if let error = addon.lastError { return error }
        if let date = addon.lastRefreshAt { return "Connesso · aggiornato \(Format.relativeDate(date))" }
        return "Connesso"
    }
}

// MARK: - Install

struct AddonInstallSheet: View {
    var prefill: String?
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var input = ""
    @State private var isWorking = false
    @State private var preview: AddonInstallPreview?
    @State private var errorMessage: String?
    @State private var errorKind: AddonError?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("URL del manifest"), footer: Text("Esempio: https://v3-cinemeta.strem.io/manifest.json — accetta anche link stremio://")) {
                    TextField("https://…/manifest.json", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("addon.install.field")
                        .onChange(of: input) { _, _ in
                            preview = nil
                            errorMessage = nil
                            errorKind = nil
                        }
                    HStack {
                        Button("Incolla") { if let text = UIPasteboard.general.string { input = text } }
                        Spacer()
                        Button {
                            Task { await verify() }
                        } label: {
                            if isWorking { ProgressView() } else { Text("Verifica") }
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                        .accessibilityIdentifier("addon.install.verify")
                    }
                }

                if let message = errorMessage {
                    Section {
                        Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                            .accessibilityIdentifier("addon.install.error")
                        errorActions
                    }
                }

                if let preview = preview {
                    previewSection(preview)
                }
            }
            .navigationTitle("Installa addon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annulla") { dismiss() } }
            }
            .onAppear {
                if input.isEmpty, let prefill = prefill {
                    input = prefill
                    Task { await verify() }
                } else {
                    focused = true
                }
            }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private var errorActions: some View {
        if let error = errorKind {
            switch error {
            case .blockedURL(.privateAddress), .blockedURL(.localHostname):
                Button("Abilita la rete locale e riprova") {
                    settings.value.privacy.allowLocalNetwork = true
                    Task { await verify() }
                }
                Text("Consenti ad Aether di contattare addon e sorgenti nella tua rete (es. un NAS). Resta disattivato per impostazione predefinita: un addon malevolo potrebbe altrimenti puntare ai dispositivi della tua LAN.")
                    .font(.caption).foregroundStyle(Color.aetherSecondary)
            case .configurationRequired:
                Button("Apri la pagina di configurazione") {
                    if let url = configureURL() { openURL(url) }
                }
                Text("Questo addon va configurato prima dell'uso: completa la configurazione e incolla qui il link di installazione che ti viene fornito.")
                    .font(.caption).foregroundStyle(Color.aetherSecondary)
            default:
                EmptyView()
            }
        }
    }

    private func configureURL() -> URL? {
        guard let url = try? AddonURL.parseInstallInput(input),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = components.path.replacingOccurrences(of: "/manifest.json", with: "/configure")
        components.query = nil
        return components.url
    }

    @ViewBuilder
    private func previewSection(_ preview: AddonInstallPreview) -> some View {
        Section(header: Text("Anteprima")) {
            HStack(spacing: 12) {
                RemoteImage(urlString: preview.manifest.logo, width: 96, contentMode: .fit, placeholderSeed: preview.manifest.id, systemPlaceholder: "puzzlepiece.extension")
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.manifest.name).font(.headline)
                    Text("v\(preview.manifest.version) · \(AddonURL.displayHost(preview.transportURL))").font(.caption).foregroundStyle(Color.aetherSecondary)
                }
            }
            if let description = preview.manifest.description, !description.isEmpty {
                Text(description).font(.subheadline)
            }
            LabeledContent("Tipi", value: preview.manifest.types.map { RequestPlanner.friendlyTypeName($0) }.joined(separator: ", ").ifEmpty("—"))
            LabeledContent("Risorse", value: preview.manifest.capabilitySummary.joined(separator: ", ").ifEmpty("—"))
            LabeledContent("Cataloghi", value: "\(preview.manifest.catalogs.count)")
            if let existing = preview.existing {
                Label("Già installato (\(existing.displayName)): verrà aggiornato mantenendo le tue impostazioni.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
        }
        if !preview.warnings.isEmpty {
            Section(header: Text("Attenzione")) {
                ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(text(for: warning), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                }
            }
        }
        Section {
            Button {
                Task { await install(preview) }
            } label: {
                HStack {
                    Spacer()
                    if isWorking { ProgressView() } else { Text(preview.existing == nil ? "Installa" : "Aggiorna").font(.headline) }
                    Spacer()
                }
            }
            .disabled(isWorking)
            .accessibilityIdentifier("addon.install.confirm")
        }
    }

    private func text(for warning: AddonInstallWarning) -> String {
        switch warning {
        case .unknownAddon:
            return "Addon di terze parti sconosciuto. Aether non ne controlla il contenuto né i server: installa solo addon di cui ti fidi. Potrai rimuoverlo in qualsiasi momento."
        case .p2p:
            return "Dichiara contenuti P2P (es. BitTorrent): collegarti a questi flussi può rivelare il tuo indirizzo IP ad altri utenti."
        case .adult:
            return "Dichiara contenuti per adulti."
        case .localNetwork:
            return "L'addon è nella rete locale (non su Internet)."
        case .sameIdDifferentURL(let name):
            return "Hai già «\(name)» con lo stesso identificativo ma un indirizzo diverso (di solito è una configurazione diversa dello stesso addon)."
        }
    }

    private func verify() async {
        isWorking = true
        errorMessage = nil
        errorKind = nil
        preview = nil
        defer { isWorking = false }
        do {
            preview = try await addons.preview(input)
        } catch {
            let addonError = error as? AddonError
            errorKind = addonError
            errorMessage = addonError?.message ?? error.localizedDescription
        }
    }

    private func install(_ preview: AddonInstallPreview) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await addons.install(preview)
            dismiss()
        } catch {
            errorMessage = (error as? AddonError)?.message ?? error.localizedDescription
        }
    }
}

private extension String {
    func ifEmpty(_ replacement: String) -> String { return isEmpty ? replacement : self }
}

// MARK: - Detail

struct AddonDetailView: View {
    let addonID: UUID
    @EnvironmentObject private var addons: AddonStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmRemove = false
    @State private var isRefreshing = false
    @State private var refreshMessage: String?
    @State private var copied = false

    private var addon: InstalledAddon? { addons.addons.first(where: { $0.id == addonID }) }

    var body: some View {
        Group {
            if let addon = addon {
                List {
                    Section {
                        HStack(spacing: 14) {
                            RemoteImage(urlString: addon.manifest.logo, width: 120, contentMode: .fit, placeholderSeed: addon.manifest.id, systemPlaceholder: "puzzlepiece.extension")
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(addon.displayName).font(.title3.weight(.bold))
                                Text("Versione \(addon.manifest.version)").font(.footnote).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                        if let description = addon.manifest.description, !description.isEmpty { Text(description).font(.subheadline) }
                        Toggle("Attivo", isOn: Binding(get: { addon.isEnabled }, set: { value in Task { await addons.setEnabled(value, id: addon.id) } }))
                            .disabled(addon.needsReinstall)
                            .accessibilityIdentifier("addon.enabled")
                    }
                    Section(header: Text("Stato")) {
                        LabeledContent("Server", value: addon.host)
                        LabeledContent("Installato", value: Format.relativeDate(addon.installedAt))
                        if let date = addon.lastRefreshAt { LabeledContent("Ultimo aggiornamento", value: Format.relativeDate(date)) }
                        if let error = addon.lastError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote) }
                        if addon.needsReinstall {
                            Label("L'indirizzo di questo addon non è più nel Portachiavi (backup ripristinato senza URL). Reinstallalo da Addon → Installa.", systemImage: "key.slash")
                                .foregroundStyle(.red).font(.footnote)
                        }
                        Button {
                            Task { await refresh(addon) }
                        } label: {
                            HStack { Text("Aggiorna manifest"); if isRefreshing { Spacer(); ProgressView() } }
                        }
                        .disabled(isRefreshing || addon.needsReinstall)
                        if let message = refreshMessage { Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary) }
                    }
                    Section(header: Text("Cosa offre")) {
                        LabeledContent("Tipi", value: addon.manifest.types.map { RequestPlanner.friendlyTypeName($0) }.joined(separator: ", "))
                        LabeledContent("Risorse", value: addon.manifest.capabilitySummary.joined(separator: ", "))
                        if addon.manifest.behaviorHints.p2p { Label("Contenuti P2P", systemImage: "network").font(.footnote) }
                        if addon.manifest.behaviorHints.adult { Label("Contenuti per adulti", systemImage: "18.circle").font(.footnote) }
                        if addon.manifest.behaviorHints.configurable { Label("Configurabile", systemImage: "slider.horizontal.3").font(.footnote) }
                    }
                    if !addon.manifest.catalogs.isEmpty {
                        Section(header: Text("Cataloghi"), footer: Text("Disattiva un catalogo per nasconderlo da Home e Scopri. Le ricerche lo useranno comunque se supporta la ricerca.")) {
                            ForEach(addon.manifest.catalogs, id: \.key) { catalog in
                                Toggle(isOn: Binding(
                                    get: { addon.isCatalogVisible(catalog) },
                                    set: { value in Task { await addons.setCatalogVisible(value, catalogKey: catalog.key, id: addon.id) } })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(catalog.name)
                                        Text("\(RequestPlanner.friendlyTypeName(catalog.type))\(catalog.supportsSearch ? " · ricerca" : "")\(catalog.isPlainFeed ? "" : " · richiede filtri")")
                                            .font(.caption).foregroundStyle(Color.aetherSecondary)
                                    }
                                }
                                .disabled(!catalog.isPlainFeed)
                            }
                        }
                    }
                    Section {
                        Button("Rinomina") { newName = addon.nameOverride ?? addon.manifest.name; renaming = true }
                        if addon.manifest.behaviorHints.configurable {
                            Button("Apri la configurazione") {
                                Task {
                                    if let url = await addons.transportURL(for: addon.id),
                                       var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                                        components.path = components.path.replacingOccurrences(of: "/manifest.json", with: "/configure")
                                        components.query = nil
                                        if let configure = components.url { openURL(configure) }
                                    }
                                }
                            }
                        }
                        Button(copied ? "Link copiato" : "Copia il link di installazione") {
                            Task {
                                if let url = await addons.transportURL(for: addon.id) {
                                    UIPasteboard.general.setItems([["public.utf8-plain-text": url.absoluteString]],
                                                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                    copied = true
                                }
                            }
                        }
                        Button("Disinstalla", role: .destructive) { confirmRemove = true }
                            .accessibilityIdentifier("addon.remove")
                    } footer: {
                        Text("Il link di installazione può contenere chiavi personali: trattalo come una password. Resta nel clipboard solo per 2 minuti e non viene condiviso con altri dispositivi.")
                    }
                }
                .navigationTitle(addon.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .alert("Rinomina addon", isPresented: $renaming) {
                    TextField("Nome", text: $newName)
                    Button("Salva") { Task { await addons.rename(newName, id: addon.id) } }
                    Button("Annulla", role: .cancel) {}
                }
                .confirmationDialog("Disinstallare «\(addon.displayName)»?", isPresented: $confirmRemove, titleVisibility: .visible) {
                    Button("Disinstalla", role: .destructive) {
                        Task { await addons.uninstall(id: addon.id); dismiss() }
                    }
                } message: {
                    Text("L'addon e il suo indirizzo salvato verranno rimossi. Libreria e cronologia restano.")
                }
            } else {
                EmptyStateView(systemImage: "puzzlepiece.extension", title: "Addon non trovato")
            }
        }
    }

    private func refresh(_ addon: InstalledAddon) async {
        isRefreshing = true
        defer { isRefreshing = false }
        if let outcome = await addons.refresh(id: addon.id) {
            if let error = outcome.error { refreshMessage = "Aggiornamento non riuscito: \(error)" }
            else if outcome.versionChanged { refreshMessage = "Aggiornato da v\(outcome.previousVersion) a v\(outcome.newVersion ?? "")." }
            else { refreshMessage = "Già aggiornato." }
        }
    }
}
