import SwiftUI
import AetherCore

/// «Scelti per te»: titles of the genres the viewer likes and has not seen or judged, from the genre catalogs of their own addons.
/// Shown only once the profile says something (genres chosen or votes given).
struct HomeForYouRow: View {
    var style: HomeCardStyle = .poster
    var size: PosterSize = .medium
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var addons: AddonStore
    @State private var items: [MetaItem] = []

    private static var cache: (key: String, date: Date, items: [MetaItem])?

    private var profile: ProfileSettings { return settings.value.content.profile }
    private var key: String { return (profile.genres + profile.votes.map { $0.id }).joined(separator: ",") + "|\(addons.revision)" }

    var body: some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Scelti per te", subtitle: subtitle)
                    PosterRowView(items: items, watchlistIDs: library.watchlistIDs, style: style, size: size)
                }
                .accessibilityIdentifier("home.forYou")
            }
        }
        .task(id: key) { await load() }
    }

    private var subtitle: String? {
        let names = TasteEngine.topGenres(profile, limit: 3).compactMap { ProfileGenre(rawValue: $0)?.title }
        return names.isEmpty ? nil : "Per chi ama " + names.joined(separator: ", ").lowercased()
    }

    private func load() async {
        guard !profile.genres.isEmpty || !profile.votes.isEmpty else { items = []; return }
        if let cached = Self.cache, cached.key == key, Date().timeIntervalSince(cached.date) < 1800 { items = cached.items; return }
        let found = await TasteSource.fetch(env: env, addons: addons, genres: TasteEngine.topGenres(profile))
        let seen = Set(library.history.map { $0.metaID })
        let deck = TasteEngine.deck(found.shuffled(), profile: profile, excluding: seen)
        let metas = deck.prefix(18).map { MetaItem(id: $0.id, type: $0.type, name: $0.name, poster: $0.poster, description: $0.overview, releaseInfo: $0.year, genres: $0.genres) }
        items = metas
        Self.cache = (key, Date(), metas)
    }
}
