import SwiftUI
import AetherCore

struct StreamRow: View {
    let item: RankedStream
    let isBest: Bool
    var debrid: DebridRowAppearance? = nil
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment

    private var display: StreamDisplaySettings { settings.value.content.streamDisplay }

    /// The logo of the addon that produced this source, when the viewer asked for it and the addon has one.
    private var addonLogo: URL? {
        guard display.showAddonLogo, let name = item.stream.addonName else { return nil }
        return env.addons.addons.first(where: { $0.displayName == name })?.manifest.logo.flatMap { URL(string: $0) }
    }

    /// The quality as a tile at the start of the row: the first thing an eye looks for in a list of sources.
    private var qualityTile: some View {
        let quality = item.info.quality
        let colors: [Color]
        switch quality {
        case .uhd2160: colors = [Color(red: 0.98, green: 0.78, blue: 0.30), Color(red: 0.85, green: 0.45, blue: 0.10)]
        case .fullHD1080: colors = [Color(red: 0.35, green: 0.62, blue: 1.0), Color(red: 0.20, green: 0.32, blue: 0.85)]
        case .hd720: colors = [Color(red: 0.30, green: 0.80, blue: 0.75), Color(red: 0.12, green: 0.50, blue: 0.55)]
        case .sd, .unknown: colors = [Color.white.opacity(0.28), Color.white.opacity(0.12)]
        }
        return VStack(spacing: 1) {
            if quality == .unknown {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold))
            } else {
                Text(quality.label).font(.system(size: quality == .uhd2160 ? 17 : 13, weight: .heavy, design: AetherTypography.design))
                    .minimumScaleFactor(0.7).lineLimit(1)
            }
            if !item.info.hdr.isEmpty {
                Text(item.info.hdr.contains(.dolbyVision) ? "DV" : "HDR")
                    .font(.system(size: 8, weight: .black, design: AetherTypography.design)).opacity(0.9)
            }
        }
        .foregroundStyle(.white)
        .frame(width: 48, height: 48)
        .background(RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: Corner.control, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
        .opacity(item.info.support.isPlayable ? 1 : 0.45)
        .accessibilityHidden(true)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
            qualityTile
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    if isBest {
                        Label("Consigliata", systemImage: "sparkles")
                            .font(.system(.caption2, design: AetherTypography.design).weight(.bold))
                            .foregroundStyle(settings.accentColor)
                    }
                    Spacer()
                    if let addon = item.stream.addonName {
                        HStack(spacing: 4) {
                            if let logo = addonLogo {
                                AsyncImage(url: logo) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Color.clear
                                }
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .accessibilityHidden(true)
                            }
                            Text(addon).font(.caption2).foregroundStyle(Color.aetherSecondary)
                        }
                    }
                }
                if display.template.isEmpty {
                    Text(item.stream.name ?? "Sorgente")
                        .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let details = item.stream.details, !details.isEmpty {
                        Text(details).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(3)
                    }
                } else {
                    Text(StreamFormatter.line(template: display.template, info: item.info, stream: item.stream))
                        .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                FlowBadges(info: item.info, display: display, stream: item.stream)
                if let debrid = debrid {
                    DebridBadgeRow(appearance: debrid)
                }
                if case .unsupported(let reason) = item.info.support {
                    Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let debrid = debrid, !debrid.torBoxConfigured {
                    Label(DebridUserText.configureHint, systemImage: "key")
                        .font(.caption).foregroundStyle(Color.aetherSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.info.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(Color.aetherSecondary)
                }
            }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hintText)
    }

    private var hintText: String {
        guard item.info.support.isPlayable else { return "Non riproducibile" }
        if let debrid = debrid, debrid.torBoxConfigured {
            switch debrid.badge {
            case .some(DebridCacheBadge.notCached): return "Richiede un download su TorBox, con conferma"
            case .some(DebridCacheBadge.cached): return "Riproduci tramite TorBox: il contenuto è in cache"
            default: return "Controlla TorBox e riproduci questa sorgente"
            }
        }
        return "Riproduci questa sorgente"
    }
}

/// "Torrent" plus the TorBox cache badge. The badge says only what the cache check answered.
struct DebridBadgeRow: View {
    let appearance: DebridRowAppearance

    var body: some View {
        WrappingHStack(spacing: 6) {
            Text("Torrent")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.09), in: Capsule())
            if let badge = appearance.badge {
                // Built like the "Torrent" pill beside it: ONE Text (icon and words inside it) with padding and a capsule, so it
                // is sized by its content the same way. A device showed the earlier `Label` version as a tall capsule holding
                // only the check mark; the cause was not reproduced in a unit test, this removes the `Label` altogether.
                (Text(Image(systemName: badge.systemImage)).foregroundStyle(color(for: badge))
                    + Text(" " + badge.label).foregroundStyle(.primary))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color(for: badge).opacity(0.16), in: Capsule())
                    .accessibilityLabel(badge.accessibilityText)
            }
        }
    }

    private func color(for badge: DebridCacheBadge) -> Color {
        switch badge {
        case .checking: return Color.gray
        case .cached: return Color.green
        case .notCached: return Color.orange
        }
    }
}

/// Why the cache check could not be made, with a retry when trying again can help. The torrent rows show no badge meanwhile.
struct DebridCacheNotice: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stream.debrid.cacheError")
            if let retry = retry {
                Button(action: retry) {
                    Text("Riprova")
                }
                .buttonStyle(.aetherSecondary)
                .accessibilityIdentifier("stream.debrid.cacheRetry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherGlassCard(cornerRadius: Corner.control)
        .padding(.horizontal, Theme.pageMargin)
    }
}

