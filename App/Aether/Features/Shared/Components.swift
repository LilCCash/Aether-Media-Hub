import SwiftUI
import AetherCore

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.aetherTitle(22))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle = subtitle {
                    Text(subtitle).font(.aetherCaption()).foregroundStyle(Color.aetherSecondary)
                }
            }
            Spacer()
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold))
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }
}

// MARK: - Symmetric card grid

private struct CardGridWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A grid whose cards fill every row symmetrically: at least `minColumns` columns, the same margin on both sides, and cards
/// sized to the column (an adaptive grid with a fixed card width left the spare room of each column on one side).
struct AdaptiveCardGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var minColumns: Int = 3
    var preferredWidth: CGFloat = 130
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 18
    var margin: CGFloat = Theme.pageMargin
    @ViewBuilder var content: (Item, CGFloat) -> Content

    @State private var containerWidth: CGFloat = 390

    /// Columns and card width for a container of `containerWidth` points. Pure, so it is unit-tested.
    static func layout(containerWidth: CGFloat, margin: CGFloat, spacing: CGFloat, minColumns: Int,
                       preferredWidth: CGFloat) -> (columns: Int, cardWidth: CGFloat) {
        let available = max(0, containerWidth - 2 * margin)
        let fitting = Int(((available + spacing) / (preferredWidth + spacing)).rounded(.down))
        let columns = max(max(1, minColumns), fitting)
        let width = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return (columns, max(40, width))
    }

    var body: some View {
        let metrics = AdaptiveCardGrid.layout(containerWidth: containerWidth, margin: margin, spacing: spacing,
                                              minColumns: minColumns, preferredWidth: preferredWidth)
        let columns: [GridItem] = Array(repeating: GridItem(.fixed(metrics.cardWidth), spacing: spacing, alignment: .top),
                                        count: metrics.columns)
        return VStack(spacing: 0) {
            Color.clear
                .frame(height: 0)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: CardGridWidthKey.self, value: proxy.size.width)
                })
            LazyVGrid(columns: columns, alignment: .center, spacing: rowSpacing) {
                ForEach(items) { item in
                    content(item, metrics.cardWidth)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(CardGridWidthKey.self) { width in
            if width > 0, abs(width - containerWidth) > 0.5 { containerWidth = width }
        }
    }
}

// MARK: - Poster

struct RatingBadge: View {
    let rating: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: 9))
            Text(rating).font(.system(size: 11, weight: .semibold, design: AetherTypography.design))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityLabel("Valutazione \(rating)")
    }
}

struct PosterCard: View {
    let meta: MetaItem
    var width: CGFloat = 128
    var showsTitle: Bool = true
    var isInWatchlist: Bool = false
    var progress: Double? = nil
    @Environment(\.aetherStyle) private var style

    private var height: CGFloat { width / CGFloat(meta.posterShape.aspectRatio) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RemoteImage(urlString: meta.poster ?? meta.background, width: width, placeholderSeed: meta.name)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: style.posterRadius, style: .continuous))
                    .aetherCardChrome(cornerRadius: style.posterRadius)
                    .overlay(alignment: .bottom) {
                        if let progress = progress, progress > 0 {
                            ProgressBar(value: progress).padding(8)
                        }
                    }
                HStack {
                    if let rating = meta.imdbRating, !rating.isEmpty { RatingBadge(rating: rating) }
                    Spacer(minLength: 0)
                    if isInWatchlist {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .accessibilityLabel("In watchlist")
                    }
                }
                .padding(6)
            }
            if showsTitle {
                Text(meta.name)
                    .font(.system(.footnote, design: AetherTypography.design).weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
                if let year = meta.releaseInfo, !year.isEmpty {
                    Text(year).font(.aetherCaption()).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                        .frame(width: width, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = [meta.name]
        if let year = meta.releaseInfo, !year.isEmpty { parts.append(year) }
        if let rating = meta.imdbRating, !rating.isEmpty { parts.append("valutazione \(rating)") }
        if isInWatchlist { parts.append("nella watchlist") }
        return parts.joined(separator: ", ")
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule().fill(Color.white)
                    .frame(width: max(height, proxy.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Skeleton

struct ShimmerModifier: ViewModifier {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if settings.animationsEnabled && !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: proxy.size.width * 0.6)
                            .offset(x: phase * proxy.size.width * 1.6)
                            .blendMode(.plusLighter)
                    }
                    .clipped()
                }
            }
            .onAppear {
                guard settings.animationsEnabled && !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Theme.cardCorner

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .shimmer()
    }
}

struct SkeletonRow: View {
    var posterWidth: CGFloat = 128
    var count: Int = 6
    /// Width over height of one card: 0.675 for a poster, 16/9 for a wide card.
    var aspectRatio: CGFloat = 0.675

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock().frame(width: posterWidth, height: posterWidth / aspectRatio)
                        SkeletonBlock(cornerRadius: 4).frame(width: posterWidth * 0.8, height: 10)
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
        .scrollDisabled(true)
        .accessibilityLabel("Caricamento in corso")
    }
}

// MARK: - Messages

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.aetherSecondary)
                .padding(.bottom, 4)
            Text(title).font(.aetherTitle(20)).multilineTextAlignment(.center)
            if let message = message {
                Text(message).font(.subheadline).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            }
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action).buttonStyle(PrimaryActionButtonStyle()).padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct InlineErrorView: View {
    let message: String
    var retryTitle: String = "Riprova"
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary).lineLimit(3)
            Spacer(minLength: 0)
            if let retry = retry {
                Button(retryTitle, action: retry).font(.footnote.weight(.semibold))
            }
        }
        .padding(12)
        .aetherGlassCard(cornerRadius: 14)
        .padding(.horizontal, Theme.pageMargin)
        .accessibilityElement(children: .combine)
    }
}

struct OfflineBanner: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        if !network.isOnline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                Text("Sei offline: mostro i contenuti salvati.").font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .aetherGlassCapsule()
            .padding(.top, 4)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Chips

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? AnyShapeStyle(settings.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct GenreChips: View {
    let genres: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.system(.caption, design: AetherTypography.design).weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
        }
    }
}

// MARK: - Formatting

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%ld:%02ld:%02ld", h, m, s) : String(format: "%ld:%02ld", m, s)
    }

    static func remaining(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min rimasti" }
        return "\(max(1, minutes)) min rimasti"
    }

    static func bytes(_ value: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
