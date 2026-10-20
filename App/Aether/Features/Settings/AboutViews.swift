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

/// What the player can really do on this device, read from the system when the page opens.
/// Nothing on this page is a promise about a particular file: see the info sheet in the player for that.
struct PlayerStatusView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var device = DeviceVideoCapabilities.conservative
    @State private var mpvReport: PlaybackEngineFactory.MPVReport?

    var body: some View {
        List {
            Section(header: Text("Motori"),
                    footer: Text("AVPlayer è il player di Apple: HLS, MP4, MOV e M4V; è l'unico che può mostrare il vero Dolby Vision (profili 5 e 8.x). MPV (libmpv + FFmpeg, licenza LGPL-3.0) apre MKV, AVI, WebM, TS e altri; il Dolby Vision viene mappato su HDR10 o SDR, non mostrato come Dolby Vision.")) {
                statusRow("AVPlayer (Apple)", "Disponibile", color: .green)
                statusRow("MPV (libmpv)", PlaybackEngineFactory.mpvAvailable ? "Incluso in questa build" : "Non incluso in questa build",
                          color: PlaybackEngineFactory.mpvAvailable ? .green : .gray)
                if let report = mpvReport {
                    statusRow("Versione libmpv", report.initStatus >= 0 ? (report.mpvVersion ?? "sconosciuta") : "non si avvia (\(report.initStatus))",
                              color: report.initStatus >= 0 ? .green : .orange)
                    if let ffmpeg = report.ffmpegVersion, !ffmpeg.isEmpty { statusRow("Versione FFmpeg", ffmpeg, color: .green) }
                }
                statusRow("Picture in Picture", AVPictureInPictureSupport.isSupported ? "Disponibile (solo AVPlayer)" : "Non disponibile su questo dispositivo",
                          color: AVPictureInPictureSupport.isSupported ? .green : .orange)
                statusRow("AirPlay", settings.value.casting.airPlayEnabled ? "Disponibile" : "Disattivato", color: settings.value.casting.airPlayEnabled ? .green : .gray)
            }
            Section(header: Text("Schermo (letto dal sistema)"),
                    footer: Text("Valori forniti da iOS per questo schermo: indicano cosa il dispositivo può mostrare, non cosa contiene un file.")) {
                statusRow("HDR10", device.supportsHDR10 ? "Sì" : "No", color: device.supportsHDR10 ? .green : .gray)
                statusRow("HLG", device.supportsHLG ? "Sì" : "No", color: device.supportsHLG ? .green : .gray)
                statusRow("Dolby Vision", device.supportsDolbyVision ? "Sì" : "No", color: device.supportsDolbyVision ? .green : .gray)
                statusRow("Margine HDR (EDR)", String(format: "%.1f×", device.edrHeadroom), color: device.edrHeadroom > 1 ? .green : .gray)
            }
            Section(header: Text("Decodifica hardware (letta dal sistema)")) {
                statusRow("HEVC / H.265", device.hardwareHEVC ? "Sì" : "No", color: device.hardwareHEVC ? .green : .orange)
                statusRow("AV1", device.hardwareAV1 ? "Sì" : "No (solo software con MPV)", color: device.hardwareAV1 ? .green : .gray)
                statusRow("VP9", device.hardwareVP9 ? "Sì" : "No (solo software con MPV)", color: device.hardwareVP9 ? .green : .gray)
            }
            Section(header: Text("Non inclusi"), footer: Text("Le sorgenti di questi tipi sono marcate come non riproducibili invece di fallire a metà.")) {
                statusRow("DASH (.mpd)", "Non verificato: non abilitato", color: .gray)
                statusRow("Torrent integrato", "Non incluso", color: .gray)
                statusRow("YouTube (ytId)", "Non riproducibile nel player", color: .gray)
            }
        }
        .navigationTitle("Stato dei player")
        .onAppear {
            device = DeviceCapabilitiesReader.current()
            mpvReport = PlaybackEngineFactory.mpvSelfTest()
        }
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
        let label = info?["AetherReleaseLabel"] as? String ?? ""
        return label.isEmpty ? "\(short) (\(build))" : "\(short) \(label) (\(build))"
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
        "Motore torrent integrato (i torrent si risolvono solo con un servizio debrid configurato)",
        "Trakt / Simkl",
        "Widget e notifiche di nuovi episodi",
        "Dolby Vision nativo per MKV (MPV lo mappa su HDR10/SDR)"
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
        License(name: "MPV, FFmpeg e librerie collegate (MPVKit)", id: "mpvkit",
                summary: "LGPL-3.0: motore di riproduzione per MKV, AVI, TS e altri formati.",
                text: "Il motore MPV usa libmpv (LGPL-2.1 o successiva) e FFmpeg (LGPL-2.1 o successiva) tramite il pacchetto MPVKit (https://github.com/mpvkit/MPVKit, LGPL-3.0, prodotto «MPVKit», non quello GPL), che include anche libplacebo, libdovi, libass, dav1d, FreeType, HarfBuzz, FriBidi, uchardet, libbluray, lcms2, MoltenVK, GnuTLS/Nettle/GMP e OpenSSL con le rispettive licenze (LGPL, BSD, MIT, Apache-2.0, ISC, MPL). Le librerie sono collegate staticamente; il codice sorgente completo di Aether è pubblico (licenza MIT) e chiunque può ricompilare l'app con una versione modificata di quelle librerie, come richiesto dalla LGPL. Il testo delle licenze e le versioni esatte sono in docs/03-LICENSES.md del repository."),
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
