import SwiftUI
import UserNotifications
import AetherCore

// MARK: - Opening a TMDB title

/// What it takes to open a title that only TMDB knows by number: the IMDb code, then the usual page.
@MainActor
func routeForCard(_ card: DiscoveryCard, env: AppEnvironment) async -> MetaRoute {
    let imdb = await env.metadata.imdbID(forTMDBID: card.tmdbID, metaType: card.type)
    let id = imdb ?? "tmdb:\(card.tmdbID)"
    let preview = MetaItem(id: id, type: card.type, name: card.title, poster: card.posterURL, background: card.backdropURL,
                           description: card.overview.isEmpty ? nil : card.overview, releaseInfo: card.year)
    return MetaRoute(type: card.type, id: id, preview: preview)
}

// MARK: - Cinematic discovery

@MainActor
final class CinematicDiscoveryModel: ObservableObject {
    @Published var cards: [DiscoveryCard] = []
    @Published var loading = true
    /// The film whose similar titles are on screen; nil for the general feed.
    @Published var seed: DiscoveryCard?
    private var trail: [(cards: [DiscoveryCard], seed: DiscoveryCard?)] = []

    var canGoBack: Bool { return !trail.isEmpty }

    func loadFeed(env: AppEnvironment) async {
        loading = true
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        let page = Int.random(in: 1...5)
        async let movies = env.metadata.acclaimed(type: "movie", language: language, page: page)
        async let series = env.metadata.acclaimed(type: "series", language: language, page: page)
        let movieCards = await movies
        let seriesCards = await series
        cards = (movieCards + Array(seriesCards.prefix(8))).shuffled()
        seed = nil
        trail = []
        loading = false
    }

    func showSimilar(to card: DiscoveryCard, env: AppEnvironment) async {
        loading = true
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        let meta = MetaItem(id: "tmdb:\(card.tmdbID)", type: card.type, name: card.title)
        let rich = await env.metadata.richDetails(for: meta, language: language)
        let similar = (rich?.similar ?? []).map {
            DiscoveryCard(tmdbID: $0.tmdbID, type: card.type, title: $0.title, posterURL: $0.posterURL, backdropURL: nil, rating: $0.rating, genreIDs: $0.genreIDs ?? [])
        }
        if !similar.isEmpty {
            trail.append((cards, seed))
            cards = [card] + similar
            seed = card
        }
        loading = false
    }

    func back() {
        guard let last = trail.popLast() else { return }
        cards = last.cards
        seed = last.seed
    }
}

/// Full-screen, one film per page: swipe up for the next, «Simili» to follow the thread to films like this one.
struct CinematicDiscoveryView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CinematicDiscoveryModel()
    @State private var route: MetaRoute?
    @State private var opening = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.loading && model.cards.isEmpty {
                ProgressView().tint(.white)
            } else if model.cards.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.white.opacity(0.6))
                    Text("Niente da mostrare").font(.title3.bold()).foregroundStyle(.white)
                    Text("La scoperta usa TMDB: aggiungi la chiave in Impostazioni ▸ Servizi e chiavi.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding(.horizontal, 40)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.cards) { card in
                            DiscoveryPage(card: card, opening: opening,
                                          open: { open(card) }, similar: { Task { await model.showSimilar(to: card, env: env) } })
                                .containerRelativeFrame([.horizontal, .vertical])
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
                .id(model.seed?.id ?? "feed")
            }
            VStack {
                HStack {
                    GlassIconButton(systemName: "xmark", accessibilityLabel: "Chiudi la scoperta") { dismiss() }
                    if model.canGoBack {
                        Button { model.back(); Haptics.tap() } label: { Label("Indietro", systemImage: "chevron.left").font(.subheadline.weight(.semibold)) }
                            .buttonStyle(SecondaryActionButtonStyle())
                    } else if let seed = model.seed {
                        Text("Simili a \(seed.title)").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    }
                    Spacer()
                    GlassIconButton(systemName: "shuffle", accessibilityLabel: "Mescola") { Task { await model.loadFeed(env: env) }; Haptics.tap() }
                }
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .sheet(item: $route) { route in NavigationStack { DetailView(route: route) } }
        .task { if model.cards.isEmpty { await model.loadFeed(env: env) } }
        .animation(settings.animationsEnabled ? .easeInOut(duration: 0.3) : nil, value: model.seed?.id)
    }

    private func open(_ card: DiscoveryCard) {
        guard !opening else { return }
        opening = true
        Haptics.tap()
        Task {
            route = await routeForCard(card, env: env)
            opening = false
        }
    }
}

