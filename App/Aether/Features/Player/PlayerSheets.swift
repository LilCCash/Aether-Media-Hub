import SwiftUI
import UniformTypeIdentifiers
import AetherCore

struct PlayerEpisodesSheet: View {
    @ObservedObject var model: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var season: Int?

    var body: some View {
        NavigationStack {
            let seasons = model.meta.seasons
            let selected = season ?? model.currentVideo?.season ?? seasons.first
            List {
                if seasons.count > 1 {
                    Picker("Stagione", selection: Binding(get: { selected ?? 0 }, set: { season = $0 })) {
                        ForEach(seasons, id: \.self) { Text($0 == 0 ? "Speciali" : "Stagione \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                ForEach(selected.map { model.meta.videos(inSeason: $0) } ?? model.meta.videos) { video in
                    Button {
                        dismiss()
                        Task { await model.play(episode: video) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(video.episode.map { "\($0)" } ?? "•")
                                .font(.system(.body, design: .rounded).weight(.bold))
                                .frame(width: 34)
                                .foregroundStyle(video.id == model.currentVideo?.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.title).lineLimit(2)
                                if let released = video.released {
                                    Text(released.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                            Spacer()
                            if video.id == model.currentVideo?.id { Image(systemName: "play.fill").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Episodi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What is actually playing. Three kinds of information are kept apart on purpose:
/// what the addon / release name *claims*, what the decoder *measured*, and what the app *expects* to reach the screen.
struct PlayerInfoSheet: View {
    @ObservedObject var model: PlayerViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Riproduzione")) {
                    row("Motore", model.engine.displayName, id: "info.engine")
                    if model.snapshot.videoSize != .zero {
                        row("Risoluzione video", "\(Int(model.snapshot.videoSize.width))×\(Int(model.snapshot.videoSize.height))")
                    }
                    if model.snapshot.duration > 0 { row("Durata", Format.duration(model.snapshot.duration)) }
                    row("Velocità", String(format: "%.2g×", Double(model.playbackRate)))
                    row("Rete", network.isOnline ? network.interfaceName + (network.isExpensive ? " (a consumo)" : "") : "Offline")
                    if case .audioOnlyBecauseMPV(let route) = model.airPlayAdvice {
                        row("AirPlay", "Solo audio (\(route))", id: "info.airplay")
                    } else if let route = model.airPlayRoute {
                        row("AirPlay", route, id: "info.airplay")
                    }
                }
                conversionSection
                detectedSection
                expectationSection
                Section(header: Text("Sorgente (dichiarato dall'addon o dal nome)")) {
                    row("Nome", model.sourceName)
                    if let addon = model.addonSourceName { row("Addon", addon) }
                    if let info = model.currentStreamInfo {
                        row("Qualità dichiarata", info.quality.label)
                        if let codec = info.codec { row("Codec nel nome", codec.label) }
                        if !info.hdr.isEmpty { row("HDR nel nome", info.hdr.map { $0.label }.joined(separator: ", "), id: "info.hdr.claimed") }
                        if !info.audio.isEmpty { row("Audio nel nome", info.audio.map { $0.label }.joined(separator: ", ")) }
                        if let container = info.container { row("Contenitore", container.uppercased()) }
                        if let size = info.sizeLabel { row("Dimensione", size) }
                    }
                }
                Section(footer: Text("«Rilevato» viene dal decoder del motore in uso; «atteso» è una stima basata sul formato e sullo schermo, non una misura. La risoluzione reale può essere inferiore a quella dichiarata: gli stream adattivi (HLS) cambiano qualità in base alla rete.")) {
                    EmptyView()
                }
            }
            .navigationTitle("Informazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    /// Shown when the file plays through the on-the-fly conversion: what is copied and what is left out.
    @ViewBuilder
    private var conversionSection: some View {
        if let plan = model.conversionPlan {
            Section(header: Text("Conversione al volo"),
                    footer: Text("Il telefono rimette i dati del file MKV in pezzi HLS che AVPlayer legge. Video e audio sono copiati così come sono, non ricodificati: la qualità è quella del file.")) {
                row("Metodo", "MKV → HLS (copia, senza ricodifica)", id: "info.conversion")
                if let audio = plan.audio.first { row("Audio che passa", audio.summary, id: "info.conversion.audio") }
                ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detectedSection: some View {
        if let info = model.mediaInfo {
            Section(header: Text("Formato rilevato dal decoder")) {
                if let container = info.container, !container.isEmpty { row("Contenitore", container.uppercased(), id: "info.container") }
                if let video = info.primaryVideo {
                    row("Video", videoDescription(video), id: "info.video")
                    row("Gamma dinamica", video.verifiedHDRLabel ?? "Non rilevata", id: "info.range")
                    if let primaries = video.primaries, let transfer = video.transfer {
                        row("Colore", "\(primaries) · \(transfer)")
                    }
                    if let dv = video.dolbyVision {
                        row("Dolby Vision", dv.profile == 0 ? "Presente (profilo non leggibile)" : "Profilo \(dv.profileLabel), livello \(dv.level)", id: "info.dv")
                    }
                    if let decodable = video.isDecodable { row("Decodificabile da iOS", decodable ? "Sì" : "No", id: "info.decodable") }
                } else if info.source == .avFoundation {
                    row("Video", "Nessuna traccia video letta")
                }
                if let decoder = info.hardwareDecoder { row("Decodifica", decoder == "software" ? "Software" : "Hardware (\(decoder))") }
                if let active = info.videoOutputActive { row("Uscita video", active ? "Attiva" : "Non attiva", id: "info.vo") }
                ForEach(Array(info.audio.enumerated()), id: \.offset) { index, track in
                    row(index == 0 ? "Audio" : " ", audioDescription(track))
                }
            }
        }
    }

    @ViewBuilder
    private var expectationSection: some View {
        if let plan = model.playbackPlan {
            Section(header: Text("Uscita attesa")) {
                row("Sullo schermo", plan.output.label, id: "info.expected")
                ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                    Label(note.text, systemImage: note.severity == .blocking ? "xmark.octagon.fill" : (note.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                        .font(.footnote)
                        .foregroundStyle(note.severity == .info ? Color.aetherSecondary : Color.orange)
                }
            }
        }
    }

    private func videoDescription(_ video: VideoTrackFacts) -> String {
        var parts: [String] = []
        if let name = video.codecName, !name.isEmpty { parts.append(name.uppercased()) }
        else if let tag = video.codecTag { parts.append(tag) }
        if video.width > 0 && video.height > 0 { parts.append("\(video.width)×\(video.height)") }
        if let fps = video.frameRate, fps > 0 { parts.append(String(format: "%.3g fps", fps)) }
        if let depth = video.bitDepth { parts.append("\(depth) bit") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func audioDescription(_ track: AudioTrackFacts) -> String {
        var parts: [String] = []
        if let name = track.codecName, !name.isEmpty { parts.append(name.uppercased()) }
        else if let tag = track.codecTag { parts.append(tag) }
        if let channels = track.channels, channels > 0 { parts.append("\(channels) canali") }
        if let language = track.language, !language.isEmpty { parts.append(language) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func row(_ title: String, _ value: String, id: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id ?? "info.row")
    }
}

/// Casting from the player: AirPlay (system picker) plus Google Cast / DLNA devices.
struct PlayerCastSheet: View {
    /// Replaces the usual AirPlay footnote when the playing file cannot have its picture sent (MPV).
    var airPlayNote: String?
    let onSelect: (CastDevice) -> Void
    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if casting.session != nil {
                    Section(header: Text("Sessione attiva")) { CastSessionControls() }
                }
                Section(header: Text("AirPlay"), footer: Text(airPlayNote ?? "Per AirPlay il video passa dal sistema: scegli il dispositivo dal pulsante.")) {
                    HStack {
                        Label("Dispositivi AirPlay", systemImage: "airplayvideo")
                        Spacer()
                        AirPlayRoutePicker(activeTint: UIColor(settings.accentColor)).frame(width: 44, height: 44)
                    }
                }
                CastDeviceSections { device in
                    dismiss()
                    onSelect(device)
                }
                if let error = casting.lastError {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Trasmetti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .onAppear { casting.beginDiscovery() }
            .onDisappear { casting.endDiscovery() }
        }
        .presentationDetents([.medium, .large])
    }
}

enum SubtitleFileTypes {
    static var all: [UTType] {
        ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
    }
}
