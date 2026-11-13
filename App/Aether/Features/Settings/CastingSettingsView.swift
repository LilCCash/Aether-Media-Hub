import SwiftUI
import AetherCore

// MARK: - Casting settings

struct CastingSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var relay: RelayService
    @EnvironmentObject private var network: NetworkMonitor
    @State private var newHost = ""

    /// Where the relay stands, for the row below. Reads the phone's address each time the page is drawn.
    private var relayStatus: String {
        switch relay.availability {
        case .ready(let interface): return "Pronto (\(interface.address))"
        case .unavailable(let reason): return "Non disponibile: \(reason.message)"
        }
    }

    var body: some View {
        Form {
            Section(header: Text("Protocolli")) {
                Toggle("AirPlay", isOn: settings.binding(\.casting.airPlayEnabled))
                Toggle("Google Cast (Chromecast, Android TV con Cast)", isOn: settings.binding(\.casting.googleCastEnabled))
                Toggle("DLNA / UPnP", isOn: settings.binding(\.casting.dlnaEnabled))
            }
            Section(header: Text("DLNA"), footer: Text("La scoperta automatica (SSDP) usa il multicast UDP e richiede l'entitlement «com.apple.developer.networking.multicast» concesso da Apple: senza, non trova nulla. L'aggiunta manuale funziona sempre.")) {
                Toggle("Scoperta automatica SSDP", isOn: settings.binding(\.casting.ssdpDiscoveryEnabled))
                    .disabled(!settings.value.casting.dlnaEnabled)
                ForEach(settings.value.casting.manualDLNAHosts, id: \.self) { host in
                    Text(host).font(.system(.body, design: .monospaced))
                }
                .onDelete { offsets in settings.value.casting.manualDLNAHosts.remove(atOffsets: offsets) }
                HStack {
                    TextField("192.168.1.50:49152", text: $newHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("Aggiungi") {
                        let trimmed = newHost.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !settings.value.casting.manualDLNAHosts.contains(trimmed) {
                            settings.value.casting.manualDLNAHosts.append(trimmed)
                        }
                        newHost = ""
                    }
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section(header: Text("Ponte sul telefono"),
                    footer: Text("Il ponte si accende solo mentre trasmetti e si spegne da solo. Tieni Aether aperto: con lo schermo bloccato la trasmissione può interrompersi.")) {
                LabeledContent("Ponte sul telefono") {
                    Text(relayStatus).multilineTextAlignment(.trailing).foregroundStyle(Color.aetherSecondary)
                }
                .accessibilityIdentifier("settings.relayStatus")
                .id(network.reconnectToken)
                if settings.value.advanced.sendDirectLinkToTV {
                    Label("Attivo: il televisore riceve la chiave TorBox.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if RemuxEngineFactory.isAvailable {
                Section(header: Text("File MKV"),
                        footer: Text("Molti Chromecast e televisori con Cast rifiutano gli MKV. Con questa opzione il telefono li rimette al volo in HLS (video e audio copiati, non ricodificati) e li passa dal ponte: serve il Wi-Fi e il permesso «Rete locale», parte dopo qualche secondo e consuma batteria. Passa una sola traccia audio, senza sottotitoli incorporati. Se il file ha solo audio DTS/TrueHD o un video non copiabile, Aether lo invia com'è, come prima.")) {
                    Toggle("Converti gli MKV per Google Cast", isOn: settings.binding(\.casting.convertMatroskaForGoogleCast))
                        .accessibilityIdentifier("settings.castConvertMKV")
                }
            }
            Section(header: Text("Riproduzione remota")) {
                Toggle("Riprendi sul telefono quando mi disconnetto", isOn: settings.binding(\.casting.resumeLocallyOnDisconnect))
                Toggle("Consenti sorgenti nella rete locale", isOn: settings.binding(\.privacy.allowLocalNetwork))
            }
            Section {
                NavigationLink("Dispositivi, sessioni e diagnostica") { CastView() }
            }
        }
        .aetherPage()
        .navigationTitle("Casting")
    }
}
