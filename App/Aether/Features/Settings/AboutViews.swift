import SwiftUI
import AVKit
import AetherCore

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var logText = ""
    @State private var logURL: URL?
    @State private var serverIssue: String?

    var body: some View {
        Form {
            Section(header: Text("Server di streaming esterno (sperimentale)"),
                    footer: Text("Aether non contiene un motore torrent. Se gestisci un server compatibile con Stremio (per esempio sul tuo computer), puoi indicarne l'indirizzo: le sorgenti torrent verranno richieste a quel server. Non verificato con hardware reale; spento per impostazione predefinita.")) {
                Toggle("Usa un server esterno", isOn: settings.binding(\.advanced.useExternalStreamingServer))
                TextField("http://192.168.1.10:11470", text: settings.binding(\.advanced.streamingServerURL))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .disabled(!settings.value.advanced.useExternalStreamingServer)
                    .onChange(of: settings.value.advanced.streamingServerURL) { _, _ in validateServer() }
                if let issue = serverIssue, settings.value.advanced.useExternalStreamingServer {
                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                }
            }
            Section(header: Text("Diagnostica"),
                    footer: Text("Il log resta sul dispositivo e non contiene indirizzi completi degli addon né chiavi: host, percorsi e parametri sensibili sono rimossi. Condividilo solo se vuoi.")) {
                Toggle("Registro dettagliato", isOn: settings.binding(\.advanced.verboseLogging))
                Button("Mostra il registro") { Task { logText = await env.diagnostics.exportText() } }
                if !logText.isEmpty {
                    ScrollView { Text(logText).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 260)
                    ShareLink(item: logText) { Label("Condividi il registro", systemImage: "square.and.arrow.up") }
                }
                Button("Cancella il registro", role: .destructive) {
                    Task { await env.diagnostics.clear(); logText = "" }
                }
            }
            Section(header: Text("Rete")) {
                LabeledContent("Connessione", value: env.network.isOnline ? env.network.interfaceName : "Offline")
                if env.network.isExpensive { Text("Connessione a consumo: i download usano la rete mobile solo se consentito.").font(.footnote).foregroundStyle(Color.aetherSecondary) }
            }
        }
        .navigationTitle("Avanzate")
        .onAppear(perform: validateServer)
    }

    private func validateServer() {
        let text = settings.value.advanced.streamingServerURL.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { serverIssue = nil; return }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            serverIssue = "Indirizzo non valido: usa http://indirizzo:porta"
            return
        }
        if CastCompatibility.hostKind(of: url) == .localNetwork && !settings.value.privacy.allowLocalNetwork {
            serverIssue = "È un indirizzo della rete locale: attiva «Consenti rete locale» in Impostazioni ▸ Account e dati."
        } else if CastCompatibility.hostKind(of: url) == .loopback {
            serverIssue = "Un indirizzo «localhost» punta a questo telefono, dove non gira nessun server."
        } else {
            serverIssue = nil
        }
    }
}

// MARK: - Player status

