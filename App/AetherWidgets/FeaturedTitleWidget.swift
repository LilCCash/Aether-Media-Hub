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
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct FeaturedBackground: View {
    let title: WidgetSnapshot.Title?
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let base = Color(hex: title?.backdropHex) ?? panelColor
        ZStack {
            LinearGradient(colors: [base, panelColor], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Small: the poster fills the whole square (no cropped corners inside the margins), darkened toward the bottom.
            if family == .systemSmall, let poster = image(title?.poster) {
                Image(uiImage: poster).resizable().scaledToFill()
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            }
        }
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
        Group { inner }.padding(family == .systemSmall ? 0 : 16)
    }

    @ViewBuilder
    private var inner: some View {
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
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 5) {
                Spacer(minLength: 0)
                if let logo = image(title.logo) {
                    Image(uiImage: logo).resizable().scaledToFit().frame(maxHeight: 36, alignment: .leading)
                } else {
                    Text(title.name).font(.footnote.weight(.heavy)).lineLimit(2).minimumScaleFactor(0.7)
                }
                Label("Apri la scheda", systemImage: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(accentColor)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        case .systemMedium:
            HStack(spacing: 14) {
                poster(title, width: 92)
                details(title, accentColor: accentColor, logoHeight: 54)
            }
        default:
            VStack(spacing: 14) {
                poster(title, width: 150)
                details(title, accentColor: accentColor, logoHeight: 64).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func poster(_ title: WidgetSnapshot.Title, width: CGFloat) -> some View {
        if let poster = image(title.poster) {
            Image(uiImage: poster).resizable().scaledToFill().frame(width: width, height: width * 1.5).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 6)
        }
    }

    private func details(_ title: WidgetSnapshot.Title, accentColor: Color, logoHeight: CGFloat) -> some View {
        VStack(alignment: family == .systemLarge ? .center : .leading, spacing: 8) {
            if let logo = image(title.logo) {
                Image(uiImage: logo).resizable().scaledToFit().frame(maxHeight: logoHeight, alignment: .leading)
            } else {
                Text(title.name).font(family == .systemLarge ? .title2.weight(.heavy) : .title3.weight(.heavy)).lineLimit(3).minimumScaleFactor(0.7)
            }
            if let info = title.info { Text(info).font(.caption).opacity(0.8).lineLimit(1) }
            if family != .systemLarge { Spacer(minLength: 0) }
            // Two real buttons: the title's page, and the watchlist (each opens the app there).
            HStack(spacing: 8) {
                if let url = WidgetSnapshot.deepLink(type: title.type, id: title.id) {
                    Link(destination: url) {
                        Label("Apri la scheda", systemImage: "play.fill").font(.footnote.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 8).background(accentColor, in: Capsule()).foregroundStyle(.black.opacity(0.85))
                    }
                }
                if let watchlist = URL(string: "aether://watchlist") {
                    Link(destination: watchlist) {
                        Label("Watchlist", systemImage: "bookmark.fill").labelStyle(.iconOnly).font(.footnote.weight(.bold))
                            .frame(width: 34, height: 34).background(.white.opacity(0.16), in: Circle())
                    }
                    .accessibilityLabel("Apri la watchlist")
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: family == .systemLarge ? .center : .leading)
    }
}
