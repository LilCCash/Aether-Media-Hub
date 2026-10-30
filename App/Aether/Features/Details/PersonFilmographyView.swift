import SwiftUI
import AetherCore

/// Which person's filmography to show (TMDB's id of the person and their name).
struct PersonRoute: Hashable, Identifiable {
    let personID: Int
    let name: String
    var id: Int { return personID }
}

/// The films and series a person from the cast appeared in, the best known first. Under each title: the character they played.
/// A tap opens the title like any other (its IMDb code is asked from TMDB first).
struct PersonFilmographyView: View {
    let route: PersonRoute
    @EnvironmentObject private var env: AppEnvironment
    @State private var credits: [PersonCredit] = []
    @State private var isLoading = true
    @State private var isOpening = false
    @State private var openedTitle: MetaRoute?
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView("Cerco la filmografia…")
                    .padding(.top, 60)
            } else if credits.isEmpty {
                Text("TMDB non ha restituito titoli per \(route.name). Controlla la chiave in Impostazioni › Servizi.")
                    .font(.subheadline)
                    .foregroundStyle(Color.aetherSecondary)
                    .multilineTextAlignment(.center)
                    .padding(32)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(credits) { credit in
                        Button {
                            open(credit)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RemoteImage(urlString: credit.posterURL, width: 300, placeholderSeed: credit.title)
                                    .frame(width: 110, height: 165)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(credit.title)
                                    .font(.caption.weight(.semibold))
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .frame(width: 110, alignment: .leading)
                                if let character = credit.character {
                                    Text("nel ruolo di \(character)")
                                        .font(.caption2)
                                        .foregroundStyle(Color.aetherSecondary)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                        .frame(width: 110, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(credit.character.map { "\(credit.title), nel ruolo di \($0)" } ?? credit.title)
                        .accessibilityHint("Apre la scheda del titolo")
                        .accessibilityIdentifier("person.credit.\(credit.id)")
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, 16)
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

    private func load() async {
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        credits = await env.metadata.filmography(personID: route.personID, language: language,
                                                   hideTalkShows: env.settings.value.content.hiddenTalkScopes.contains(.cast))
        isLoading = false
    }

    private func open(_ credit: PersonCredit) {
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
