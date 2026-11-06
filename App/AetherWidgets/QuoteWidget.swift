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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct QuoteView: View {
    let entry: QuoteEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let quote = entry.quote
        let link = WidgetSnapshot.deepLink(type: quote.type, id: quote.id)
        VStack(spacing: family == .systemSmall ? 2 : 6) {
            if let link = link { Link(destination: link) { quoteBlock(quote) } } else { quoteBlock(quote) }
            controls
        }
    }

    /// ◀ and ▶ on every size (small ones are tiny so the line keeps its room).
    private var controls: some View {
        HStack {
            Button(intent: QuoteStepIntent(step: -1)) { Image(systemName: "chevron.left").font(.system(size: family == .systemSmall ? 11 : 15, weight: .bold)).frame(width: family == .systemSmall ? 30 : 48, height: family == .systemSmall ? 20 : 28) }
            Spacer()
            if family == .systemLarge { Text("Tocca la frase per aprire il film").font(.caption2).opacity(0.7) }
            Spacer()
            Button(intent: QuoteStepIntent(step: 1)) { Image(systemName: "chevron.right").font(.system(size: family == .systemSmall ? 11 : 15, weight: .bold)).frame(width: family == .systemSmall ? 30 : 48, height: family == .systemSmall ? 20 : 28) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
    }

    private func quoteBlock(_ quote: FilmQuote) -> some View {
        let size: Font.TextStyle = family == .systemSmall ? .footnote : (family == .systemMedium ? .headline : .title2)
        return VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 6) {
            Image(systemName: "quote.opening").font(family == .systemLarge ? .largeTitle.weight(.bold) : .title3.weight(.bold)).foregroundStyle(.white.opacity(0.55))
            Text(quote.text).font(.system(size, design: .serif).weight(.semibold))
                .lineLimit(family == .systemSmall ? 5 : (family == .systemMedium ? 4 : 9)).minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(quote.film).font(family == .systemLarge ? .subheadline.weight(.bold) : .caption2.weight(.bold)).lineLimit(2).opacity(0.9)
                if family != .systemSmall { Label("Apri la scheda", systemImage: "play.fill").font(.caption2.weight(.bold)).opacity(0.75) }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
