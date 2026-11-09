import Foundation

/// «Dove eravamo rimasti?»: the material for a summary of a series the viewer has not watched for a while. Only the plots of the
/// episodes already watched are used (from the addon or TMDB), so the summary cannot tell anything that comes later and cannot
/// invent: the model is told to use those plots and nothing else.
public enum SeriesRecap {
    /// The recap is offered when the last episode was watched at least this long ago.
    public static let pause: TimeInterval = 21 * 24 * 3600
    /// At most this many of the latest watched episodes go into the summary.
    public static let maxEpisodes = 8

    public struct Episode: Equatable, Sendable {
        public var label: String
        public var title: String
        public var overview: String
    }

    /// Watched episodes with a plot, in order, the latest `maxEpisodes`.
    public static func episodes(of meta: MetaItem, watched: Set<String>) -> [Episode] {
        let seen = meta.videos
            .filter { watched.contains($0.id) && ($0.season ?? 0) > 0 }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        let withPlot = seen.compactMap { video -> Episode? in
            guard let plot = video.overview?.trimmingCharacters(in: .whitespacesAndNewlines), plot.count >= 20 else { return nil }
            let label = String(format: "S%02dE%02d", video.season ?? 0, video.episode ?? 0)
            return Episode(label: label, title: video.title, overview: plot)
        }
        return Array(withPlot.suffix(maxEpisodes))
    }

    /// Whether to show the button: a series with at least three watched episodes, the last one watched long enough ago.
    public static func shouldOffer(watchedCount: Int, lastWatched: Date?, now: Date = Date()) -> Bool {
        guard watchedCount >= 3, let last = lastWatched else { return false }
        return now.timeIntervalSince(last) >= pause
    }

    public static let instructions = """
    Sei l'assistente di un'app per guardare film e serie. Scrivi in italiano un riepilogo di quello che lo spettatore ha già visto, \
    per ricordargli dove era rimasto. Usa SOLO le trame degli episodi che ti vengono date: non aggiungere fatti, nomi o eventi che \
    non ci sono, e non parlare di cosa succederà dopo. Scrivi 5-7 frasi scorrevoli, al passato, senza elenchi e senza titoli. \
    Se le trame sono poche o vaghe, fai un riepilogo breve e non inventare.
    """

    public static func prompt(series: String, episodes: [Episode]) -> String {
        var lines = ["Serie: \(series)", "Episodi già visti, dal più vecchio al più recente:"]
        for episode in episodes {
            lines.append("- \(episode.label) «\(episode.title)»: \(episode.overview)")
        }
        lines.append("Riassumi dove era rimasto lo spettatore.")
        return lines.joined(separator: "\n")
    }
}
