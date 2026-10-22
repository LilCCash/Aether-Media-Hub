import SwiftUI
import AetherCore

/// The three panels that open on the right edge of the player. They are not sheets: the picture stays behind, dimmed, and the
/// panel takes about 40% of the width, so the viewer keeps seeing what a change does (a subtitle, a delay) while making it.
enum PlayerPanel: String, Identifiable, Equatable {
    case subtitles, audio, sources

    var id: String { return rawValue }

    var title: String {
        switch self {
        case .subtitles: return "Sottotitoli"
        case .audio: return "Audio"
        case .sources: return "Sorgenti"
        }
    }
}

struct PlayerPanelHost: View {
    let panel: PlayerPanel
    @ObservedObject var model: PlayerViewModel
    let onImportSubtitle: () -> Void
    let close: () -> Void
    /// The current subtitle, laid out for the part of the screen the panel leaves free: drawn over the dimming, beside the panel, so
    /// the effect of a delay or a style can be judged while the panel is open.
    let subtitleLayer: (CGSize) -> AnyView

    /// Two fifths of the screen, never narrower than a readable list nor wider than a comfortable one, and never the whole screen.
    static func panelWidth(screenWidth: CGFloat) -> CGFloat {
        let wanted = min(max(screenWidth * 0.4, 340), 520)
        return min(wanted, screenWidth * 0.92)
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let width = PlayerPanelHost.panelWidth(screenWidth: proxy.size.width)
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.5)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                    .accessibilityElement()
                    .accessibilityLabel("Chiudi il pannello")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("player.panel.scrim")
                let free = CGSize(width: max(0, proxy.size.width - width - insets.trailing), height: proxy.size.height)
                subtitleLayer(free)
                    .frame(width: free.width, height: free.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Color.white.opacity(0.14))
                    content
                }
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)
                .padding(.trailing, insets.trailing)
                .frame(width: width + insets.trailing)
                .frame(maxHeight: .infinity)
                .background(
                    Rectangle().fill(.regularMaterial)
                        .overlay(Color.black.opacity(0.35))
                        .ignoresSafeArea()
                )
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityIdentifier("player.panel.\(panel.rawValue)")
                .transition(.move(edge: .trailing))
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .tint(.white)
        .accessibilityAction(.escape, close)
    }

    private var header: some View {
        HStack {
            Text(panel.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.14), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chiudi il pannello")
            .accessibilityIdentifier("player.panel.close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .subtitles:
            PlayerSubtitlesPanel(model: model, onImport: { close(); onImportSubtitle() })
        case .audio:
            PlayerAudioPanel(model: model)
        case .sources:
            PlayerSourcesPanel(model: model, onSelect: { item in close(); model.switchSource(to: item) })
        }
    }
}

// MARK: - Rows

/// A selectable line of a panel: wraps at large text sizes and tells VoiceOver which entry is on.
private struct PanelRow: View {
    let title: String
    var detail: String?
    let label: String
    let isSelected: Bool
    let identifier: String
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.playerAccent) private var playerAccent

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).multilineTextAlignment(.leading)
                    if let detail = detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Color.white.opacity(0.65)).multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle((playerAccent ?? settings.accentColor)).accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? Color.white.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A line of the language column.
