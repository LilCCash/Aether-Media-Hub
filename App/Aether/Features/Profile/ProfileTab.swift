import SwiftUI
import AetherCore

/// The Profile tab: who the viewer is, and everything that Aether keeps about what they watch (diary, statistics, their cinema year, tastes).
/// The settings are behind the gear at the top left, editing the profile behind the pencil at the top right.
struct ProfileTabView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var library: LibraryModel
    @State private var path = NavigationPath()
    @State private var editing = false
    @State private var playing = false
    /// Shown over the glass Home (opened from its picture): a «Fine» button closes it.
    var onClose: (() -> Void)? = nil

    enum Destination: Hashable { case settings, addons, services, diary, stats, universe, ratings, votes, trakt }

    private var profile: ProfileSettings { return settings.value.content.profile }
    private var diary: DiarySettings { return settings.value.content.diary }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                AetherBackdrop()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        if settings.value.appearance.showCinemaCard {
                            CinemaUniverseCard().onTapGesture { path.append(Destination.universe) }
                                .accessibilityAddTraits(.isButton)
                        }
                        diaryPanel
                        tastePanel
                        if settings.value.content.trakt.enabled { traktPanel }
                    }
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Profilo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { path.append(Destination.settings) } label: { Image(systemName: "gearshape.fill") }
                        .accessibilityLabel("Impostazioni")
                        .accessibilityIdentifier("profile.settings")
                }
                if let onClose = onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fine", action: onClose).fontWeight(.semibold).accessibilityIdentifier("profile.close")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "pencil.circle.fill") }
                        .accessibilityLabel("Modifica il profilo")
                        .accessibilityIdentifier("profile.edit")
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .settings: SettingsRootView()
                case .addons: AddonsView()
                case .services: ServicesSettingsView()
                case .diary: DiaryView()
                case .stats: StatsView()
                case .universe: CinemaUniverseView()
                case .ratings: RatingComparisonView()
                case .votes: TasteVotesView()
                case .trakt: TraktCatalogView(trakt: env.trakt)
                }
            }
            .sheet(isPresented: $editing) { NavigationStack { ProfileEditorView() } }
            .fullScreenCover(isPresented: $playing) { TasteGameView() }
            .onChange(of: router.profileRoute) { _, route in consume(route) }
            .onChange(of: router.pendingAddonInput) { _, input in
                if input != nil && !router.usesGlassHome { router.open(.addons) }
            }
            .onAppear {
                consume(router.profileRoute)
                if router.pendingAddonInput != nil && !router.usesGlassHome { router.open(.addons) }
            }
        }
    }

    private func consume(_ route: ProfileRoute?) {
        // With the glass Home these pages open in the Impostazioni item of the bar, not in the profile.
        guard let route = route, !router.usesGlassHome else { return }
        router.profileRoute = nil
        path = NavigationPath()
        switch route {
        case .settings: path.append(Destination.settings)
        case .addons: path.append(Destination.addons)
        case .services: path.append(Destination.settings); path.append(Destination.services)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            AvatarView(avatarID: profile.avatar, size: 96)
            Text(profile.displayName ?? "Il tuo profilo").font(.aetherTitle(28))
            if !profile.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(profile.genres, id: \.self) { raw in
                            if let genre = ProfileGenre(rawValue: raw) {
                                Text("\(genre.emoji) \(genre.title)").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } else {
                Button { editing = true } label: { Text("Scegli i generi che ti piacciono").font(.footnote.weight(.semibold)) }
                    .buttonStyle(.aetherSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var diaryPanel: some View {
        AetherPanel(title: "Il mio cinema", symbol: "film.stack") {
            VStack(spacing: 0) {
                row("Diario e timeline", "book.closed.fill", .brown, "\(diary.entries.count + library.history.count) visioni", .diary)
                Divider()
                row("Statistiche", "chart.bar.fill", .orange, nil, .stats)
                Divider()
                row("Confronto dei voti", "star.leadinghalf.filled", .yellow, "\(diary.entries.filter { $0.rating != nil }.count) voti", .ratings)
            }
        }
    }

    private var tastePanel: some View {
        AetherPanel(title: "I miei gusti", symbol: "heart.fill") {
            Button { playing = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.draw.fill").foregroundStyle(.white).frame(width: 34, height: 34)
                        .background(LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gioco dei gusti").font(.headline)
                        Text("Scorri a destra se ti piace, a sinistra se no.").font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.aetherSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.game")
            Divider()
            row("I miei voti", "heart.text.square.fill", .pink, "\(profile.likes.count) 👍 · \(profile.dislikes.count) 👎", .votes)
        }
    }

    private var traktPanel: some View {
        AetherPanel(title: "Collegamenti", symbol: "link") {
            row("Trakt", "play.square.stack.fill", .red, env.trakt.user?.username, .trakt)
        }
    }

    private func row(_ title: String, _ icon: String, _ color: Color, _ detail: String?, _ destination: Destination) -> some View {
        Button { path.append(destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(color.gradient, in: RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                Text(title)
                Spacer()
                if let detail = detail { Text(detail).font(.footnote).foregroundStyle(Color.aetherSecondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.aetherSecondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.row.\(title)")
    }
}

// MARK: - My Cinema Universe

/// The numbers of the viewer's year, from the diary and from what was watched with the player.
struct CinemaYear {
    var year: Int
    var stats: DiaryStats
    var playerMinutes: Int

    var totalMinutes: Int { return max(stats.minutes, playerMinutes) }
    var hours: Int { return totalMinutes / 60 }

    static func compute(diary: DiarySettings, history: [PlaybackProgress], year: Int) -> CinemaYear {
        let calendar = Calendar.current
        let seconds = history.filter { calendar.component(.year, from: $0.updatedAt) == year }
            .reduce(0.0) { $0 + ($1.isCompleted ? max($1.duration, $1.position) : $1.position) }
        return CinemaYear(year: year, stats: DiaryStats.compute(diary.entries, year: year), playerMinutes: Int(seconds / 60))
    }
}

/// The card on the Profile that opens the full page: this year's hours, big.
struct CinemaUniverseCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        let year = Calendar.current.component(.year, from: Date())
        let data = CinemaYear.compute(diary: settings.value.content.diary, history: library.history, year: year)
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [settings.accentColor, settings.accentColor.opacity(0.35), Color(red: 0.05, green: 0.06, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "sparkles").font(.system(size: 90)).foregroundStyle(.white.opacity(0.12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14)
            VStack(alignment: .leading, spacing: 4) {
                Text("IL MIO UNIVERSO DEL CINEMA \(String(year))").font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.8))
                Text("\(data.hours) ore").font(.system(size: 44, weight: .heavy, design: AetherTypography.design)).foregroundStyle(.white)
                Text(data.stats.films + data.stats.episodesAndSeries == 0 ? "Guarda qualcosa e segnalo nel diario: qui comparirà il tuo anno."
                     : "\(data.stats.films) film · \(data.stats.episodesAndSeries) tra serie ed episodi")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            .padding(18)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct CinemaUniverseView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @State private var year = Calendar.current.component(.year, from: Date())

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array(Set(DiaryStats.years(settings.value.content.diary.entries) + [current])).sorted(by: >)
    }

    private static let months = ["G", "F", "M", "A", "M", "G", "L", "A", "S", "O", "N", "D"]

    var body: some View {
        let data = CinemaYear.compute(diary: settings.value.content.diary, history: library.history, year: year)
        return ZStack {
            AetherBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Anno", selection: $year) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    hero(data)
                    tiles(data.stats)
                    monthsPanel(data.stats)
                    if !data.stats.topGenres.isEmpty { bubblesPanel("I tuoi generi", "theatermasks.fill", data.stats.topGenres) }
                    if !data.stats.topPeople.isEmpty { bubblesPanel("Registi e attori più visti", "person.2.fill", data.stats.topPeople) }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Il mio universo")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hero(_ data: CinemaYear) -> some View {
        VStack(spacing: 4) {
            Text("NEL \(String(data.year))").font(.system(size: 12, weight: .bold)).tracking(2).foregroundStyle(.white.opacity(0.8))
            Text("\(data.hours)").font(.system(size: 88, weight: .black, design: AetherTypography.design)).foregroundStyle(.white)
            Text(data.hours == 1 ? "ora di cinema" : "ore di cinema").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(LinearGradient(colors: [settings.accentColor, settings.accentColor.opacity(0.4), Color(red: 0.05, green: 0.06, blue: 0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: Corner.sheet, style: .continuous))
    }

    private func tiles(_ stats: DiaryStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            tile("Film", "\(stats.films)", "film.fill")
            tile("Serie ed episodi", "\(stats.episodesAndSeries)", "tv.fill")
            tile("Riguardati", "\(stats.rewatches)", "arrow.triangle.2.circlepath")
            tile("Voto medio", stats.averageRating.map { String(format: "%.1f ★", $0 / 2) } ?? "—", "star.fill")
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tint)
            Text(value).font(.system(size: 30, weight: .bold, design: AetherTypography.design))
            Text(title).font(.footnote).foregroundStyle(Color.aetherSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
    }

    private func monthsPanel(_ stats: DiaryStats) -> some View {
        let values = stats.perMonth.count == 12 ? stats.perMonth : Array(repeating: 0, count: 12)
        let peak = max(values.max() ?? 1, 1)
        return AetherPanel(title: "Mese per mese", symbol: "calendar") {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<12, id: \.self) { index in
                    VStack(spacing: 4) {
                        Text(values[index] > 0 ? "\(values[index])" : " ").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.aetherSecondary)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(values[index] == peak ? AnyShapeStyle(settings.accentColor.gradient) : AnyShapeStyle(settings.accentColor.opacity(0.45)))
                            .frame(height: max(4, 90 * CGFloat(values[index]) / CGFloat(peak)))
                        Text(CinemaUniverseView.months[index]).font(.system(size: 10)).foregroundStyle(Color.aetherSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
    }

    private func bubblesPanel(_ title: String, _ icon: String, _ items: [DiaryStats.Count]) -> some View {
        let peak = max(items.map { $0.count }.max() ?? 1, 1)
        return AetherPanel(title: title, symbol: icon) {
            FlowLayout(spacing: 8) {
                ForEach(items, id: \.name) { item in
                    let weight = Double(item.count) / Double(peak)
                    Text("\(item.name) · \(item.count)")
                        .font(.system(size: 13 + 5 * weight, weight: .semibold, design: AetherTypography.design))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(settings.accentColor.opacity(0.15 + 0.35 * weight), in: Capsule())
                }
            }
        }
    }
}

/// Lays its children out in rows that wrap, like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Personal rating comparison

/// The viewer's stars against the public score of the same titles.
struct RatingComparisonView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment
    @State private var publicScores: [String: Double] = [:]
    @State private var loading = true

    private var rated: [DiaryEntry] {
        var seen = Set<String>()
        return settings.value.content.diary.timeline.filter { $0.rating != nil && seen.insert($0.metaID).inserted }
    }

    var body: some View {
        List {
            if rated.isEmpty {
                Section { Text("Dai un voto ai titoli nel diario («Segna nel diario» sulla scheda di un film): qui li confronti con il voto del pubblico.").foregroundStyle(Color.aetherSecondary) }
            } else {
                Section(footer: Text("Il tuo voto è in stelle da 0 a 5 portate a 10; quello del pubblico viene da IMDb, dove disponibile.")) {
                    ForEach(rated) { entry in row(entry) }
                }
            }
        }
        .navigationTitle("Confronto dei voti")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: rated.map { $0.metaID }) { await loadScores() }
    }

    private func row(_ entry: DiaryEntry) -> some View {
        let mine = Double(entry.rating ?? 0)
        let theirs = publicScores[entry.metaID]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.name).font(.headline).lineLimit(1)
                Spacer()
                if let theirs = theirs {
                    let delta = mine - theirs
                    Text(abs(delta) < 0.5 ? "In linea" : (delta > 0 ? "Più generoso" : "Più severo"))
                        .font(.caption.weight(.semibold)).foregroundStyle(abs(delta) < 0.5 ? .green : (delta > 0 ? .orange : .red))
                }
            }
            bar("Tu", mine, settings.accentColor)
            if let theirs = theirs { bar("Pubblico", theirs, .gray) }
            else { Text(loading ? "Cerco il voto del pubblico…" : "Voto del pubblico non disponibile").font(.caption).foregroundStyle(Color.aetherSecondary) }
        }
        .padding(.vertical, 4)
    }

    private func bar(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 62, alignment: .leading).foregroundStyle(Color.aetherSecondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color.gradient).frame(width: proxy.size.width * CGFloat(min(max(value / 10, 0), 1)))
                }
            }
            .frame(height: 8)
            Text(String(format: "%.1f", value)).font(.caption.monospacedDigit().weight(.semibold)).frame(width: 34, alignment: .trailing)
        }
    }

    private func loadScores() async {
        loading = true
        for entry in rated.prefix(40) where publicScores[entry.metaID] == nil {
            let resolution = await env.service.meta(type: entry.type, id: entry.metaID)
            if let value = resolution.meta.ratingValue { publicScores[entry.metaID] = value }
        }
        loading = false
    }
}
