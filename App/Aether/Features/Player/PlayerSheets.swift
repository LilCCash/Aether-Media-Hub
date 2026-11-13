import SwiftUI
import UniformTypeIdentifiers
import AetherCore

struct PlayerEpisodesSheet: View {
    @ObservedObject var model: PlayerViewModel
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var season: Int?

    var body: some View {
        NavigationStack {
            let seasons = model.meta.seasons
            let selected = season ?? model.currentVideo?.season ?? seasons.first
            List {
                Section {
                    Picker("Cambiando episodio", selection: settings.binding(\.playback.episodeSwitch)) {
                        Text("Fonte automatica").tag(EpisodeSwitchMode.automatic)
                        Text("Scelgo io").tag(EpisodeSwitchMode.askEachTime)
                    }
                    .pickerStyle(.segmented)
                    if model.packEpisodeCount > 1 {
                        Toggle(isOn: settings.binding(\.playback.preferPack)) {
                            Label("Usa prima il pack aperto (\(model.packEpisodeCount) file)", systemImage: "shippingbox.fill")
                        }
                    }
                } footer: {
                    Text(model.packEpisodeCount > 1
                         ? "Gli episodi con l'icona del pack sono già nel file che stai guardando: si aprono subito, senza cercare una fonte. Tieni premuto un episodio per scegliere come aprirlo."
                         : "Con «Scelgo io», toccando un altro episodio si apre l'elenco delle fonti. Tieni premuto un episodio per altre scelte.")
                }
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
                                .font(.system(.body, design: AetherTypography.design).weight(.bold))
                                .frame(width: 34)
                                .foregroundStyle(video.id == model.currentVideo?.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(video.title).lineLimit(2)
                                if let released = video.released {
                                    Text(released.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                            Spacer()
                            if model.isDownloaded(video) {
                                Image(systemName: "arrow.down.circle.fill").font(.footnote).foregroundStyle(Color.green)
                                    .accessibilityLabel("Scaricato")
                            }
                            if model.isInPack(video) {
                                Image(systemName: "shippingbox.fill").font(.footnote).foregroundStyle(Color.aetherSecondary)
                                    .accessibilityLabel("Nel pack")
                            }
                            if video.id == model.currentVideo?.id { Image(systemName: "play.fill").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        if model.isInPack(video) {
                            Button { dismiss(); Task { await model.play(episode: video, via: .pack) } } label: {
                                Label("Apri dal pack", systemImage: "shippingbox")
                            }
                        }
                        Button { dismiss(); Task { await model.play(episode: video, via: .search) } } label: {
                            Label("Cerca la fonte e scegli la migliore", systemImage: "wand.and.stars")
                        }
                        Button { dismiss(); Task { await model.play(episode: video, via: .pick) } } label: {
                            Label("Scegli la fonte…", systemImage: "list.bullet")
                        }
                    }
                }
            }
            .navigationTitle("Episodi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// L'elenco delle fonti di un episodio, per sceglierla a mano (impostazione «Scelgo io», o tenendo premuto un episodio).
struct EpisodeSourcesSheet: View {
    @ObservedObject var model: PlayerViewModel
    let video: Video
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var ranked: [RankedStream] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if model.isInPack(video) {
                    Section {
                        Button {
                            dismiss()
                            Task { await model.play(episode: video, via: .pack) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Dal pack che stai guardando").font(.headline)
                                    Text("Subito, senza cercare: l'episodio è nello stesso file.").font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section(header: Text("Fonti per \(video.episodeLabel ?? "questo episodio")")) {
                    if loading {
                        HStack(spacing: 10) { ProgressView(); Text("Cerco le fonti…").foregroundStyle(Color.aetherSecondary) }
                    } else if ranked.isEmpty {
                        Text("Nessuna fonte trovata per questo episodio.").foregroundStyle(Color.aetherSecondary)
                    }
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, item in
                        Button {
                            dismiss()
                            Task { await model.playEpisode(video, with: item, ranked: ranked) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.stream.name ?? item.stream.addonName ?? "Sorgente").font(.headline).lineLimit(1)
                                    if index == 0 { Text("consigliata").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor) }
                                }
                                if let details = item.stream.details {
                                    Text(details).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(3)
                                }
                                HStack(spacing: 6) {
                                    Text(item.info.badges.prefix(4).joined(separator: " · "))
                                    if let size = item.info.sizeBytes { Text("· " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                                    if let addon = item.stream.addonName { Text("· " + addon) }
                                }
                                .font(.caption2)
                                .foregroundStyle(Color.aetherSecondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(video.episodeLabel ?? "Episodio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } } }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        let result = await env.service.allStreams(type: model.meta.type, videoID: video.id, debrid: env.debrid.streamContext)
        let found = StreamSelector.rank(result.streams, preferences: env.streamPreferences())
        ranked = found.filter { $0.info.support.isPlayable }
        loading = false
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
                liveSection
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

    /// What the engine measures now, refreshed every second while the sheet is open, and why this engine plays the file.
    private var liveSection: some View {
        Section(header: Text("In tempo reale"),
                footer: Text("Misurato dal motore mentre riproduce. I valori che il motore non fornisce non compaiono.")) {
            row("Perché questo motore", engineReason, id: "info.engineReason")
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let stats = model.engine.liveStats()
                VStack(spacing: 10) {
                    if let decoder = stats?.decoder { row("Decodifica", decoder, id: "info.live.decoder") }
                    if let value = stats?.videoBitrate { row("Bitrate video", PlayerInfoSheet.bitrate(value), id: "info.live.video") }
                    if let value = stats?.audioBitrate { row("Bitrate audio", PlayerInfoSheet.bitrate(value)) }
                    if let value = stats?.networkBitrate { row("Velocità della rete", PlayerInfoSheet.bitrate(value)) }
                    if let fps = stats?.displayedFrameRate { row("Fotogrammi mostrati", String(format: "%.3g al secondo", fps)) }
                    if let dropped = stats?.droppedFrames { row("Fotogrammi persi", "\(dropped)", id: "info.live.dropped") }
                    if let buffered = stats?.bufferedSeconds { row("Già in memoria", String(format: "%.0f s", buffered)) }
                    if stats == nil { row("Misure", "Non disponibili per questo motore") }
                }
            }
        }
    }

    private var engineReason: String {
        if let reason = model.engineSwitchReason, !reason.isEmpty { return reason }
        if model.engineChoice != .automatic { return "Scelto nelle impostazioni del player" }
        if let note = model.playbackPlan?.notes.first(where: { $0.severity == .info }) { return note.text }
        return "Scelto in automatico in base al formato del file"
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 { return String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000) }
        return String(format: "%.0f kbit/s", bitsPerSecond / 1000)
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
    @ObservedObject var model: PlayerViewModel
    var airPlayNote: String?
    let onSelect: (CastDevice) -> Void
    let onTrackChange: () -> Void
    @EnvironmentObject private var casting: CastCoordinator
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if casting.session != nil {
                    Section(header: Text("Sessione attiva")) { CastSessionControls() }
                    if let session = casting.session,
                       model.currentStreamInfo?.container?.lowercased() == "mkv",
                       RemuxEngineFactory.isAvailable,
                       (session.device.target == .dlna || settings.value.casting.convertMatroskaForGoogleCast),
                       model.audioTracks.count > 1 || model.subtitleOptions.contains(where: { $0.isEmbedded }) {
                        Section(header: Text("Tracce sul televisore"),
                                footer: Text("Disponibile per MKV convertiti da Aether. I sottotitoli testuali incorporati possono essere preselezionati; PGS/VobSub e sottotitoli esterni non vengono ancora inviati a Google Cast o DLNA. La modifica riavvia il flusso dal punto corrente.")) {
                            if model.audioTracks.count > 1 {
                                Picker("Audio", selection: Binding(
                                    get: { model.audioTracks.first(where: { $0.isSelected })?.id ?? "" },
                                    set: { id in
                                        if let track = model.audioTracks.first(where: { $0.id == id }) {
                                            model.selectAudioForCasting(track)
                                            onTrackChange()
                                        }
                                    })) {
                                    ForEach(model.audioTracks) { track in
                                        Text(track.title).tag(track.id)
                                    }
                                }
                            }
                            let embedded = model.subtitleOptions.filter { $0.isEmbedded }
                            if !embedded.isEmpty {
                                Picker("Sottotitoli", selection: Binding(
                                    get: { embedded.contains(where: { $0.id == model.selectedSubtitleID }) ? model.selectedSubtitleID : nil },
                                    set: { id in
                                        if let id = id, let option = embedded.first(where: { $0.id == id }) {
                                            model.selectSubtitle(option)
                                        } else {
                                            model.disableSubtitles()
                                        }
                                        onTrackChange()
                                    })) {
                                    Text("Disattivati").tag(String?.none)
                                    ForEach(embedded) { option in
                                        Text(option.title).tag(String?.some(option.id))
                                    }
                                }
                            }
                        }
                    }
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