private struct PanelFilterRow: View {
    let title: String
    var count: Int?
    let isSelected: Bool
    let identifier: String
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.playerAccent) private var playerAccent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let count = count {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isSelected ? AnyShapeStyle((playerAccent ?? settings.accentColor).opacity(0.85)) : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Subtitles

/// Subtitles in two columns: the languages on the left, the subtitles of the chosen language on the right. Under the list sit the
/// delay, the file import and the style, which are used while the picture is still visible.
struct PlayerSubtitlesPanel: View {
    @ObservedObject var model: PlayerViewModel
    let onImport: () -> Void
    @EnvironmentObject private var network: NetworkMonitor
    /// Stable code of the language the list is narrowed to, nil for all of them.
    @State private var languageFilter: String?
    @State private var showingStyle = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // At the largest text sizes the controls alone fill the panel: the whole panel scrolls and the two lists keep a height
                // of their own (each scrolls too).
                ScrollView {
                    VStack(spacing: 0) {
                        columns.frame(height: 320)
                        Divider().overlay(Color.white.opacity(0.14))
                        footer
                    }
                }
            } else {
                VStack(spacing: 0) {
                    columns
                    Divider().overlay(Color.white.opacity(0.14))
                    footer
                }
            }
        }
        .sheet(isPresented: $showingStyle) { SubtitleStyleSheet() }
    }

    private var columns: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                languageColumn
                    .frame(width: proxy.size.width * 0.34)
                Divider().overlay(Color.white.opacity(0.14))
                listColumn
            }
        }
    }

    // MARK: Languages

    private var languageColumn: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if model.subtitleGroups.count > 1 {
                    PanelFilterRow(title: "Tutte", count: externalCount, isSelected: activeFilter == nil,
                                   identifier: "subtitle.filter.all") { languageFilter = nil }
                        .accessibilityHint("Mostra i sottotitoli di tutte le lingue")
                    ForEach(model.subtitleGroups) { group in
                        PanelFilterRow(title: SubtitleRowText.groupName(group), count: group.candidates.count,
                                       isSelected: activeFilter == group.language, identifier: "subtitle.filter.\(group.language)") {
                            languageFilter = group.language
                        }
                        .accessibilityHint("Mostra solo i sottotitoli in questa lingua")
                    }
                } else if let only = model.subtitleGroups.first {
                    PanelFilterRow(title: SubtitleRowText.groupName(only), count: only.candidates.count, isSelected: true,
                                   identifier: "subtitle.language.single") {}
                } else {
                    Text("Nessuna lingua")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.6))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
    }

    /// The language that is on, or nil when none is (also when the language it stood for is gone after a refresh).
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

    // MARK: The list

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

    private var listColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PanelRow(title: "Disattivati", detail: nil, label: "Sottotitoli disattivati", isSelected: model.selectedSubtitleID == nil,
                         identifier: "subtitle.off") { model.disableSubtitles() }
                ForEach(Array(embeddedOptions.enumerated()), id: \.element.id) { index, option in
                    PanelRow(title: option.title, detail: option.detail, label: "\(option.title), incorporato",
                             isSelected: model.selectedSubtitleID == option.id,
                             identifier: "subtitle.option.embedded.\(index)") { model.selectSubtitle(option) }
                }
                statusRows
                ForEach(visibleGroups) { group in
                    groupHeader(group)
                    let rows = SubtitleRowText.rows(for: group)
                    ForEach(Array(group.candidates.enumerated()), id: \.element.id) { index, candidate in
                        let option = SubtitleOption.addon(candidate)
                        PanelRow(title: rows[index].title, detail: rows[index].detail, label: rows[index].accessibilityLabel,
                                 isSelected: model.selectedSubtitleID == option.id,
                                 identifier: "subtitle.option.\(candidate.language).\(index)") { model.selectSubtitle(option) }
                    }
                }
                ForEach(Array(localOptions.enumerated()), id: \.element.id) { index, option in
                    PanelRow(title: option.title, detail: option.detail, label: "\(option.title), file importato",
                             isSelected: model.selectedSubtitleID == option.id,
                             identifier: "subtitle.local.\(index)") { model.selectSubtitle(option) }
                }
            }
        }
    }

    private func groupHeader(_ group: SubtitleLanguageGroup) -> some View {
        Text(SubtitleRowText.groupName(group))
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.65))
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("subtitle.group.\(group.language)")
    }

    // MARK: Loading, errors and empty states

    @ViewBuilder
    private var statusRows: some View {
        if model.subtitleListPhase == .loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Cerco i sottotitoli…").font(.footnote).foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(14)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("subtitle.loading")
        }
        if let message = model.subtitleError {
            // Not InlineErrorView: that one is a full-width row and leaves a few characters per line in this column.
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.retrySubtitle() } label: {
                    Text("Riprova")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 34)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 8)
            .accessibilityElement(children: .combine)
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
                    .accessibilityIdentifier("subtitle.empty.noAddons")
            case .nothingFound:
                EmptyStateView(systemImage: "text.bubble", title: nothingFoundTitle, message: nothingFoundMessage)
                    .accessibilityIdentifier("subtitle.empty.none")
            }
        }
    }

    // MARK: Delay, file and style

    private var delayNote: String {
        if model.engine.kind == .mpv { return "Vale per tutti i sottotitoli. Valori positivi li ritardano." }
        return "Vale per i sottotitoli scaricati e importati: AVPlayer non permette di ritardare quelli incorporati. Valori positivi li ritardano."
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Button { model.adjustSubtitleDelay(by: -0.5) } label: {
                    Image(systemName: "minus.circle").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .accessibilityLabel("Anticipa di mezzo secondo")
                    .accessibilityIdentifier("subtitle.delay.earlier")
                Spacer()
                Text(String(format: "%+.1f s", model.subtitleDelay))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .accessibilityLabel("Ritardo dei sottotitoli")
                    .accessibilityValue(String(format: "%+.1f secondi", model.subtitleDelay))
                    .accessibilityIdentifier("subtitle.delay.value")
                Spacer()
                Button { model.adjustSubtitleDelay(by: 0.5) } label: {
                    Image(systemName: "plus.circle").font(.title3).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .accessibilityLabel("Ritarda di mezzo secondo")
                    .accessibilityIdentifier("subtitle.delay.later")
            }
            .buttonStyle(.borderless)
            HStack(spacing: 8) {
                footerButton("Azzera", "arrow.counterclockwise", id: "subtitle.delay.reset", enabled: model.subtitleDelay != 0) {
                    model.adjustSubtitleDelay(by: -model.subtitleDelay)
                }
                footerButton("Importa", "doc.badge.plus", id: "subtitle.import", enabled: true, action: onImport)
                footerButton("Stile", "textformat.size", id: "subtitle.style", enabled: true) { showingStyle = true }
            }
            Text(delayNote)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private func footerButton(_ title: String, _ symbol: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Color.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityIdentifier(id)
    }
}

/// The subtitle style form, opened from the panel.
private struct SubtitleStyleSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SubtitleStyleView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Audio

struct PlayerAudioPanel: View {
    @ObservedObject var model: PlayerViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.audioTracks.count < 2 {
                    Text(model.audioTracks.first.map { "Una sola traccia: \($0.title)" } ?? "Nessuna traccia audio alternativa in questo file.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(14)
                        .accessibilityIdentifier("audio.single")
                }
                ForEach(model.audioTracks) { track in
                    row(track)
                }
            }
        }
    }

    private func row(_ track: EngineTrack) -> some View {
        var language: String?
        if let tag = track.language, !tag.isEmpty { language = LanguageCodes.displayName(tag) }
        var spoken = track.title
        if let name = language, !track.title.lowercased().contains(name.lowercased()) { spoken += ", " + name }
        return PanelRow(title: track.title, detail: language, label: spoken, isSelected: track.isSelected,
                        identifier: "audio.track.\(track.id)") { model.selectAudio(track) }
    }
}

