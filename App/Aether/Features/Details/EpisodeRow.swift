import SwiftUI
import AetherCore

struct EpisodeRow: View {
    let video: Video
    let isWatched: Bool
    let progress: PlaybackProgress?
    let isFuture: Bool
    let play: () -> Void
    let toggleWatched: () -> Void
    let showDetails: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    RemoteImage(urlString: video.thumbnail, width: 220, placeholderSeed: video.id, systemPlaceholder: "play.rectangle")
                        .frame(width: 120, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                    if let progress = progress, !progress.isCompleted, progress.fraction > 0 {
                        ProgressBar(value: progress.fraction, height: 3).padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let episode = video.episode { Text("\(episode).").foregroundStyle(Color.aetherSecondary) }
                        Text(video.title.isEmpty ? "Episodio" : video.title).lineLimit(2)
                    }
                    .font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(2)
                    }
                    if isFuture, let released = video.released {
                        Text("Esce il \(released.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if isWatched {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Visto")
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
            .opacity(isFuture ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .contextMenu {
            Button(action: showDetails) {
                Label("Trama completa e voti", systemImage: "text.alignleft")
            }
            Button(action: toggleWatched) {
                Label(isWatched ? "Segna come non visto" : "Segna come visto", systemImage: isWatched ? "eye.slash" : "checkmark.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Scegli la sorgente e riproduci")
    }
}
