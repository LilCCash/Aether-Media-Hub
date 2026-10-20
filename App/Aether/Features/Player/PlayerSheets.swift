import SwiftUI
import UniformTypeIdentifiers
import AetherCore

/// Audio tracks, subtitles (embedded, from addons, from a file), delay and style.
struct PlayerTracksSheet: View {
    @ObservedObject var model: PlayerViewModel
    let onImport: () -> Void
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.dismiss) private var dismiss
    /// Stable code of the language the list is narrowed to, nil for all of them.
    @State private var languageFilter: String?

    var body: some View {
        NavigationStack {
            List {
                audioSection
                subtitleSection
                languageSections
                fileSection
                syncSection
                styleSection
            }
            .navigationTitle("Audio e sottotitoli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Audio

    @ViewBuilder
    private var audioSection: some View {
        Section(header: Text("Audio")) {
            if model.audioTracks.count < 2 {
                Text(model.audioTracks.first.map { "Una sola traccia: \($0.title)" } ?? "Nessuna traccia audio alternativa in questo file.")
                    .foregroundStyle(Color.aetherSecondary)
            }
            ForEach(model.audioTracks) { track in
                audioRow(track)
            }
        }
    }

    private func audioRow(_ track: EngineTrack) -> some View {
        var language: String?
        if let tag = track.language, !tag.isEmpty { language = LanguageCodes.displayName(tag) }
        var spoken = track.title
        if let name = language, !track.title.lowercased().contains(name.lowercased()) { spoken += ", " + name }
        return trackRow(title: track.title, detail: language, label: spoken, isSelected: track.isSelected,
                        identifier: "audio.track.\(track.id)") { model.selectAudio(track) }
    }

    // MARK: Subtitles

    private var embeddedOptions: [SubtitleOption] {
        return model.subtitleOptions.filter { (option: SubtitleOption) -> Bool in return option.isEmbedded }
    }

    private var localOptions: [SubtitleOption] {
        return model.subtitleOptions.filter { (option: SubtitleOption) -> Bool in return option.isLocalFile }
    }

    private var externalCount: Int {
        var count = 0
        for group in model.subtitleGroups { count += group.candidates.count }
        return count
    }

    @ViewBuilder
    private var subtitleSection: some View {
        Section(header: Text("Sottotitoli")) {
            trackRow(title: "Disattivati", detail: nil, label: "Sottotitoli disattivati", isSelected: model.selectedSubtitleID == nil,
                     identifier: "subtitle.off") { model.disableSubtitles() }
            ForEach(Array(embeddedOptions.enumerated()), id: \.element.id) { index, option in
                trackRow(title: option.title, detail: option.detail, label: "\(option.title), incorporato",
                         isSelected: model.selectedSubtitleID == option.id,
                         identifier: "subtitle.option.embedded.\(index)") { model.selectSubtitle(option) }
            }
            if model.subtitleGroups.count > 1 { filterRow }
            statusRows
        }
    }

    /// One chip per language, when there is more than one to choose from.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Tutte", isSelected: activeFilter == nil) { languageFilter = nil }
                    .accessibilityHint("Mostra i sottotitoli di tutte le lingue")
                    .accessibilityIdentifier("subtitle.filter.all")
                ForEach(model.subtitleGroups) { group in
                    FilterChip(title: SubtitleRowText.groupName(group), isSelected: activeFilter == group.language) {
                        languageFilter = group.language
                    }
                    .accessibilityHint("Mostra solo i sottotitoli in questa lingua")
                    .accessibilityIdentifier("subtitle.filter.\(group.language)")
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 6)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    /// The chip that is on, or nil when none is (also when the language it stood for is gone after a refresh).
    private var activeFilter: String? {
        guard let filter = languageFilter else { return nil }
        let exists = model.subtitleGroups.contains(where: { (group: SubtitleLanguageGroup) -> Bool in
            return group.language == filter
        })
        return exists ? filter : nil
    }

    private var visibleGroups: [SubtitleLanguageGroup] {
        guard let filter = activeFilter else { return model.subtitleGroups }
        return model.subtitleGroups.filter { (group: SubtitleLanguageGroup) -> Bool in
            return group.language == filter
        }
    }

    @ViewBuilder
    private var languageSections: some View {
        ForEach(visibleGroups) { group in
            Section {
                groupRows(group)
            } header: {
                Text(SubtitleRowText.groupName(group))
                    .textCase(nil)
                    .accessibilityIdentifier("subtitle.group.\(group.language)")
            }
        }
    }

    private func groupRows(_ group: SubtitleLanguageGroup) -> some View {
        let rows = SubtitleRowText.rows(for: group)
        return ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
            candidateRow(candidate, text: rows[index], index: index)
        }
    }

    private func candidateRow(_ candidate: SubtitleCandidate, text: SubtitleRowText, index: Int) -> some View {
        let option = SubtitleOption.addon(candidate)
        return trackRow(title: text.title, detail: text.detail, label: text.accessibilityLabel,
                        isSelected: model.selectedSubtitleID == option.id,
                        identifier: "subtitle.option.\(candidate.language).\(index)") { model.selectSubtitle(option) }
    }

    // MARK: Loading, errors and empty states

    @ViewBuilder
    private var statusRows: some View {
        if model.subtitleListPhase == .loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Cerco i sottotitoli…").font(.footnote).foregroundStyle(Color.aetherSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("subtitle.loading")
        }
        if let message = model.subtitleError {
            InlineErrorView(message: message, retry: { model.retrySubtitle() })
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("subtitle.error")
        }
        emptyState
    }

    private var emptyStateKind: SubtitleEmptyState? {
        return SubtitleEmptyState.resolve(phase: model.subtitleListPhase, hasProvider: model.hasSubtitleProvider,
                                          externalCount: externalCount)
    }

    private var nothingFoundTitle: String {
        if embeddedOptions.isEmpty { return "Nessun sottotitolo trovato per questo titolo" }
        return "Nessun altro sottotitolo trovato per questo titolo"
    }

    private var nothingFoundMessage: String {
        if network.isOnline { return "Gli addon installati non hanno sottotitoli per questo video. Puoi importare un file." }
        return "Sei offline: gli addon non sono raggiungibili. Puoi importare un file."
    }

    @ViewBuilder
    private var emptyState: some View {
        if let kind = emptyStateKind {
            switch kind {
            case .noProvider:
                EmptyStateView(systemImage: "captions.bubble",
                               title: "Nessun addon di sottotitoli installato",
                               message: "Installa un addon di sottotitoli da Altro → Addon (OpenSubtitles v3 è tra i consigliati) per cercarli qui. Puoi sempre importare un file.")
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("subtitle.empty.noAddons")
            case .nothingFound:
                EmptyStateView(systemImage: "text.bubble", title: nothingFoundTitle, message: nothingFoundMessage)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("subtitle.empty.none")
            }
        }
    }

    // MARK: Files and synchronisation

    @ViewBuilder
    private var fileSection: some View {
        Section(header: Text("Da file")) {
            ForEach(Array(localOptions.enumerated()), id: \.element.id) { index, option in
                trackRow(title: option.title, detail: option.detail, label: "\(option.title), file importato",
                         isSelected: model.selectedSubtitleID == option.id,
                         identifier: "subtitle.local.\(index)") { model.selectSubtitle(option) }
            }
            Button { dismiss(); onImport() } label: { Label("Importa da file…", systemImage: "doc.badge.plus") }
                .accessibilityIdentifier("subtitle.import")
        }
    }

    private var delayFooter: String {
        if model.engine.kind == .mpv {
            return "Vale per tutti i sottotitoli. Valori positivi li ritardano."
        }
        return "Vale per i sottotitoli scaricati e importati: AVPlayer non permette di ritardare quelli incorporati. Valori positivi li ritardano."
    }

    @ViewBuilder
    private var syncSection: some View {
        Section(header: Text("Sincronizzazione"), footer: Text(delayFooter)) {
            HStack {
                Button { model.adjustSubtitleDelay(by: -0.5) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Anticipa di mezzo secondo")
                    .accessibilityIdentifier("subtitle.delay.earlier")
                Spacer()
                Text(String(format: "%+.1f s", model.subtitleDelay))
                    .monospacedDigit()
                    .accessibilityLabel("Ritardo dei sottotitoli")
                    .accessibilityValue(String(format: "%+.1f secondi", model.subtitleDelay))
                    .accessibilityIdentifier("subtitle.delay.value")
                Spacer()
                Button { model.adjustSubtitleDelay(by: 0.5) } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("Ritarda di mezzo secondo")
                    .accessibilityIdentifier("subtitle.delay.later")
            }
            .buttonStyle(.borderless)
            Button("Azzera") { model.adjustSubtitleDelay(by: -model.subtitleDelay) }
                .disabled(model.subtitleDelay == 0)
                .accessibilityIdentifier("subtitle.delay.reset")
        }
    }

    @ViewBuilder
    private var styleSection: some View {
        Section {
            NavigationLink("Stile dei sottotitoli") { SubtitleStyleView() }
        }
    }

    // MARK: Rows

    private var checkmark: some View {
        Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
    }

    /// A selectable row: wraps at large text sizes and tells VoiceOver which entry is on.
    private func trackRow(title: String, detail: String?, label: String, isSelected: Bool, identifier: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail = detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected { checkmark }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
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
                    if let route = model.airPlayRoute { row("AirPlay", route) }
                }
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