private struct DiscoveryPage: View {
    let card: DiscoveryCard
    let opening: Bool
    let open: () -> Void
    let similar: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.aetherStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomed = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(urlString: card.backdropURL ?? card.posterURL, width: 1280, placeholderSeed: card.title)
                .scaleEffect(zoomed && style.kenBurns && !reduceMotion ? 1.12 : 1)
                .blur(radius: card.backdropURL == nil ? 18 : 0)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.92)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text(card.title).font(.aetherTitle(34)).foregroundStyle(.white).lineLimit(3).shadow(radius: 8)
                HStack(spacing: 10) {
                    if let year = card.year { Text(year) }
                    Text(card.type == "movie" ? "Film" : "Serie")
                    if let rating = card.rating, rating > 0 { Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow) }
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                if !card.overview.isEmpty {
                    Text(card.overview).font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(4)
                }
                HStack(spacing: 10) {
                    Button(action: open) { Label(opening ? "Apro…" : "Dettagli", systemImage: "info.circle.fill") }
                        .buttonStyle(PrimaryActionButtonStyle())
                    Button(action: similar) { Label("Simili", systemImage: "arrow.triangle.branch") }
                        .buttonStyle(SecondaryActionButtonStyle())
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 54)
        }
        .onAppear { if style.kenBurns { withAnimation(.easeInOut(duration: 14)) { zoomed = true } } }
        .onDisappear { zoomed = false }
    }
}

// MARK: - Release calendar

/// Reminders for releases: the ids live in UserDefaults, the notification itself in the system (delivered on the day, at ten).
@MainActor
final class ReleaseReminders: ObservableObject {
    static let shared = ReleaseReminders()
    private static let key = "aether.releaseReminders"
    @Published private(set) var ids: Set<String>

    private init() { ids = Set(UserDefaults.standard.stringArray(forKey: ReleaseReminders.key) ?? []) }

    func isOn(_ card: DiscoveryCard) -> Bool { return ids.contains(card.id) }

    /// Turns the reminder of a release on or off. Returns false when the system refused notifications.
    @discardableResult
    func toggle(_ card: DiscoveryCard) async -> Bool {
        let center = UNUserNotificationCenter.current()
        if ids.contains(card.id) {
            center.removePendingNotificationRequests(withIdentifiers: ["release:" + card.id])
            ids.remove(card.id)
            persist()
            return true
        }
        guard let date = card.date else { return false }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return false }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 10
        guard let fire = Calendar.current.date(from: components), fire > Date() else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Esce oggi: \(card.title)"
        content.body = card.overview.isEmpty ? "Il titolo che aspettavi è disponibile da oggi." : String(card.overview.prefix(120))
        content.sound = .default
        content.userInfo = ["aetherDetailType": card.type, "aetherTMDB": card.tmdbID]
        let request = UNNotificationRequest(identifier: "release:" + card.id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        do { try await center.add(request) } catch { return false }
        ids.insert(card.id)
        persist()
        return true
    }

    private func persist() { UserDefaults.standard.set(Array(ids), forKey: ReleaseReminders.key) }
}

struct ReleaseCalendarView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var reminders = ReleaseReminders.shared
    @State private var cards: [DiscoveryCard] = []
    @State private var loading = true
    @State private var filter: Filter = .all
    @State private var route: MetaRoute?
    @State private var note: String?

    enum Filter: String, CaseIterable { case all = "Tutto", movie = "Film", series = "Serie" }

    private var visible: [DiscoveryCard] {
        switch filter {
        case .all: return cards
        case .movie: return cards.filter { $0.type == "movie" }
        case .series: return cards.filter { $0.type != "movie" }
        }
    }

    private var grouped: [(month: String, items: [DiscoveryCard])] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "LLLL yyyy"
        var order: [String] = []
        var buckets: [String: [DiscoveryCard]] = [:]
        for card in visible {
            let key = card.date.map { formatter.string(from: $0).capitalized } ?? "Data da definire"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(card)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Tipo", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else if cards.isEmpty {
                    Text("Nessuna uscita trovata. Il calendario usa TMDB: aggiungi la chiave in Impostazioni ▸ Servizi e chiavi.")
                        .foregroundStyle(Color.aetherSecondary)
                }
                ForEach(grouped, id: \.month) { group in
                    Section(header: Text(group.month)) {
                        ForEach(group.items) { card in row(card) }
                    }
                }
                if let note = note { Section { Text(note).font(.footnote).foregroundStyle(Color.aetherSecondary) } }
            }
            .scrollContentBackground(.hidden)
            .background(AetherBackdrop())
            .navigationTitle("Calendario uscite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() }.fontWeight(.semibold) } }
            .sheet(item: $route) { route in NavigationStack { DetailView(route: route) } }
            .task {
                let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
                let region = Locale.current.region?.identifier ?? "IT"
                cards = await env.metadata.upcoming(language: language, region: region)
                loading = false
            }
        }
    }

    private func row(_ card: DiscoveryCard) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { route = await routeForCard(card, env: env) }
            } label: {
                HStack(spacing: 12) {
                    RemoteImage(urlString: card.posterURL, width: 60, placeholderSeed: card.title)
                        .frame(width: 52, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title).font(.headline).lineLimit(2)
                        Text(dateText(card)).font(.subheadline).foregroundStyle(.tint)
                        Text(card.type == "movie" ? "Film" : "Serie TV").font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                Task {
                    let ok = await reminders.toggle(card)
                    note = ok ? nil : "Per il promemoria servono le notifiche (Impostazioni di iOS ▸ Aether) e una data futura."
                    if ok { Haptics.success() }
                }
            } label: {
                Image(systemName: reminders.isOn(card) ? "bell.fill" : "bell").font(.title3).foregroundStyle(reminders.isOn(card) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.aetherSecondary))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminders.isOn(card) ? "Togli il promemoria" : "Ricordamelo")
        }
    }

    private func dateText(_ card: DiscoveryCard) -> String {
        guard let date = card.date else { return "Data da definire" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE d MMMM"
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: date).day ?? 0
        let relative = days <= 0 ? "oggi" : (days == 1 ? "domani" : "tra \(days) giorni")
        return formatter.string(from: date).capitalized + " · " + relative
    }
}

