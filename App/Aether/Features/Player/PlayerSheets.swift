import SwiftUI
import UniformTypeIdentifiers
import AetherCore

/// Audio tracks, subtitles (embedded, from addons, from a file), delay and style.
struct PlayerTracksSheet: View {
    @ObservedObject var model: PlayerViewModel
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Audio")) {
                    if model.audioTracks.count < 2 {
                        Text(model.audioTracks.first.map { "Una sola traccia: \($0.title)" } ?? "Nessuna traccia audio alternativa in questo file.")
                            .foregroundStyle(Color.aetherSecondary)
                    }
                    ForEach(model.audioTracks) { track in
                        Button { model.selectAudio(track) } label: {
                            HStack {
                                Text(track.title)
                                if let language = track.language, !language.isEmpty {
                                    Text(LanguageCodes.displayName(language)).font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                                Spacer()
                                if track.isSelected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section(header: Text("Sottotitoli")) {
                    Button { model.disableSubtitles() } label: {
                        HStack {
                            Text("Disattivati")
                            Spacer()
                            if model.selectedSubtitleID == nil { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .foregroundStyle(.primary)
                    ForEach(model.subtitleOptions) { option in
                        Button { model.selectSubtitle(option) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.title)
                                    if let detail = option.detail, !detail.isEmpty {
                                        Text(detail).font(.caption).foregroundStyle(Color.aetherSecondary)
                                    }
                                }
                                Spacer()
                                if model.selectedSubtitleID == option.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if model.subtitleOptions.isEmpty {
                        Text("Nessun sottotitolo trovato. Installa un addon di sottotitoli o importa un file.")
                            .font(.footnote).foregroundStyle(Color.aetherSecondary)
                    }
                    if let error = model.subtitleError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    }
                    Button { dismiss(); onImport() } label: { Label("Importa da file…", systemImage: "doc.badge.plus") }
                }
                Section(header: Text("Sincronizzazione"), footer: Text("Vale per i sottotitoli esterni. Valori positivi li ritardano.")) {
                    HStack {
                        Button { model.adjustSubtitleDelay(by: -0.5) } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Anticipa di mezzo secondo")
                        Spacer()
                        Text(String(format: "%+.1f s", model.subtitleDelay)).monospacedDigit()
                        Spacer()
                        Button { model.adjustSubtitleDelay(by: 0.5) } label: { Image(systemName: "plus.circle") }
                            .accessibilityLabel("Ritarda di mezzo secondo")
                    }
                    .buttonStyle(.borderless)
                    Button("Azzera") { model.adjustSubtitleDelay(by: -model.subtitleDelay) }
                        .disabled(model.subtitleDelay == 0)
                }
                Section {
                    NavigationLink("Stile dei sottotitoli") { SubtitleStyleView() }
                }
            }
            .navigationTitle("Audio e sottotitoli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

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

/// Alternative sources, shown when the current one fails or the user wants a different quality.
struct PlayerSourcesSheet: View {
    @ObservedObject var model: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.alternatives.isEmpty {
                    Text("Nessuna altra sorgente disponibile per questo titolo.").foregroundStyle(Color.aetherSecondary)
                }
                ForEach(model.alternatives.filter { $0.info.support.isPlayable }) { item in
                    StreamRow(item: item, isBest: false) {
                        dismiss()
                        model.switchSource(to: item)
                    }
                }
            }
            .navigationTitle("Cambia sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What is actually playing: no guessing, only what the addon declared and the engine reports.
struct PlayerInfoSheet: View {
    @ObservedObject var model: PlayerViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Sorgente")) {
                    row("Nome", model.sourceName)
                    if let addon = model.addonSourceName { row("Addon", addon) }
                    if let info = model.currentStreamInfo {
                        row("Qualità dichiarata", info.quality.label)
                        if let codec = info.codec { row("Codec video", codec.label) }
                        if !info.hdr.isEmpty { row("HDR", info.hdr.map { $0.label }.joined(separator: ", ")) }
                        if !info.audio.isEmpty { row("Audio", info.audio.map { $0.label }.joined(separator: ", ")) }
                        if let container = info.container { row("Contenitore", container.uppercased()) }
                        if let size = info.sizeLabel { row("Dimensione", size) }
                    }
                }
                Section(header: Text("Riproduzione")) {
                    row("Motore", model.engine.displayName)
                    if model.snapshot.videoSize != .zero {
                        row("Risoluzione video", "\(Int(model.snapshot.videoSize.width))×\(Int(model.snapshot.videoSize.height))")
                    }
                    if model.snapshot.duration > 0 { row("Durata", Format.duration(model.snapshot.duration)) }
                    row("Velocità", String(format: "%.2g×", Double(model.playbackRate)))
                    row("Rete", network.isOnline ? network.interfaceName + (network.isExpensive ? " (a consumo)" : "") : "Offline")
                    if let route = model.airPlayRoute { row("AirPlay", route) }
                }
                Section(footer: Text("La risoluzione reale può essere inferiore a quella dichiarata dall'addon: gli stream adattivi (HLS) cambiano qualità in base alla rete.")) {
                    EmptyView()
                }
            }
            .navigationTitle("Informazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Casting from the player: AirPlay (system picker) plus Google Cast / DLNA devices.
struct PlayerCastSheet: View {
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
                Section(header: Text("AirPlay"), footer: Text("Per AirPlay il video passa dal sistema: scegli il dispositivo dal pulsante.")) {
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
