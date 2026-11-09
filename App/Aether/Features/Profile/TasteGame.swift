import SwiftUI
import AetherCore

@MainActor
final class TasteGameModel: ObservableObject {
    @Published private(set) var deck: [TasteCandidate] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var details: [String: TasteCandidate] = [:]
    private var refilling = false

    func card(_ item: TasteCandidate) -> TasteCandidate { return details[item.id] ?? item }

    func start(env: AppEnvironment, addons: AddonStore, settings: SettingsStore, library: LibraryModel) async {
        guard deck.isEmpty else { return }
        isLoading = true
        await refill(env: env, addons: addons, settings: settings, library: library)
        isLoading = false
        if deck.isEmpty { message = "Non trovo titoli da proporti: servono un addon con cataloghi per genere (Cinemeta lo è) e la rete." }
        await enrichUpcoming(env: env)
    }

    func refill(env: AppEnvironment, addons: AddonStore, settings: SettingsStore, library: LibraryModel) async {
        guard !refilling else { return }
        refilling = true
        defer { refilling = false }
        let profile = settings.value.content.profile
        let genres = TasteEngine.topGenres(profile)
        let found = await TasteSource.fetch(env: env, addons: addons, genres: genres)
        let watched = Set(library.history.map { $0.metaID })
        let known = Set(deck.map { $0.id })
        deck += TasteEngine.deck(TasteSource.varied(found), profile: profile, excluding: watched.union(known))
    }

    /// The film is taken off the pile; returns it so the caller can record the verdict.
    func take() -> TasteCandidate? { return deck.isEmpty ? nil : deck.removeFirst() }

    func enrichUpcoming(env: AppEnvironment) async {
        for item in deck.prefix(3) where details[item.id] == nil {
            let fallback = MetaItem(id: item.id, type: item.type, name: item.name, poster: item.poster)
            let found = await env.service.meta(type: item.type, id: item.id, fallback: fallback).meta
            details[item.id] = TasteCandidate(id: item.id, type: item.type, name: item.name, poster: item.poster ?? found.poster, year: item.year ?? found.releaseInfo,
                                              genres: found.genres.isEmpty ? item.genres : found.genres,
                                              overview: (found.description?.isEmpty == false ? found.description : item.overview), cast: found.cast.isEmpty ? item.cast : found.cast)
        }
    }
}