// MARK: - AI discovery

/// Suggestions from the AI model the viewer set up for the advanced search, built on their tastes: favourite genres, the titles they voted up or
/// down in the taste game, and what they rated highly in the diary. A tap on a suggestion searches for it.
struct AIDiscoverySheet: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [(title: String, reason: String)] = []
    @State private var loading = false
    @State private var problem: String?

    private var advanced: AdvancedSearchSettings { return settings.value.content.advancedSearch }
    private var canAsk: Bool { return env.advancedSearch.ai.hasKey(for: advanced.provider) || advanced.provider.keyIsOptional }
    private var profile: ProfileSettings { return settings.value.content.profile }

    /// The tastes as a few lines of text for the model.
    private var tasteSummary: String {
        var lines: [String] = []
        let genres = TasteEngine.topGenres(profile)
        if !genres.isEmpty { lines.append("Generi preferiti: " + genres.joined(separator: ", ")) }
        let likes = profile.likes.prefix(12).map { $0.name }
        if !likes.isEmpty { lines.append("Titoli che gli sono piaciuti: " + likes.joined(separator: "; ")) }
        let dislikes = profile.dislikes.prefix(6).map { $0.name }
        if !dislikes.isEmpty { lines.append("Titoli che non gli sono piaciuti: " + dislikes.joined(separator: "; ")) }
        let loved = settings.value.content.diary.timeline.filter { ($0.rating ?? 0) >= 8 }.prefix(8).map { $0.name }
        if !loved.isEmpty { lines.append("Valutati molto bene nel diario: " + loved.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            List {
                if tasteSummary.isEmpty {
                    Section { Text("Per consigli su misura serve qualche gusto: scegli i generi nel Profilo e gioca al gioco dei gusti.").foregroundStyle(Color.aetherSecondary) }
                }
                if !canAsk {
                    Section { Text("Imposta un modello AI in Impostazioni ▸ Ricerca avanzata per ricevere i consigli.").foregroundStyle(Color.aetherSecondary) }
                }
                Section {
                    Button { Task { await ask() } } label: {
                        Label(loading ? "Penso ai tuoi gusti…" : (suggestions.isEmpty ? "Consigliami qualcosa" : "Altri consigli"), systemImage: "sparkles")
                    }
                    .disabled(loading || !canAsk)
                }
                if let problem = problem { Section { Text(problem).font(.footnote).foregroundStyle(.orange) } }
                if !suggestions.isEmpty {
                    Section(header: Text("Per te")) {
                        ForEach(suggestions.indices, id: \.self) { index in
                            Button {
                                router.pendingSearch = suggestions[index].title
                                router.tab = .search
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestions[index].title).font(.headline)
                                    if !suggestions[index].reason.isEmpty { Text(suggestions[index].reason).font(.subheadline).foregroundStyle(Color.aetherSecondary) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Consigli AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { dismiss() }.fontWeight(.semibold) } }
        }
    }

    private func ask() async {
        loading = true
        problem = nil
        defer { loading = false }
        let seen = suggestions.map { $0.title }
        let system = "Sei un consulente di cinema. Rispondi solo in italiano. Dai esattamente 8 suggerimenti di film o serie TV adatti ai gusti descritti, "
            + "senza ripetere titoli già visti o già citati. Formato: un suggerimento per riga, «Titolo (anno) | motivo in una frase breve». Nessun altro testo."
        var question = "Questi sono i gusti di chi guarda:\n" + (tasteSummary.isEmpty ? "Nessun dato: proponi grandi classici e titoli recenti molto apprezzati." : tasteSummary)
        if !seen.isEmpty { question += "\nGià proposti, non ripeterli: " + seen.joined(separator: "; ") }
        do {
            let text = try await env.advancedSearch.ai.ask(question, system: system, settings: advanced)
            let parsed = text.split(separator: "\n").compactMap { line -> (title: String, reason: String)? in
                let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: " -•*0123456789.)"))
                guard !cleaned.isEmpty else { return nil }
                let parts = cleaned.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                var title = parts[0]
                if let open = title.range(of: " (", options: .backwards), title.hasSuffix(")") { title = String(title[..<open.lowerBound]) }
                return (title, parts.count > 1 ? parts[1] : "")
            }
            suggestions += parsed
            if parsed.isEmpty { problem = "Il modello non ha risposto nel formato atteso. Riprova." }
        } catch let error as AISearchError {
            problem = error.message
        } catch {
            problem = "Non riesco a contattare il servizio AI."
        }
    }
}
