import SwiftUI
import AVKit
import AetherCore

/// The system AirPlay route picker. Choosing a route makes `AVPlayer` switch to external playback by itself.
struct AirPlayRoutePicker: UIViewRepresentable {
    var tint: UIColor = .label
    var activeTint: UIColor = .systemBlue

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = tint
        view.activeTintColor = activeTint
        view.prioritizesVideoDevices = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "AirPlay"
        view.accessibilityHint = "Apre l'elenco dei dispositivi AirPlay"
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = activeTint
    }
}

/// Devices found by Google Cast and DLNA. In the player `onSelect` sends the current video; in Settings it is nil
/// and the rows are informational.
struct CastDeviceSections: View {
    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var settings: SettingsStore
    var onSelect: ((CastDevice) -> Void)?

    var body: some View {
        section(for: .googleCast,
                empty: "Nessun dispositivo Google Cast trovato. Il telefono e il televisore devono essere nella stessa rete Wi-Fi e il permesso «Rete locale» deve essere attivo (Impostazioni di iOS ▸ Aether).")
        section(for: .dlna,
                empty: settings.value.casting.manualDLNAHosts.isEmpty && !settings.value.casting.ssdpDiscoveryEnabled
                    ? "Nessun renderer DLNA: attiva la scoperta SSDP o aggiungi l'indirizzo del televisore in Impostazioni ▸ Casting."
                    : (casting.dlnaScanNote ?? "Nessun renderer DLNA trovato."))
    }

    @ViewBuilder
    private func section(for target: CastTarget, empty: String) -> some View {
        let devices = casting.devices.filter { $0.target == target }
        Section(header: Text(target.title), footer: footer(for: target, emptyHint: devices.isEmpty ? empty : nil)) {
            if case .unavailable(let reason) = casting.availability(of: target) {
                Label(reason, systemImage: "slash.circle").foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    row(for: device)
                }
                if devices.isEmpty && casting.isScanning {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Ricerca in corso…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for device: CastDevice) -> some View {
        let active = casting.session?.device == device
        if let onSelect = onSelect {
            Button { onSelect(device) } label: { deviceLabel(device, active: active) }
                .accessibilityIdentifier("cast.device.\(device.id)")
        } else {
            deviceLabel(device, active: active)
        }
    }

    private func deviceLabel(_ device: CastDevice, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.target == .googleCast ? "tv.badge.wifi" : "tv")
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                if let detail = device.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if active { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func footer(for target: CastTarget, emptyHint: String?) -> some View {
        if let hint = emptyHint { Text(hint) }
    }
}

/// Transport controls for the active remote session.
struct CastSessionControls: View {
    @EnvironmentObject private var casting: CastCoordinator

    var body: some View {
        if let session = casting.session {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "tv.and.mediabox.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(session.title).font(.headline).lineLimit(1)
                        Text("\(session.device.target.title) · \(session.device.name)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(stateText(session.status))
                    .font(.subheadline)
                    .foregroundStyle(isFailure(session.status.state) ? Color.red : Color.secondary)
                if let duration = session.status.duration, duration > 0 {
                    ProgressView(value: min(1, session.status.position / duration))
                    HStack {
                        Text(Format.duration(session.status.position))
                        Spacer()
                        Text(Format.duration(duration))
                    }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 18) {
                    Button { casting.seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                        .accessibilityLabel("Indietro di 10 secondi")
                    Button {
                        if session.status.state == .playing { casting.pause() } else { casting.play() }
                    } label: {
                        Image(systemName: session.status.state == .playing ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .accessibilityLabel(session.status.state == .playing ? "Pausa" : "Riproduci")
                    Button { casting.seek(by: 10) } label: { Image(systemName: "goforward.10") }
                        .accessibilityLabel("Avanti di 10 secondi")
                    Spacer()
                    Button(role: .destructive) { casting.stop() } label: { Label("Interrompi", systemImage: "stop.fill") }
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
    }

    private func isFailure(_ state: CastPlayState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func stateText(_ status: CastRemoteStatus) -> String {
        switch status.state {
        case .connecting: return "Connessione al dispositivo…"
        case .loading: return "Il televisore sta caricando il video…"
        case .buffering: return "Buffering sul televisore…"
        case .playing: return "In riproduzione sul televisore"
        case .paused: return "In pausa sul televisore"
        case .ended: return "Riproduzione terminata"
        case .failed(let message): return message
        }
    }
}

struct CastView: View {
    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        List {
            if casting.session != nil {
                Section(header: Text("Sessione attiva")) { CastSessionControls() }
            }
            if let error = casting.lastError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            Section(header: Text("AirPlay"),
                    footer: Text("AirPlay è gestito da iOS: scegli lo schermo o l'altoparlante e il video passa lì. I sottotitoli esterni di Aether non vengono mostrati sul televisore; quelli incorporati nel file sì.")) {
                if settings.value.casting.airPlayEnabled {
                    HStack {
                        Label("Scegli un dispositivo AirPlay", systemImage: "airplayvideo")
                        Spacer()
                        AirPlayRoutePicker(activeTint: UIColor(settings.accentColor))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityElement(children: .contain)
                } else {
                    Label("Disattivato nelle impostazioni.", systemImage: "slash.circle").foregroundStyle(.secondary)
                }
            }
            CastDeviceSections(onSelect: nil)
            Section(header: Text("Android TV e Google TV")) {
                ForEach(CastCompatibility.androidTVGuidance, id: \.self) { line in
                    Text(line).font(.footnote)
                }
            }
            Section(header: Text("Cosa viene verificato"),
                    footer: Text("Prima di inviare un video Aether controlla indirizzo, formato e header. Non può sapere se il televisore riuscirà a decodificarlo: se rifiuta il file, lo vedrai qui sopra come errore.")) {
                Text("Per avviare il casting apri un film o un episodio e premi il pulsante Cast nel player.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Casting")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { casting.beginDiscovery() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Cerca di nuovo")
            }
        }
        .onAppear { casting.beginDiscovery() }
        .onDisappear { casting.endDiscovery() }
    }
}