/// The taste game: films as big cards. Right (or the heart) = I like it, left (or the cross) = I don't, up (or the arrow) = pass without a vote.
struct TasteGameView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var addons: AddonStore
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TasteGameModel()
    @State private var offset: CGSize = .zero
    @State private var voted = 0
    @State private var showVotes = false

    private enum Choice { case like, dislike, skip }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                VStack(spacing: 14) {
                    if model.isLoading && model.deck.isEmpty {
                        Spacer(); ProgressView("Cerco qualcosa per te…").controlSize(.large); Spacer()
                    } else if model.deck.isEmpty {
                        emptyState
                    } else {
                        stack
                        buttons
                        Text("Destra: mi piace · Sinistra: non mi piace · Su: salta").font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationTitle("Gioco dei gusti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Fine") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showVotes = true } label: { Label("I miei voti", systemImage: "list.bullet.rectangle") }
                }
            }
            .sheet(isPresented: $showVotes) { NavigationStack { TasteVotesView().toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fine") { showVotes = false } } } } }
        }
        .task { await model.start(env: env, addons: addons, settings: settings, library: library) }
    }

    // MARK: Cards

    private var stack: some View {
        ZStack {
            ForEach(Array(model.deck.prefix(3).enumerated().reversed()), id: \.element.id) { index, item in
                TasteCard(item: model.card(item), dragX: index == 0 ? offset.width : 0, dragY: index == 0 ? offset.height : 0)
                    .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.045)
                    .offset(x: index == 0 ? offset.width : 0, y: index == 0 ? offset.height : CGFloat(index) * 12)
                    .rotationEffect(.degrees(index == 0 ? Double(offset.width / 22) : 0))
                    .allowsHitTesting(index == 0)
                    .gesture(index == 0 ? drag : nil)
                    .zIndex(Double(3 - index))
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 4)
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { offset = $0.translation }
            .onEnded { value in
                if value.translation.width > 110 { decide(.like) }
                else if value.translation.width < -110 { decide(.dislike) }
                else if value.translation.height < -120 { decide(.skip) }
                else { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero } }
            }
    }

    private var buttons: some View {
        HStack(spacing: 26) {
            roundButton("xmark", .red, "Non mi piace") { decide(.dislike) }
            roundButton("arrow.uturn.up", .gray, "Salta") { decide(.skip) }.scaleEffect(0.85)
            roundButton("heart.fill", .green, "Mi piace") { decide(.like) }
        }
    }

    private func roundButton(_ symbol: String, _ color: Color, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 26, weight: .bold)).foregroundStyle(color)
                .frame(width: 66, height: 66).background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(color.opacity(0.5), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: voted > 0 ? "checkmark.seal.fill" : "film.stack").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text(voted > 0 ? "Per ora è tutto!" : "Nessun titolo").font(.title2.weight(.bold))
            Text(model.message ?? "Hai giudicato \(voted) titoli. Scegli altri generi nel profilo per averne di nuovi.").font(.subheadline).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            Button { Task { await model.refill(env: env, addons: addons, settings: settings, library: library); await model.enrichUpcoming(env: env) } } label: { Label("Cerca altri titoli", systemImage: "arrow.clockwise") }
                .buttonStyle(PrimaryActionButtonStyle())
            Spacer()
        }
    }

    // MARK: Decisions

    private func decide(_ choice: Choice) {
        guard let top = model.deck.first else { return }
        let target: CGSize
        switch choice {
        case .like: target = CGSize(width: 700, height: offset.height)
        case .dislike: target = CGSize(width: -700, height: offset.height)
        case .skip: target = CGSize(width: offset.width, height: -900)
        }
        UIImpactFeedbackGenerator(style: choice == .skip ? .light : .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.22)) { offset = target }
        let card = model.card(top)
        Task {
            try? await Task.sleep(nanoseconds: 230_000_000)
            _ = model.take()
            offset = .zero
            switch choice {
            case .skip: settings.value.content.profile.skip(card.id)
            case .like, .dislike:
                settings.value.content.profile.vote(TasteVote(id: card.id, type: card.type, name: card.name, poster: card.poster, year: card.year, genres: card.genres,
                                                              verdict: choice == .like ? .like : .dislike))
                voted += 1
            }
            await model.enrichUpcoming(env: env)
            if model.deck.count < 5 { await model.refill(env: env, addons: addons, settings: settings, library: library) }
        }
    }
}

/// One card: the poster big, and over its lower part the title, year, a short plot and the main cast.
private struct TasteCard: View {
    let item: TasteCandidate
    let dragX: CGFloat
    let dragY: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous).fill(Color.black.opacity(0.4))
            RemoteImage(urlString: item.poster, width: 520, contentMode: .fill, placeholderSeed: item.name, systemPlaceholder: "film")
                .clipShape(RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous))
            LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.system(size: 27, weight: .heavy, design: AetherTypography.design)).lineLimit(2).minimumScaleFactor(0.7)
                Text([item.year, item.genres.prefix(3).joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 14, weight: .semibold, design: AetherTypography.design)).foregroundStyle(.white.opacity(0.8))
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 14, design: AetherTypography.design)).foregroundStyle(.white.opacity(0.9)).lineLimit(4)
                }
                if !item.cast.isEmpty {
                    Text("Con " + item.cast.prefix(4).joined(separator: ", ")).font(.system(size: 13, weight: .semibold, design: AetherTypography.design)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                } else {
                    Text("Cast in arrivo…").font(.system(size: 12, design: AetherTypography.design)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            // The stamps that grow with the drag.
            stamp("MI PIACE", .green, rotation: -14, opacity: Double(max(0, min(1, dragX / 110))), alignment: .topLeading)
            stamp("NON MI PIACE", .red, rotation: 14, opacity: Double(max(0, min(1, -dragX / 110))), alignment: .topTrailing)
            stamp("SALTA", .gray, rotation: 0, opacity: Double(max(0, min(1, -dragY / 120))), alignment: .top)
        }
        .frame(maxWidth: 520)
        .aspectRatio(0.66, contentMode: .fit)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
    }

    private func stamp(_ text: String, _ color: Color, rotation: Double, opacity: Double, alignment: Alignment) -> some View {
        Text(text).font(.system(size: 28, weight: .black, design: AetherTypography.design)).foregroundStyle(color)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: Corner.chip).strokeBorder(color, lineWidth: 4))
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