struct PlayerStatusView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        List {
            Section(header: Text("In uso"), footer: Text("Aether riproduce con AVPlayer, il motore di Apple: HLS, MP4, MOV e M4V con codec H.264/HEVC e audio AAC/AC-3/E-AC-3.")) {
                statusRow("AVPlayer (Apple)", "Attivo", color: .green)
                statusRow("Picture in Picture", AVPictureInPictureSupport.isSupported ? "Disponibile" : "Non disponibile su questo dispositivo",
                          color: AVPictureInPictureSupport.isSupported ? .green : .orange)
                statusRow("AirPlay", settings.value.casting.airPlayEnabled ? "Disponibile" : "Disattivato", color: settings.value.casting.airPlayEnabled ? .green : .gray)
            }
            Section(header: Text("Non inclusi"), footer: Text("MKV, AVI, WebM e DASH non sono riproducibili da AVPlayer. Un motore alternativo (MPV, VLC) richiederebbe una libreria LGPL di decine di megabyte: l'architettura lo prevede (protocollo PlaybackEngine), ma non è presente in questa versione. Le sorgenti di quei formati sono marcate come non riproducibili invece di fallire a metà.")) {
                statusRow("MPV / VLC", "Non incluso", color: .gray)
                statusRow("Torrent integrato", "Non incluso", color: .gray)
                statusRow("YouTube (ytId)", "Non riproducibile nel player", color: .gray)
            }
        }
        .navigationTitle("Stato dei player")
    }

    private func statusRow(_ title: String, _ value: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(value).font(.footnote).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

enum AVPictureInPictureSupport {
    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
}

// MARK: - About & licences

struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image("LaunchLogo").resizable().scaledToFit().frame(width: 84, height: 84)
                        .accessibilityHidden(true)
                    Text("Aether").font(.aetherTitle(26))
                    Text("Versione \(version)").font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            Section(header: Text("Cos'è")) {
                Text("Aether è un media center per iPhone che parla il protocollo degli addon Stremio. È un'app indipendente: codice, nome, interfaccia e icona sono originali e non è affiliata a Stremio né a Nuvio.")
                    .font(.footnote)
                Text("Aether non fornisce contenuti: mostra e riproduce ciò che gli addon che installi restituiscono. Gli addon sono servizi di terze parti e la responsabilità di ciò che installi è tua.")
                    .font(.footnote)
            }
            Section(header: Text("Privacy")) {
                Text("Nessun account, nessun analytics, nessun invio di dati a server di Aether. Cronologia, libreria e impostazioni restano sul dispositivo; gli indirizzi degli addon (che possono contenere chiavi) sono nel Portachiavi.")
                    .font(.footnote)
            }
            Section(header: Text("Cosa non c'è")) {
                ForEach(AboutView.notImplemented, id: \.self) { line in
                    Label(line, systemImage: "minus.circle").font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
            }
            Section(header: Text("Componenti di terze parti")) {
                ForEach(AboutView.licenses) { license in
                    NavigationLink(license.name) { LicenseDetailView(license: license) }
                }
            }
        }
        .navigationTitle("Informazioni")
    }

    static let notImplemented = [
        "Account e sincronizzazione cloud (le API di Stremio e Nuvio non sono documentate per terzi)",
        "Plugin di scraper di Nuvio e qualsiasi esecuzione di codice scaricato",
        "Debrid e motore torrent integrato",
        "Trakt / Simkl",
        "Widget e notifiche di nuovi episodi",
        "Motori MPV / VLC (MKV, AVI, WebM)"
    ]

    struct License: Identifiable {
        let name: String
        let id: String
        let summary: String
        let text: String
    }

    static let licenses: [License] = [
        License(name: "Google Cast SDK per iOS", id: "gcast",
                summary: "Binario proprietario di Google, incluso come dipendenza Swift Package.",
                text: "Il Google Cast SDK per iOS è software proprietario di Google LLC, distribuito sotto i Termini di servizio del Google Cast SDK (https://developers.google.com/cast/docs/terms). Il pacchetto Swift che lo espone (googlecast/google-cast-ios-sdk) è rilasciato con licenza Apache-2.0. Aether lo usa esclusivamente per trovare dispositivi Google Cast e inviare loro un indirizzo multimediale tramite il Default Media Receiver."),
        License(name: "Protocollo degli addon Stremio", id: "stremio",
                summary: "Specifica consultata; nessun codice copiato.",
                text: "Aether implementa il protocollo pubblico degli addon descritto in stremio-addon-sdk (MIT). Il codice di stremio-web (GPL-2.0), stremio-core e NuvioMobile (GPL-3.0) è stato studiato solo come riferimento di comportamento: nessun codice, grafica, nome o icona è stato copiato o tradotto."),
        License(name: "Apple frameworks", id: "apple",
                summary: "SwiftUI, AVFoundation, AVKit, Network, Security.",
                text: "Aether usa i framework di sistema di Apple inclusi nell'SDK di iOS secondo i termini del contratto Apple Developer Program.")
    ]
}

struct LicenseDetailView: View {
    let license: AboutView.License

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(license.summary).font(.headline)
                Text(license.text).font(.body)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(license.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
