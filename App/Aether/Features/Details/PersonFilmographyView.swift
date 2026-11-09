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
    @State private var sub: Sub = .filmography
    @State private var collaboratorsLoaded = false

    private enum Sub: String, CaseIterable { case filmography = "Filmografia", biography = "Biografia", collaborations = "Collaborazioni" }

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
                        subTabs
                        if sub == .biography {
                            biographyPage(profile)
                        } else if sub == .collaborations {
                            collaborationsPage(profile)
                        } else {
                            mainFilms(profile)
                            filters(profile)
                            if shown.isEmpty {
                                Text("Nessun titolo con questi filtri.").font(.subheadline).foregroundStyle(Color.aetherSecondary).frame(maxWidth: .infinity).padding(.top, 20)
                            } else {
                                Text("\(shown.count) titoli").font(.caption.weight(.semibold)).foregroundStyle(Color.aetherSecondary).padding(.horizontal, Theme.pageMargin)
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) { ForEach(shown) { credit in card(credit) } }
                                    .padding(.horizontal, Theme.pageMargin)
                            }
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
        .navigationDestination(for: PersonRoute.self) { PersonFilmographyView(route: $0) }
        .alert("Titolo non trovato", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .task { await load() }
        .accessibilityIdentifier("person.filmography")
    }

    /// The person in a bubble (not a picture across the screen): the photo in a round frame with the accent ring, then name, roles and life.
    private func header(_ profile: PersonProfile) -> some View {
        VStack(spacing: 10) {
            PersonPhoto(urlString: profile.photoURL, name: profile.name, size: 148)
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Color.accentColor, .white.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3))
                .shadow(color: Color.accentColor.opacity(0.45), radius: 18, y: 6)
                .accessibilityLabel("Foto di \(profile.name)")
            Text(profile.name).font(.system(size: 28, weight: .heavy, design: AetherTypography.design)).multilineTextAlignment(.center)
            if !profile.roles.isEmpty { Text(profile.roles.map { $0.title }.joined(separator: " · ")).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor) }
            else if let job = profile.profession { Text(job).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor) }
            if let life = profile.lifeLine() { Text(life).font(.caption).foregroundStyle(Color.aetherSecondary) }
            if let place = profile.placeOfBirth { Text(place).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.horizontal, Theme.pageMargin)
    }

    private var subTabs: some View {
        HStack(spacing: 24) {
            ForEach(Sub.allCases, id: \.self) { item in
                Button { withAnimation(.snappy) { sub = item } } label: {
                    VStack(spacing: 6) {
                        Text(item.rawValue).font(.system(.subheadline, design: AetherTypography.design).weight(.semibold))
                            .foregroundStyle(sub == item ? Color.primary : Color.aetherSecondary)
                        Capsule().fill(sub == item ? Color.accentColor : Color.clear).frame(height: 3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sub == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    /// «Film principali»: the best known titles in a row, before the whole list.
    @ViewBuilder
    private func mainFilms(_ profile: PersonProfile) -> some View {
        let main = Array(profile.filmography.filter { $0.isMovie }.prefix(10))
        if main.count >= 3 {
            VStack(alignment: .leading, spacing: 10) {
                Text("Film principali").font(.title3.weight(.bold)).padding(.horizontal, Theme.pageMargin)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) { ForEach(main) { credit in card(credit) } }.padding(.horizontal, Theme.pageMargin)
                }
            }
        }
    }

    private func biographyPage(_ profile: PersonProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if profile.biography.isEmpty {
                Text("TMDB non ha una biografia di \(profile.name).").font(.subheadline).foregroundStyle(Color.aetherSecondary)
            } else {
                Text(profile.biography).font(.body).foregroundStyle(Color.primary.opacity(0.88))
            }
            VStack(alignment: .leading, spacing: 8) {
                if !profile.awards.isEmpty {
                    Text("Premi").font(.title3.weight(.bold)).padding(.top, 6)
                    ForEach(profile.awards) { award in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "trophy.fill").foregroundStyle(.yellow).font(.footnote)
                            Text(award.line).font(.subheadline)
                        }
                    }
                }
                if let life = profile.lifeLine() { fact("Nato", life) }
                if let place = profile.placeOfBirth { fact("Luogo", place) }
                if !profile.roles.isEmpty { fact("Ruoli", profile.roles.map { $0.title }.joined(separator: ", ")) }
                fact("Titoli", "\(profile.filmography.count)")
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    private func collaborationsPage(_ profile: PersonProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if profile.collaborators.isEmpty {
                Text(collaboratorsLoaded ? "Non trovo persone con almeno due titoli in comune tra i più noti." : "Cerco chi ha lavorato con \(profile.name)…")
                    .font(.subheadline).foregroundStyle(Color.aetherSecondary)
                if !collaboratorsLoaded { ProgressView() }
            } else {
                Text("Compare spesso insieme a").font(.title3.weight(.bold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14, alignment: .top)], spacing: 16) {
                    ForEach(profile.collaborators) { person in
                        NavigationLink(value: PersonRoute(personID: person.tmdbID, name: person.name)) {
                            VStack(spacing: 6) {
                                PersonPhoto(urlString: person.photoURL, name: person.name, size: 80)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                                Text(person.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                                Text("\(person.shared.count) titoli insieme").font(.caption2).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(person.name), \(person.shared.count) titoli insieme: " + person.shared.joined(separator: ", "))
                    }
                }
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Color.aetherSecondary).frame(width: 64, alignment: .leading)
            Text(value).font(.subheadline)
        }
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
                    .frame(width: 110, height: 165).clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
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
        guard let loaded = profile else { return }
        // The extras arrive after the page is already on screen.
        async let collaborators = env.metadata.collaborators(of: loaded, personID: route.personID, language: language)
        async let wikidata = env.metadata.wikidataID(personID: route.personID)
        let wikidataItem = await wikidata
        if let id = wikidataItem {
            let awards = await WikidataClient(http: env.http).awards(wikidataID: id, language: language)
            profile?.awards = awards
        }
        let foundCollaborators = await collaborators
        profile?.collaborators = foundCollaborators
        collaboratorsLoaded = true
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

/// A person's photo in a bubble without cutting the face: the whole portrait sits in the circle, over a soft blur of itself that fills the sides.
struct PersonPhoto: View {
    let urlString: String?
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RemoteImage(urlString: urlString, width: 120, contentMode: .fill, alignment: .top, placeholderSeed: name, systemPlaceholder: "person.fill")
                .blur(radius: 12)
                .opacity(0.8)
            RemoteImage(urlString: urlString, width: max(size * 2.6, 200), contentMode: .fit, placeholderSeed: name, systemPlaceholder: "person.fill")
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
