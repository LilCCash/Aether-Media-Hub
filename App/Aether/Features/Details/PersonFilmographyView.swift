import SwiftUI
import AetherCore

/// Which person's filmography to show (TMDB's id of the person and their name).
struct PersonRoute: Hashable, Identifiable {
    let personID: Int
    let name: String
    var id: Int { return personID }
}

/// A person's page: photo, profession, biography and the whole career, filterable by role, kind, genre and period.
/// A tap on a title opens it like any other (its IMDb code is asked from TMDB first).
struct PersonFilmographyView: View {
    let route: PersonRoute
    @EnvironmentObject private var env: AppEnvironment
    @State private var profile: PersonProfile?
    @State private var isLoading = true
    @State private var isOpening = false
    @State private var openedTitle: MetaRoute?
    @State private var problem: String?
    @State private var filter = PersonFilter()
    @State private var bioExpanded = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    private var shown: [PersonFilmographyEntry] { return filter.apply(profile?.filmography ?? []) }

    var body: some View {
        ZStack {
            AetherBackdrop()
            ScrollView {
                if isLoading {
                    ProgressView("Cerco la scheda…").padding(.top, 60)
                } else if let profile = profile {
                    VStack(alignment: .leading, spacing: 18) {
                        header(profile)
                        if !profile.biography.isEmpty { biography(profile.biography) }
                        filters(profile)
                        if shown.isEmpty {
                            Text("Nessun titolo con questi filtri.").font(.subheadline).foregroundStyle(Color.aetherSecondary).frame(maxWidth: .infinity).padding(.top, 20)
                        } else {
                            Text("\(shown.count) titoli").font(.caption.weight(.semibold)).foregroundStyle(Color.aetherSecondary).padding(.horizontal, Theme.pageMargin)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) { ForEach(shown) { credit in card(credit) } }
                                .padding(.horizontal, Theme.pageMargin)
                        }
                    }
                    .padding(.bottom, 24)
                } else {
                    Text("TMDB non ha restituito la scheda di \(route.name). Controlla la chiave in Impostazioni › Servizi.")
                        .font(.subheadline).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center).padding(32)
                }
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openedTitle) { DetailView(route: $0) }
        .alert("Titolo non trovato", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .task { await load() }
        .accessibilityIdentifier("person.filmography")
    }

    private func header(_ profile: PersonProfile) -> some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: profile.photoURL, width: 700, contentMode: .fill, alignment: .top, placeholderSeed: profile.name, systemPlaceholder: "person.fill")
                .frame(height: 320).frame(maxWidth: .infinity).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 30, weight: .heavy, design: .rounded))
                if !profile.roles.isEmpty { Text(profile.roles.map { $0.title }.joined(separator: " · ")).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85)) }
                else if let job = profile.profession { Text(job).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85)) }
                if let life = profile.lifeLine() { Text(life).font(.caption).foregroundStyle(.white.opacity(0.75)) }
                if let place = profile.placeOfBirth { Text(place).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1) }
            }
            .foregroundStyle(.white).padding(16)
        }
        .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 0))
    }

    private func biography(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Biografia").font(.title3.weight(.bold))
            Text(text).font(.subheadline).foregroundStyle(Color.aetherSecondary).lineLimit(bioExpanded ? nil : 5)
            Button(bioExpanded ? "Mostra meno" : "Leggi tutto") { withAnimation { bioExpanded.toggle() } }.font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    private func filters(_ profile: PersonProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip("Tutto", filter.role == nil) { filter.role = nil }
                    ForEach(profile.roles, id: \.self) { role in chip(role.title, filter.role == role) { filter.role = role } }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
            HStack(spacing: 10) {
                Menu {
                    Button("Film e serie") { filter.onlyMovies = nil }
                    Button("Solo film") { filter.onlyMovies = true }
                    Button("Solo serie") { filter.onlyMovies = false }
                } label: { menuLabel(filter.onlyMovies == nil ? "Tipo" : (filter.onlyMovies == true ? "Film" : "Serie")) }
                let genres = PersonFilter.genres(in: profile.filmography)
                if !genres.isEmpty {
                    Menu {
                        Button("Tutti i generi") { filter.genre = nil }
                        ForEach(genres, id: \.self) { genre in Button(genre) { filter.genre = genre } }
                    } label: { menuLabel(filter.genre ?? "Genere") }
                }
                Menu {
                    Button("Ogni periodo") { filter.fromYear = nil; filter.toYear = nil }
                    ForEach([(2020, 2099), (2010, 2019), (2000, 2009), (1990, 1999), (1900, 1989)], id: \.0) { range in
                        Button(range.0 == 1900 ? "Prima del 1990" : "\(range.0)–\(min(range.1, 2029))") { filter.fromYear = range.0; filter.toYear = range.1 }
                    }
                } label: { menuLabel(filter.fromYear == nil ? "Periodo" : (filter.fromYear == 1900 ? "Prima del 1990" : "\(filter.fromYear ?? 0)")) }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }

    private func chip(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 4) { Text(text).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }
            .font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(0.1), in: Capsule())
    }

    private func card(_ credit: PersonFilmographyEntry) -> some View {
        Button { open(credit) } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(urlString: credit.posterURL, width: 300, placeholderSeed: credit.title)
                    .frame(width: 110, height: 165).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(credit.title).font(.caption.weight(.semibold)).multilineTextAlignment(.leading).lineLimit(2).frame(width: 110, alignment: .leading)
                Text([credit.year.map(String.init), credit.character.map { "«\($0)»" } ?? credit.roles.map { $0.title }.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.leading).lineLimit(2).frame(width: 110, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(credit.character.map { "\(credit.title), nel ruolo di \($0)" } ?? credit.title)
        .accessibilityHint("Apre la scheda del titolo")
        .accessibilityIdentifier("person.credit.\(credit.id)")
    }

    private func load() async {
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        profile = await env.metadata.personProfile(personID: route.personID, name: route.name, language: language,
                                                   hideTalkShows: env.settings.value.content.hiddenTalkScopes.contains(.cast))
        isLoading = false
    }

    private func open(_ credit: PersonFilmographyEntry) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            defer { isOpening = false }
            guard let imdb = await env.metadata.imdbID(forTMDBID: credit.tmdbID, metaType: credit.metaType) else {
                problem = "Aether non riesce a trovare «\(credit.title)» negli addon: TMDB non indica il suo codice IMDb oppure non risponde."
                return
            }
            let preview = MetaItem(id: imdb, type: credit.metaType, name: credit.title, poster: credit.posterURL)
            openedTitle = MetaRoute(type: credit.metaType, id: imdb, preview: preview)
        }
    }
}
