import SwiftUI
import AetherCore

/// «Novità di questa build»: the notes written for the build, once after an update and always in Settings ▸ Informazioni.
struct WhatsNewSheet: View {
    @EnvironmentObject private var extras: ExtrasService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Build \(extras.installedBuild)")) {
                    let lines = extras.whatsNewLines
                    if lines.isEmpty {
                        Text("Nessuna novità annotata per questa build.").foregroundStyle(Color.aetherSecondary)
                    } else {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Label(line, systemImage: "sparkle").labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .navigationTitle("Novità")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
        }
        .onDisappear { extras.markWhatsNewSeen() }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("whatsNew.sheet")
    }
}

/// Settings ▸ Funzioni extra: the optional features, each with its own switch.
struct ExtrasSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var extras: ExtrasService
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openURL) private var openURL
    @State private var showingNotes = false

    var body: some View {
        List {
            Section(header: Text("Aggiornamenti"),
                    footer: Text("Aether legge l'elenco delle build pubblicato su GitHub (la stessa source di SideStore) al massimo ogni sei ore e ti dice se ne esiste una più nuova. Non scarica né installa nulla da solo.")) {
                Toggle("Cerca nuove build", isOn: settings.binding(\.advanced.extras.checkUpdates))
                    .accessibilityIdentifier("extras.checkUpdates")
                Button {
                    Task { await extras.checkForUpdate(force: true) }
                } label: {
                    HStack {
                        Text("Controlla adesso")
                        Spacer()
                        if extras.isChecking { ProgressView() }
                    }
                }
                if let message = extras.checkMessage { Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary) }
                if let release = extras.available {
                    Button { open(sideStore: release) } label: { Label("Apri in SideStore", systemImage: "arrow.down.app") }
                    Button { openURL(release.downloadURL) } label: { Label("Scarica l'IPA con Safari", systemImage: "safari") }
                    if !release.notes.isEmpty {
                        Text(DevbuildFeed.noteLines(release.notes).joined(separator: "\n")).font(.footnote).foregroundStyle(Color.aetherSecondary)
                    }
                }
            }
            Section(header: Text("Novità")) {
                Toggle("Mostra le novità dopo un aggiornamento", isOn: settings.binding(\.advanced.extras.showWhatsNew))
                Button("Novità di questa build") { showingNotes = true }
            }
            Section(header: Text("Riproduzione"),
                    footer: Text("Verso la fine di un episodio l'app prepara già il link del successivo (anche dal servizio debrid), così il passaggio è immediato. Usa un po' di rete in anticipo.")) {
                Toggle("Precarica il prossimo episodio", isOn: settings.binding(\.advanced.extras.prefetchNextLink))
                    .accessibilityIdentifier("extras.prefetch")
            }
            Section(header: Text("Schermata Home, Blocco e download"),
                    footer: Text("Il widget «Continua a guardare» (aggiungilo dalla schermata Home), l'attività dei download sul Blocco schermo e nella Dynamic Island, e l'avviso quando un download finisce. Il widget ha bisogno che la firma di SideStore dia all'app il gruppo condiviso: se resta vuoto, apri Aether e riprova.")) {
                Toggle("Widget «Continua a guardare»", isOn: settings.binding(\.advanced.extras.widget))
                    .accessibilityIdentifier("extras.widget")
                Toggle("Attività dei download (Blocco e Dynamic Island)", isOn: settings.binding(\.advanced.extras.downloadLiveActivity))
                    .accessibilityIdentifier("extras.liveActivity")
                Toggle("Avviso quando un download finisce", isOn: settings.binding(\.advanced.extras.downloadNotifications))
                    .accessibilityIdentifier("extras.downloadNotify")
            }
            Section(header: Text("Guarda insieme"),
                    footer: Text("Dal player, menu ⋯ ▸ «Guarda insieme (SharePlay)» durante una chiamata FaceTime: gli altri vedono il titolo e scelgono la propria fonte, e play, pausa e posizione restano allineati. Serve che la firma di SideStore consenta SharePlay: se non lo consente, l'app lo dice.")) {
                Toggle("Offri «Guarda insieme»", isOn: settings.binding(\.advanced.extras.sharePlay))
                    .accessibilityIdentifier("extras.sharePlay")
            }
            Section(header: Text("Notifiche"),
                    footer: Text("Una notifica il giorno in cui esce un nuovo episodio di una serie che segui su Trakt. Le notifiche si programmano sul telefono per i prossimi 14 giorni: apri Aether ogni tanto per aggiornarle. Serve Trakt collegato.")) {
                Toggle("Avvisami dei nuovi episodi", isOn: settings.binding(\.advanced.extras.episodeNotifications))
                    .disabled(!env.trakt.isConnected)
                    .accessibilityIdentifier("extras.notify")
                if settings.value.advanced.extras.episodeNotifications {
                    Stepper("Ora dell'avviso: \(settings.value.advanced.extras.episodeNotificationHour):00",
                            value: settings.binding(\.advanced.extras.episodeNotificationHour), in: 0...23)
                }
                if !env.trakt.isConnected { Text("Collega prima Trakt.").font(.footnote).foregroundStyle(Color.aetherSecondary) }
            }
            Section(header: Text("Sottotitoli"),
                    footer: Text("Nel pannello dei sottotitoli compare «Traduci in italiano» sui sottotitoli in un'altra lingua. La traduzione la fa il telefono con il motore di Apple (la prima volta iOS può chiedere di scaricare la lingua) e nulla viene mandato ad altri.")) {
                Toggle("Offri la traduzione dei sottotitoli", isOn: settings.binding(\.advanced.extras.translateSubtitles))
                    .accessibilityIdentifier("extras.translate")
            }
            Section(header: Text("Aspetto"),
                    footer: Text("Tinge lo sfondo della scheda del titolo con i colori della locandina.")) {
                Toggle("Colori dalla locandina", isOn: settings.binding(\.advanced.extras.posterTint))
                    .accessibilityIdentifier("extras.posterTint")
            }
        }
        .navigationTitle("Funzioni extra")
        .sheet(isPresented: $showingNotes) { WhatsNewSheet() }
        .onChange(of: settings.value.advanced.extras.episodeNotifications) { _, _ in Task { await extras.refreshEpisodeAlerts() } }
        .onChange(of: settings.value.advanced.extras.episodeNotificationHour) { _, _ in Task { await extras.refreshEpisodeAlerts() } }
    }

    private func open(sideStore release: DevbuildRelease) {
        if let url = DevbuildFeed.sideStoreInstallURL(for: release.downloadURL) {
            openURL(url) { accepted in
                if !accepted { openURL(release.downloadURL) }
            }
        }
    }
}