/// Progress of the resolution under the row that was tapped: the step, and for a real download percent, speed and time left.
struct DebridProgressRow: View {
    let state: DebridRowResolution
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = state.determinateFraction {
                ProgressView(value: fraction) {
                    Text(state.message).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(state.message).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let detail = state.detail {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Color.aetherSecondary)
            }
            Button(role: .cancel, action: cancel) {
                Text("Annulla")
            }
            .buttonStyle(.aetherSecondary)
            .accessibilityLabel("Annulla l'attesa di TorBox")
            .accessibilityHint("Smette di attendere. Quello che è già stato aggiunto al tuo account TorBox resta lì.")
            .accessibilityIdentifier("stream.debrid.cancel")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream.debrid.progress")
    }
}

/// A clear Italian message under the row, with a retry when trying again can help.
struct DebridFailureRow: View {
    let failure: DebridRowFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(failure.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if failure.isRetryable {
                Button(action: retry) {
                    Text("Riprova")
                }
                .buttonStyle(.aetherSecondary)
                .accessibilityIdentifier("stream.debrid.retry")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream.debrid.error")
    }
}

/// The video files of a torrent when the right one cannot be found automatically (an episode in a season pack).
struct DebridFileChoiceSheet: View {
    let choice: DebridFileChoice
    let onSelect: (DebridFileCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choice.candidates, id: \.id) { file in
                        Button { onSelect(file) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.subheadline.weight(.medium)).lineLimit(3)
                                if let size = file.size, size > 0 {
                                    Text(Format.bytes(size)).font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("stream.debrid.file.\(file.id)")
                    }
                } header: {
                    Text("File video nel torrent")
                } footer: {
                    Text("Non riesco a capire da solo quale file corrisponde a questo episodio: scegli quello giusto.")
                }
            }
            .navigationTitle("Scegli il file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("stream.debrid.fileChoice")
    }
}

/// Wrapping row of small badges (quality, codec, HDR, audio, languages, size).
struct FlowBadges: View {
    /// The badges of a source: «Stagione completa» first when its name says it is a pack, then the usual ones.
    static func allBadges(info: StreamInfo, display: StreamDisplaySettings, stream: AddonStream?) -> [StreamBadge] {
        var result = StreamFormatter.badges(for: info, settings: display)
        if let stream = stream, let pack = StreamFormatter.packBadge(for: stream, settings: display) { result.insert(pack, at: 0) }
        return result
    }

    let info: StreamInfo
    var display = StreamDisplaySettings()
    var stream: AddonStream?

    var body: some View {
        let badges = Self.allBadges(info: info, display: display, stream: stream)
        let imported = stream.map { CustomBadgePack.badges(for: $0, rules: display.customBadges) } ?? []
        if !badges.isEmpty || !imported.isEmpty {
            WrappingHStack(spacing: 6) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    if badge.kind == .format {
                        // The file format keeps its own look so it reads apart from quality, codec and language.
                        Text(badge.text)
                            .font(.system(size: 11, weight: .bold, design: AetherTypography.design))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                            .accessibilityLabel("Formato \(badge.text)")
                            .accessibilityIdentifier("stream.format")
                    } else {
                        pill(badge)
                    }
                }
                ForEach(imported) { rule in
                    ImportedBadgeView(rule: rule)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(_ badge: StreamBadge) -> some View {
        let text = Text(badge.text).font(.system(size: 11, weight: .semibold, design: AetherTypography.design))
        switch display.badgeStyle {
        case .filled:
            text.padding(.horizontal, 7).padding(.vertical, 3).background(tint(badge.kind).opacity(0.16), in: Capsule())
        case .outline:
            text.padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().strokeBorder(tint(badge.kind).opacity(0.6), lineWidth: 1))
        case .plain:
            text.foregroundStyle(tint(badge.kind))
        }
    }

    private func tint(_ kind: StreamBadgeKind) -> Color {
        switch kind {
        case .quality: return .blue
        case .hdr: return .orange
        case .audio: return .purple
        case .codec: return .teal
        case .language: return .green
        case .size, .format: return .gray
        case .pack: return .pink
        }
    }
}

/// Minimal flow layout (iOS 16+ `Layout`).
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


/// A badge imported from a link: its own picture when it has one (with the name as fallback), else a coloured pill.
struct ImportedBadgeView: View {
    let rule: CustomBadgeRule

    var body: some View {
        if let raw = rule.imageURL, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    pill
                }
            }
            .frame(height: 20)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(rule.label)
        } else {
            pill
        }
    }

    private var pill: some View {
        let accent = rule.colorHex.map { Color(hex: $0) } ?? Color.primary
        return Text(rule.label)
            .font(.system(size: 11, weight: .bold, design: AetherTypography.design))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(accent)
            .background((rule.fillHex.map { Color(hex: $0) } ?? Color.gray).opacity(rule.fillAlpha), in: Capsule())
            .overlay(Capsule().strokeBorder(rule.borderHex.map { Color(hex: $0) } ?? Color.clear, lineWidth: 1))
    }
}

// MARK: - Scaricare più episodi di un pack

/// Legge i file di un torrent con una stagione intera e scarica gli episodi scelti, uno dopo l'altro, dal servizio debrid.
@MainActor
