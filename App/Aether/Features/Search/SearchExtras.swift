import SwiftUI
import AetherCore

/// Under the results of a search: the universes that match (instant, from the built-in data) and the people that match (TMDB, after a short pause).
struct SearchExtrasSection: View {
    let query: String
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var router: AppRouter
    @State private var people: [PersonSearchResult] = []
    @State private var missingKey = false

    var body: some View {
        let universes = UniverseCatalog.search(query)
        Group {
            if !universes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Universe")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(universes) { universe in
                                let watched = Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys)
                                NavigationLink(value: universe) {
                                    UniverseCard(universe: universe, progress: UniverseProgress.compute(universe, order: .release, watchedIDs: watched), wide: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Theme.pageMargin)
                    }
                }
                .accessibilityIdentifier("search.universes")
            }
            if missingKey && query.count >= 3 {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Per vedere anche attori e registi serve la chiave TMDB (è gratuita).", systemImage: "person.crop.circle.badge.questionmark").font(.footnote.weight(.semibold))
                    Button("Aggiungila in Altro ▸ Impostazioni ▸ Servizi") { router.tab = .more }.font(.footnote)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, Theme.pageMargin)
                .accessibilityIdentifier("search.peopleKey")
            }
            if !people.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Persone")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(people) { person in
                                NavigationLink(value: PersonRoute(personID: person.id, name: person.name)) {
                                    VStack(spacing: 6) {
                                        RemoteImage(urlString: person.photoURL, width: 160, placeholderSeed: person.name, systemPlaceholder: "person.fill")
                                            .frame(width: 76, height: 76).clipShape(Circle())
                                        Text(person.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center).frame(width: 84)
                                        if let job = person.profession { Text(job).font(.caption2).foregroundStyle(Color.aetherSecondary).lineLimit(1) }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, Theme.pageMargin)
                    }
                }
                .accessibilityIdentifier("search.people")
            }
        }
        .task(id: query) {
            people = []
            missingKey = false
            guard query.count >= 3 else { return }
            let configured = await env.metadata.tmdbConfigured
            if !configured { missingKey = true; return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
            let found = await env.metadata.searchPeople(query, language: language)
            if !Task.isCancelled { people = found }
        }
    }
}
