import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

private let accent = Color(red: 0.55, green: 0.49, blue: 1.0)
private let background = Color(red: 0.07, green: 0.07, blue: 0.10)

@main
struct AetherWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        DownloadLiveActivity()
    }
}

// MARK: Continue watching

struct ContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// False when the signature did not give the app its shared container: the widget cannot see what the app wrote.
    let hasContainer: Bool
}

struct ContinueProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        let item = WidgetSnapshot.Item(metaID: "tt0", type: "movie", videoID: "tt0", title: "Il tuo film", subtitle: nil, progress: 0.4, thumbnail: nil)
        return ContinueEntry(date: Date(), snapshot: WidgetSnapshot(updated: Date(), items: [item]), hasContainer: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func entry() -> ContinueEntry {
        return ContinueEntry(date: Date(), snapshot: WidgetSnapshot.read(), hasContainer: AppGroup.containerURL != nil)
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aether.widget.continue", provider: ContinueProvider()) { entry in
            ContinueView(entry: entry)
                .containerBackground(for: .widget) { background }
        }
        .configurationDisplayName("Continua a guardare")
        .description("I film e le serie che stavi guardando, un tocco per riprendere.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ContinueView: View {
    let entry: ContinueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let items = entry.snapshot?.items ?? []
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "play.circle.fill").font(.title).foregroundStyle(accent)
                Text(entry.hasContainer ? "Niente da riprendere" : "Apri Aether per attivare il widget")
                    .font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        } else if family == .systemSmall, let first = items.first {
            SmallItem(item: first).widgetURL(WidgetSnapshot.deepLink(first))
        } else {
            HStack(spacing: 10) {
                ForEach(items.prefix(3)) { item in
                    if let url = WidgetSnapshot.deepLink(item) {
                        Link(destination: url) { MediumItem(item: item) }
                    }
                }
            }
        }
    }
}

private func thumbnail(_ item: WidgetSnapshot.Item) -> UIImage? {
    guard let url = WidgetSnapshot.thumbnailURL(item.thumbnail) else { return nil }
    return UIImage(contentsOfFile: url.path)
}

private struct SmallItem: View {
    let item: WidgetSnapshot.Item
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image = thumbnail(item) {
                Image(uiImage: image).resizable().scaledToFill()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            } else {
                background
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.footnote.weight(.bold)).lineLimit(2)
                if let subtitle = item.subtitle { Text(subtitle).font(.caption2).lineLimit(1).opacity(0.8) }
                ProgressView(value: item.progress).tint(accent)
            }
            .foregroundStyle(.white)
            .padding(2)
        }
    }
}

private struct MediumItem: View {
    let item: WidgetSnapshot.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let image = thumbnail(item) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Image(systemName: "film").foregroundStyle(.white.opacity(0.5))
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            ProgressView(value: item.progress).tint(accent)
            Text(item.title).font(.caption2.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Download Live Activity

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockView(state: context.state)
                .activityBackgroundTint(background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").font(.title2).foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.finished ? "Fatto" : "\(Int(context.state.fraction * 100))%").font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.fraction).tint(accent)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
            } compactTrailing: {
                Text("\(Int(context.state.fraction * 100))%").font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(accent)
            }
        }
    }
}

private struct DownloadLockView: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill").foregroundStyle(accent)
                Text(state.finished ? "Download completato" : (state.count > 1 ? "\(state.count) download in corso" : "Download in corso")).font(.footnote.weight(.semibold))
                Spacer()
                if !state.finished { Text("\(Int(state.fraction * 100))%").font(.footnote.monospacedDigit()) }
            }
            Text(state.title).font(.subheadline.weight(.bold)).lineLimit(1)
            if let subtitle = state.subtitle, !subtitle.isEmpty { Text(subtitle).font(.caption).lineLimit(1).opacity(0.75) }
            ProgressView(value: state.finished ? 1 : state.fraction).tint(accent)
        }
        .foregroundStyle(.white)
        .padding()
    }
}