// MARK: - Sources

/// Other sources for the same title, narrowed by addon with the same chips as the source list, in the order the list uses.
struct PlayerSourcesPanel: View {
    @ObservedObject var model: PlayerViewModel
    let onSelect: (RankedStream) -> Void
    @State private var addonFilter: String?

    private var playable: [RankedStream] {
        return model.alternatives.filter { (item: RankedStream) -> Bool in return item.info.support.isPlayable }
    }

    private var addonNames: [String] {
        var names: [String] = []
        for item in playable {
            if let name = item.stream.addonName, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The filter that is on, or nil when its addon no longer has a source left.
    private var activeFilter: String? {
        guard let filter = addonFilter, addonNames.contains(filter) else { return nil }
        return filter
    }

    private var visible: [RankedStream] {
        guard let filter = activeFilter else { return playable }
        return playable.filter { (item: RankedStream) -> Bool in return item.stream.addonName == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            if addonNames.count > 1 { chips }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    nowPlaying
                    if playable.isEmpty {
                        Text("Nessuna altra sorgente disponibile per questo titolo.")
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.7))
                            .accessibilityIdentifier("sources.none")
                    }
                    ForEach(visible) { item in
                        StreamRow(item: item, isBest: false) { onSelect(item) }
                            .padding(12)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(12)
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Tutti", isSelected: activeFilter == nil) { addonFilter = nil }
                    .accessibilityIdentifier("sources.filter.all")
                ForEach(addonNames, id: \.self) { name in
                    FilterChip(title: name, isSelected: activeFilter == name) { addonFilter = name }
                        .accessibilityIdentifier("sources.filter.\(name)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("In riproduzione").font(.caption2.weight(.bold)).foregroundStyle(Color.white.opacity(0.6))
            Text(model.sourceName).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let addon = model.addonSourceName {
                Text(addon).font(.caption).foregroundStyle(Color.white.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sources.current")
    }
}