// MARK: Votes

/// «I miei voti»: what the viewer liked and did not like, to change the verdict or take it back.
struct TasteVotesView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var router: AppRouter
    @State private var shown: TasteVerdict = .like

    private var profile: ProfileSettings { return settings.value.content.profile }
    private var rows: [TasteVote] { return shown == .like ? profile.likes : profile.dislikes }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Voto", selection: $shown) {
                Text("Mi piace (\(profile.likes.count))").tag(TasteVerdict.like)
                Text("Non mi piace (\(profile.dislikes.count))").tag(TasteVerdict.dislike)
            }
            .pickerStyle(.segmented)
            .padding(16)
            .accessibilityIdentifier("votes.picker")
            if rows.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: shown == .like ? "heart" : "hand.thumbsdown").font(.system(size: 44)).foregroundStyle(Color.aetherSecondary)
                    Text(shown == .like ? "Nessun titolo che ti piace, ancora" : "Nessun titolo che non ti piace, ancora").font(.headline)
                    Text("Gioca al gioco dei gusti dal tuo profilo.").font(.subheadline).foregroundStyle(Color.aetherSecondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(rows) { vote in
                        Button { router.detail = MetaRoute(type: vote.type, id: vote.id) } label: { row(vote) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .leading) {
                                Button { change(vote) } label: { Label(shown == .like ? "Non mi piace" : "Mi piace", systemImage: shown == .like ? "hand.thumbsdown.fill" : "heart.fill") }
                                    .tint(shown == .like ? .red : .green)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { settings.value.content.profile.removeVote(id: vote.id) } label: { Label("Togli voto", systemImage: "trash") }
                            }
                            .contextMenu {
                                Button { change(vote) } label: { Label(shown == .like ? "Sposta in «Non mi piace»" : "Sposta in «Mi piace»", systemImage: "arrow.left.arrow.right") }
                                Button(role: .destructive) { settings.value.content.profile.removeVote(id: vote.id) } label: { Label("Togli il voto", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("I miei voti")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ vote: TasteVote) -> some View {
        HStack(spacing: 12) {
            RemoteImage(urlString: vote.poster, width: 120, placeholderSeed: vote.name, systemPlaceholder: "film")
                .frame(width: 46, height: 69).clipShape(RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(vote.name).font(.headline).lineLimit(2)
                Text([vote.year, vote.genres.prefix(2).joined(separator: " · ")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(Color.aetherSecondary)
            }
            Spacer()
            Image(systemName: shown == .like ? "heart.fill" : "hand.thumbsdown.fill").foregroundStyle(shown == .like ? Color.green : Color.red)
        }
        .padding(.vertical, 2)
    }

    private func change(_ vote: TasteVote) {
        var updated = vote
        updated.verdict = vote.verdict == .like ? .dislike : .like
        updated.votedAt = Date()
        settings.value.content.profile.vote(updated)
    }
}
