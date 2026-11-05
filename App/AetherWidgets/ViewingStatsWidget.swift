import SwiftUI
import WidgetKit

struct StatsEntry: TimelineEntry {
    let date: Date
    let stats: WidgetSnapshot.Stats?
    let hasContainer: Bool
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        return StatsEntry(date: Date(), stats: WidgetSnapshot.Stats(totalSeconds: 90_000, weekSeconds: 18_000, days: [1, 3, 2, 0, 4, 2, 5].map { $0 * 1800 },
                                                                     titles: 24, completed: 12, films: 9, episodes: 40, streak: 3), hasContainer: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) { completion(entry()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .after(Date().addingTimeInterval(60 * 60))))
    }

    private func entry() -> StatsEntry {
        return StatsEntry(date: Date(), stats: WidgetSnapshot.read()?.stats, hasContainer: AppGroup.containerURL != nil)
    }
}

struct ViewingStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aether.widget.stats", provider: StatsProvider()) { entry in
            StatsView(entry: entry).containerBackground(for: .widget) {
                LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.32), panelColor], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .configurationDisplayName("Statistiche di visione")
        .description("Quanto hai guardato: ore, ultimi sette giorni e giorni di fila.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private func hours(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min" }
    let h = minutes / 60
    return h >= 100 ? "\(h) h" : "\(h) h \(minutes % 60) min"
}

struct StatsView: View {
    let entry: StatsEntry
    @Environment(\.widgetFamily) private var family
    private let weekdays = ["D", "L", "M", "M", "G", "V", "S"]

    var body: some View {
        if let stats = entry.stats {
            if family == .systemSmall { small(stats) } else { medium(stats) }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").font(.title).foregroundStyle(accent)
                Text(entry.hasContainer ? "Guarda qualcosa per iniziare" : "Il gruppo condiviso non è disponibile").font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        }
    }

    private func small(_ stats: WidgetSnapshot.Stats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Questa settimana", systemImage: "chart.bar.fill").font(.caption2.weight(.bold)).foregroundStyle(accent)
            Text(hours(stats.weekSeconds)).font(.title2.weight(.heavy)).minimumScaleFactor(0.6).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(stats.streak) \(stats.streak == 1 ? "giorno" : "giorni") di fila").font(.caption.weight(.semibold))
            Text("Totale \(hours(stats.totalSeconds))").font(.caption2).opacity(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ stats: WidgetSnapshot.Stats) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Statistiche", systemImage: "chart.bar.fill").font(.caption.weight(.bold)).foregroundStyle(accent)
                Text(hours(stats.weekSeconds)).font(.title.weight(.heavy)).minimumScaleFactor(0.6).lineLimit(1)
                Text("questa settimana").font(.caption2).opacity(0.7)
                Spacer(minLength: 0)
                Text("\(stats.streak) \(stats.streak == 1 ? "giorno" : "giorni") di fila").font(.caption.weight(.semibold))
                Text("\(stats.titles) titoli · \(hours(stats.totalSeconds))").font(.caption2).opacity(0.7).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            bars(stats)
        }
        .foregroundStyle(.white)
    }

    private func bars(_ stats: WidgetSnapshot.Stats) -> some View {
        let peak = max(stats.days.max() ?? 0, 1)
        let todayIndex = Calendar.current.component(.weekday, from: Date()) - 1
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(stats.days.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(index == stats.days.count - 1 ? accent : accent.opacity(0.45))
                        .frame(height: max(4, CGFloat(value / peak) * 62))
                    Text(weekdays[((todayIndex - (stats.days.count - 1 - index)) % 7 + 7) % 7]).font(.system(size: 9, weight: .semibold)).opacity(0.7)
                }
            }
        }
        .frame(width: 130, height: 84)
    }
}
