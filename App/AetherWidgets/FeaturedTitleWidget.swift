import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// MARK: Choice of the title

struct TitleEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Titolo")
    static var defaultQuery = TitleQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { return DisplayRepresentation(title: "\(name)") }
}

struct TitleQuery: EntityQuery {
    private func pool() -> [TitleEntity] {
        return (WidgetSnapshot.read()?.pool ?? []).map { TitleEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [TitleEntity] {
        return pool().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TitleEntity] { return pool() }
}

struct SelectTitleIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Titolo"
    static var description = IntentDescription("Scegli il titolo che il widget apre. Senza scelta ruota ogni giorno tra i titoli della tua libreria.")

    @Parameter(title: "Titolo")
    var choice: TitleEntity?
}

// MARK: Timeline

struct FeaturedEntry: TimelineEntry {
    let date: Date
    let title: WidgetSnapshot.Title?
    let hasContainer: Bool
}

struct FeaturedProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FeaturedEntry {
        return FeaturedEntry(date: Date(), title: WidgetSnapshot.Title(id: "tt0", type: "movie", name: "Il tuo titolo", info: "Scheda del titolo"), hasContainer: true)
    }

    func snapshot(for configuration: SelectTitleIntent, in context: Context) async -> FeaturedEntry { return entry(configuration) }

    func timeline(for configuration: SelectTitleIntent, in context: Context) async -> Timeline<FeaturedEntry> {
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 5), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(6 * 3600)
        return Timeline(entries: [entry(configuration)], policy: .after(next))
    }

    private func entry(_ configuration: SelectTitleIntent) -> FeaturedEntry {
        let pool = WidgetSnapshot.read()?.pool ?? []
        var chosen: WidgetSnapshot.Title?
        if let id = configuration.choice?.id { chosen = pool.first(where: { $0.id == id }) }
        if chosen == nil, !pool.isEmpty {
            let day = Int(Date().timeIntervalSince1970 / 86_400)
            chosen = pool[day % pool.count]
        }
        return FeaturedEntry(date: Date(), title: chosen, hasContainer: AppGroup.containerURL != nil)
    }
}

// MARK: Widget

struct FeaturedTitleWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.aether.widget.featured", intent: SelectTitleIntent.self, provider: FeaturedProvider()) { entry in
            FeaturedView(entry: entry)
                .containerBackground(for: .widget) { FeaturedBackground(title: entry.title) }
        }
        .configurationDisplayName("Titolo in evidenza")
        .description("Un titolo della tua libreria con locandina e logo. Un tocco apre la sua scheda.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct FeaturedBackground: View {
    let title: WidgetSnapshot.Title?
    var body: some View {
        let base = Color(hex: title?.backdropHex) ?? panelColor
        LinearGradient(colors: [base, panelColor], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private func image(_ path: String?) -> UIImage? {
    guard let url = WidgetSnapshot.fileURL(path) else { return nil }
    return UIImage(contentsOfFile: url.path)
}

struct FeaturedView: View {
    let entry: FeaturedEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let title = entry.title {
            content(title).widgetURL(WidgetSnapshot.deepLink(type: title.type, id: title.id))
        } else {
            VStack(spacing: 6) {
                Image(systemName: "film.stack.fill").font(.title).foregroundStyle(accent)
                Text(entry.hasContainer ? "Aggiungi titoli ai preferiti o alla lista" : "Il gruppo condiviso non è disponibile")
                    .font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                if !entry.hasContainer { Text("Aether ▸ Funzioni extra ▸ Stato del widget").font(.caption2).opacity(0.7).multilineTextAlignment(.center) }
            }
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func content(_ title: WidgetSnapshot.Title) -> some View {
        let accentColor = Color(hex: title.accentHex) ?? accent
        if family == .systemSmall {
            ZStack(alignment: .bottomLeading) {
                if let poster = image(title.poster) {
                    Image(uiImage: poster).resizable().scaledToFill().clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let logo = image(title.logo) {
                        Image(uiImage: logo).resizable().scaledToFit().frame(maxHeight: 34, alignment: .leading)
                    } else {
                        Text(title.name).font(.footnote.weight(.heavy)).lineLimit(2)
                    }
                    Label("Apri", systemImage: "play.fill").font(.caption2.weight(.bold)).foregroundStyle(accentColor)
                }
                .foregroundStyle(.white)
            }
        } else {
            HStack(spacing: 14) {
                if let poster = image(title.poster) {
                    Image(uiImage: poster).resizable().scaledToFill().frame(width: 92).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let logo = image(title.logo) {
                        Image(uiImage: logo).resizable().scaledToFit().frame(maxHeight: 54, alignment: .leading)
                    } else {
                        Text(title.name).font(.title3.weight(.heavy)).lineLimit(3).minimumScaleFactor(0.7)
                    }
                    if let info = title.info { Text(info).font(.caption).opacity(0.8).lineLimit(1) }
                    Spacer(minLength: 0)
                    Label("Apri la scheda", systemImage: "play.fill").font(.footnote.weight(.bold))
                        .padding(.horizontal, 12).padding(.vertical, 7).background(accentColor, in: Capsule()).foregroundStyle(.black.opacity(0.85))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
