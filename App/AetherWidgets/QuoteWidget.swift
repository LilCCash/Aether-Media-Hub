import AppIntents
import SwiftUI
import WidgetKit

private let offsetKey = "aether.widget.quoteOffset"

/// ◀ / ▶ on the widget: moves to the previous or the next line. Runs in the widget itself (no app, no shared container needed).
struct QuoteStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia citazione"
    static var isDiscoverable = false

    @Parameter(title: "Passo")
    var step: Int

    init() { step = 1 }
    init(step: Int) { self.step = step }

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: offsetKey) + step, forKey: offsetKey)
        return .result()
    }
}

struct QuoteEntry: TimelineEntry {
    let date: Date
    let quote: FilmQuote
}

struct QuoteProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuoteEntry { return QuoteEntry(date: Date(), quote: Quotes.all[0]) }

    func getSnapshot(in context: Context, completion: @escaping (QuoteEntry) -> Void) { completion(entry(at: Date())) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuoteEntry>) -> Void) {
        let now = Date()
        let slot = 3 * 3600.0
        let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / slot).rounded(.down) * slot)
        let entries = (0..<8).map { entry(at: start.addingTimeInterval(Double($0) * slot)) }
        completion(Timeline(entries: entries.map { QuoteEntry(date: max($0.date, now.addingTimeInterval(-1)), quote: $0.quote) }, policy: .atEnd))
    }

    private func entry(at date: Date) -> QuoteEntry {
        let offset = UserDefaults.standard.integer(forKey: offsetKey)
        return QuoteEntry(date: date, quote: Quotes.all[Quotes.index(at: date, offset: offset)])
    }
}

struct QuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.aether.widget.quote", provider: QuoteProvider()) { entry in
            QuoteView(entry: entry).containerBackground(for: .widget) {
                LinearGradient(colors: hueColors(entry.quote.film), startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .configurationDisplayName("Citazioni dei film")
        .description("Una battuta famosa che cambia ogni tanto. Le frecce scorrono, un tocco apre la scheda del film.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuoteView: View {
    let entry: QuoteEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let quote = entry.quote
        let link = WidgetSnapshot.deepLink(type: quote.type, id: quote.id)
        if family == .systemSmall {
            quoteBlock(quote).widgetURL(link)
        } else {
            VStack(spacing: 6) {
                if let link = link { Link(destination: link) { quoteBlock(quote) } } else { quoteBlock(quote) }
                HStack {
                    Button(intent: QuoteStepIntent(step: -1)) { Image(systemName: "chevron.left").font(.footnote.weight(.bold)).frame(width: 40, height: 22) }
                    Spacer()
                    Button(intent: QuoteStepIntent(step: 1)) { Image(systemName: "chevron.right").font(.footnote.weight(.bold)).frame(width: 40, height: 22) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func quoteBlock(_ quote: FilmQuote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "quote.opening").font(.title3.weight(.bold)).foregroundStyle(.white.opacity(0.55))
            Text(quote.text).font(.system(family == .systemSmall ? .footnote : .headline, design: .serif).weight(.semibold))
                .lineLimit(family == .systemSmall ? 5 : 4).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Text(quote.film).font(.caption2.weight(.bold)).lineLimit(1).opacity(0.85)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
