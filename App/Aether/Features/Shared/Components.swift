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
                    Text(subtitle).font(.aetherCaption()).foregroundStyle(.secondary)
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

// MARK: - Poster

struct RatingBadge: View {
    let rating: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: 9))
            Text(rating).font(.system(size: 11, weight: .semibold, design: .rounded))
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

    private var height: CGFloat { width / CGFloat(meta.posterShape.aspectRatio) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RemoteImage(urlString: meta.poster ?? meta.background, width: width, placeholderSeed: meta.name)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5))
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
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
                if let year = meta.releaseInfo, !year.isEmpty {
                    Text(year).font(.aetherCaption()).foregroundStyle(.secondary).lineLimit(1)
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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock().frame(width: posterWidth, height: posterWidth / 0.675)
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
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text(title).font(.aetherTitle(20)).multilineTextAlignment(.center)
            if let message = message {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
            Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
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
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
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
                        .font(.system(.caption, design: .rounded).weight(.semibold))
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
