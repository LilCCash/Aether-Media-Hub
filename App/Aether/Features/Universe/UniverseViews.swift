import SwiftUI
import AetherCore

/// Where the artwork of an universe comes from: Cinemeta's image service, by IMDb id (no request to make before showing a card).
enum UniverseArt {
    static func background(_ id: String) -> String { return "https://images.metahub.space/background/medium/\(id)/img" }
    static func poster(_ id: String) -> String { return "https://images.metahub.space/poster/medium/\(id)/img" }
}

/// What the viewer has seen, from the player's history and from the diary.
@MainActor
enum WatchedTitles {
    enum Source { case history, diary }

    static func sources(library: LibraryModel, diary: DiarySettings) -> [String: Source] {
        var result: [String: Source] = [:]
        for item in library.history where item.isCompleted { result[item.metaID] = .history }
        for id in diary.watchedIDs where result[id] == nil { result[id] = .diary }
        return result
    }
}

extension UniverseDefinition {
    var gradient: [Color] {
        var hash: UInt64 = 1469598103934665603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360
        return [Color(hue: hue, saturation: 0.55, brightness: 0.55), Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.22)]
    }
    var countsLine: String {
        var parts: [String] = []
        if !films.isEmpty { parts.append("\(films.count) film") }
        if !series.isEmpty { parts.append("\(series.count) serie") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Hub

/// The «Universe» tab: every universe with its progress; the ones the viewer follows first.
struct UniverseHubView: View {
    /// Set when the hub is a page above the tabs: a close button at the top left (the pushed pages keep their own back button).
    var onClose: (() -> Void)? = nil
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var router: AppRouter

    private var diary: DiarySettings { return settings.value.content.diary }
    private var options: UniverseSettings { return settings.value.content.universes }

    private func progress(_ universe: UniverseDefinition) -> UniverseProgress {
        let watched = Set(WatchedTitles.sources(library: library, diary: diary).keys)
        return UniverseProgress.compute(universe, order: .release, watchedIDs: watched)
    }

    private var followed: [UniverseDefinition] { return options.followed.compactMap { UniverseCatalog.universe(id: $0) } }
    private var inProgress: [UniverseDefinition] {
        return UniverseCatalog.all.filter { universe in
            let p = progress(universe)
            return p.watched > 0 && !p.isComplete && !options.followed.contains(universe.id)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AetherBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text("Esplora interi universi narrativi: film, serie e spin-off, con il tuo percorso di visione.")
                            .font(.subheadline).foregroundStyle(Color.aetherSecondary)
                            .padding(.horizontal, Theme.pageMargin)
                        if !followed.isEmpty { rail("Che segui", followed) }
                        if !inProgress.isEmpty { rail("Da continuare", inProgress) }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tutti gli universi").font(.title3.weight(.bold)).padding(.horizontal, Theme.pageMargin)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 14)], spacing: 14) {
                                ForEach(UniverseCatalog.all) { universe in
                                    NavigationLink(value: universe.id) { UniverseCard(universe: universe, progress: progress(universe), wide: false) }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("universe.card.\(universe.id)")
                                }
                            }
                            .padding(.horizontal, Theme.pageMargin)
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle("Universe")
            .toolbar {
                if let onClose = onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onClose) { Image(systemName: "xmark") }.accessibilityLabel("Chiudi Universe")
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let universe = UniverseCatalog.universe(id: id) { UniverseDetailView(universe: universe) }
            }
            .navigationDestination(for: MetaRoute.self) { DetailView(route: $0) }
        }
    }

    private func rail(_ title: String, _ list: [UniverseDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal, Theme.pageMargin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(list) { universe in
                        NavigationLink(value: universe.id) { UniverseCard(universe: universe, progress: progress(universe), wide: true) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
        }
    }
}

struct UniverseCard: View {
    let universe: UniverseDefinition
    let progress: UniverseProgress
    let wide: Bool
    @Environment(\.aetherStyle) private var style

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: universe.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            RemoteImage(urlString: UniverseArt.background(universe.hero), width: 480, contentMode: .fill, placeholderSeed: universe.name, systemPlaceholder: "sparkles")
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                // Text styles (title3 = 20 pt, headline = 17 pt at the standard size) so the name follows Dynamic Type.
                Text(universe.name).font(.system(wide ? .title3 : .headline, design: AetherTypography.design, weight: .heavy))
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text(universe.countsLine).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if progress.watched > 0 {
                    ProgressView(value: progress.fraction).tint(.white).scaleEffect(y: 0.7)
                    Text("\(progress.watched)/\(progress.total) visti").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
            .legibleOnArtwork()
            .padding(12)
        }
        .frame(width: wide ? 250 : nil, height: wide ? 150 : 130)
        .frame(maxWidth: wide ? 250 : .infinity)
        // A title card like the others of the Home: it follows «Angoli» and the frame chosen for the cards.
        .clipShape(RoundedRectangle(cornerRadius: style.landscapeRadius, style: .continuous))
        .aetherCardChrome(cornerRadius: style.landscapeRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(universe.name), \(universe.countsLine)" + (progress.watched > 0 ? ", \(progress.percent) per cento visto" : ""))
    }
}

// MARK: Detail

struct UniverseDetailView: View {
    let universe: UniverseDefinition
    @EnvironmentObject private var env: AppEnvironment
    @State private var recurring: [(name: String, count: Int)] = []
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var router: AppRouter
    @State private var order: UniverseOrder = .release
    @State private var filter: Filter = .all
    @State private var editing = false
    @State private var showingMap = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tutto", films = "Film", series = "Serie", missing = "Mancanti"
        var id: String { return rawValue }
    }

    private var diary: DiarySettings { return settings.value.content.diary }
    private var custom: [String]? { return settings.value.content.universes.customOrders[universe.id] }
    private var sources: [String: WatchedTitles.Source] { return WatchedTitles.sources(library: library, diary: diary) }
    private var progress: UniverseProgress { return UniverseProgress.compute(universe, order: order, custom: custom, watchedIDs: Set(sources.keys)) }
    private var shown: [UniverseEntry] {
        let all = universe.ordered(order, custom: custom)
        switch filter {
        case .all: return all
        case .films: return all.filter { !$0.isSeries }
        case .series: return all.filter { $0.isSeries }
        case .missing: return all.filter { sources[$0.id] == nil }
        }
    }
    private var follows: Bool { return settings.value.content.universes.followed.contains(universe.id) }

    var body: some View {
        ZStack {
            AetherBackdrop()
            if editing {
                List {
                    Section { controls.listRowBackground(Color.clear) }
                    Section {
                        ForEach(shown) { entry in
                            HStack(spacing: 12) {
                                RemoteImage(urlString: UniverseArt.poster(entry.id), width: 120, placeholderSeed: entry.name, systemPlaceholder: "film")
                                    .frame(width: 40, height: 60).clipShape(RoundedRectangle(cornerRadius: Corner.chip, style: .continuous))
                                Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                            }
                        }
                        .onMove { source, destination in moveEntries(source, destination) }
                    } header: { Text("Trascina per riordinare").font(.caption).textCase(nil) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        controls.padding(.horizontal, Theme.pageMargin)
                        grid
                        recurringCast
                        linkedUniverses
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationTitle(universe.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingMap) { UniverseMapView(universe: universe) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingMap = true } label: { Image(systemName: "point.topleft.down.to.point.bottomright.curvepath") }
                    .accessibilityLabel("Mappa della timeline")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings.value.content.universes.toggleFollow(universe.id) } label: {
                    Image(systemName: follows ? "star.fill" : "star")
                }
                .accessibilityLabel(follows ? "Non seguire più l'universo" : "Segui l'universo")
            }
        }
        .onAppear { order = settings.value.content.universes.lastOrder[universe.id] ?? .release }
        .task(id: universe.id) { await loadRecurring() }
        .onChange(of: order) { _, new in
            settings.value.content.universes.lastOrder[universe.id] = new
            if new != .custom { editing = false }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: universe.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            RemoteImage(urlString: UniverseArt.background(universe.hero), width: 900, contentMode: .fill, placeholderSeed: universe.name, systemPlaceholder: "sparkles")
            LinearGradient(colors: [.black.opacity(0.25), .clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(universe.name).font(.system(size: 30, weight: .heavy, design: AetherTypography.design)).shadow(color: .black.opacity(0.5), radius: 6)
                Text(universe.summary).font(.subheadline).foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 14) {
                    stat("\(universe.films.count)", "film")
                    stat("\(universe.series.count)", "serie")
                    if let years = universe.years { stat("\(years.lowerBound)–\(years.upperBound)", "anni") }
                    Spacer(minLength: 0)
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 5)
                        Circle().trim(from: 0, to: progress.fraction).stroke(Color.white, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(progress.percent)%").font(.caption.weight(.bold)).contentTransition(.numericText()).animation(.default, value: progress.percent)
                    }
                    .frame(width: 50, height: 50)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(progress.percent) per cento visto")
                }
                if let next = progress.next {
                    Button { open(next) } label: {
                        Label(progress.watched == 0 ? "Inizia da «\(next.name)»" : "Prossimo: «\(next.name)»", systemImage: "play.fill").lineLimit(1)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                } else {
                    Label("Universo completato", systemImage: "checkmark.seal.fill").font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 340)
        .clipped()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.75))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The order is chosen from a menu, as in the concept: «In ordine cronologico ⌄».
            Menu {
                Picker("Ordine", selection: $order) {
                    ForEach(UniverseOrder.allCases.filter { $0 != .chronological || universe.hasChronological }, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                HStack {
                    Text("In " + order.title.lowercased()).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.footnote.weight(.bold))
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Corner.control, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 1))
            }
            .foregroundStyle(Color.primary)
            Text(universe.trust(of: order).label).font(.caption).foregroundStyle(Color.aetherSecondary)
            if order == .chronological, let note = universe.chronologicalNote {
                Text(note).font(.caption).foregroundStyle(Color.aetherSecondary)
            }
            if order == .custom {
                HStack {
                    Button(editing ? "Fatto" : "Riordina") { editing.toggle() }.buttonStyle(.aetherSecondary)
                    if custom != nil {
                        Button("Ripristina") { settings.value.content.universes.customOrders[universe.id] = nil }.buttonStyle(.aetherSecondary)
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { item in
                        Button { withAnimation(.snappy) { filter = item } } label: {
                            Text(item.rawValue).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 7)
                                .background(filter == item ? Color.accentColor : Color.primary.opacity(0.1), in: Capsule())
                                .foregroundStyle(filter == item ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Three posters a row, each with its place in the order and a check when it has been seen.
    private var grid: some View {
        let ordered = shown
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                let source = sources[entry.id]
                Button { open(entry) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topLeading) {
                            RemoteImage(urlString: UniverseArt.poster(entry.id), width: 300, placeholderSeed: entry.name, systemPlaceholder: "film")
                                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Corner.control, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
                            Text("\(index + 1)").font(.caption2.weight(.heavy)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(6)
                            if source != nil {
                                VStack { Spacer(); HStack { Spacer()
                                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).font(.title3).foregroundStyle(.green, .white).padding(6)
                                } }
                            }
                            if entry.isSeries {
                                VStack { HStack { Spacer(); Text("SERIE").font(.system(size: 8, weight: .heavy)).padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(settings.accentColor, in: Capsule()).foregroundStyle(settings.accentColor.readableForeground).padding(6) }; Spacer() }
                            }
                        }
                        Text(entry.name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(String(entry.year)).font(.caption2).foregroundStyle(Color.aetherSecondary)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { toggleWatched(entry, source: source) } label: { Label(source == nil ? "Segna come visto" : "Togli il segno di visto", systemImage: "checkmark.circle") }
                    Button { open(entry) } label: { Label("Apri la scheda", systemImage: "info.circle") }
                }
                .accessibilityLabel("\(index + 1). \(entry.name), \(entry.year)" + (source != nil ? ", visto" : ""))
                .accessibilityHint("Apre la scheda; tieni premuto per segnarlo come visto")
            }
        }
        .padding(.horizontal, Theme.pageMargin)
    }

    /// The actors who come back in the titles of this universe (from the cast the addons give), each one a door to the search for the person.
    @ViewBuilder
    private var recurringCast: some View {
        if !recurring.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("🎭 Attori che tornano").font(.title3.weight(.bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recurring, id: \.name) { person in
                            Button {
                                router.pendingSearch = person.name
                                router.universeSheet = false
                                router.tab = .search
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.fill")
                                    Text(person.name).font(.subheadline.weight(.semibold))
                                    Text("\(person.count)").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 1).background(.white.opacity(0.2), in: Capsule())
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Cerca la persona")
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }

    @ViewBuilder
    private var linkedUniverses: some View {
        let linked = UniverseCatalog.linked(to: universe.id)
        if !linked.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("🔗 Universi collegati").font(.title3.weight(.bold))
                ForEach(linked, id: \.universe.id) { item in
                    NavigationLink(value: item.universe) {
                        HStack(spacing: 12) {
                            RemoteImage(urlString: UniverseArt.background(item.universe.hero), width: 300, contentMode: .fill, placeholderSeed: item.universe.name, systemPlaceholder: "sparkles")
                                .frame(width: 96, height: 60).clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.universe.name).font(.subheadline.weight(.bold))
                                Text(item.note).font(.caption).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Color.aetherSecondary)
                        }
                        .padding(12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.pageMargin)
        }
    }

    private func loadRecurring() async {
        let films = Array(universe.films.prefix(10))
        let service = env.service
        var counts: [String: Int] = [:]
        await withTaskGroup(of: [String].self) { group in
            for entry in films {
                group.addTask {
                    let fallback = MetaItem(id: entry.id, type: entry.type, name: entry.name)
                    return await service.meta(type: entry.type, id: entry.id, fallback: fallback).meta.cast.prefix(6).map { $0 }
                }
            }
            for await names in group { for name in names { counts[name, default: 0] += 1 } }
        }
        recurring = counts.filter { $0.value >= 2 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(12).map { (name: $0.key, count: $0.value) }
    }

    private func open(_ entry: UniverseEntry) {
        router.detail = MetaRoute(type: entry.type, id: entry.id, preview: MetaItem(id: entry.id, type: entry.type, name: entry.name, poster: UniverseArt.poster(entry.id)))
    }

    private func toggleWatched(_ entry: UniverseEntry, source: WatchedTitles.Source?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch source {
        case nil:
            settings.value.content.diary.add(DiaryEntry(metaID: entry.id, type: entry.type, name: entry.name, poster: UniverseArt.poster(entry.id), year: String(entry.year)))
        case .diary: settings.value.content.diary.removeAll(metaID: entry.id)
        case .history: break
        }
    }

    private func moveEntries(_ source: IndexSet, _ destination: Int) {
        guard order == .custom, filter == .all else { return }
        var ids = universe.ordered(.custom, custom: custom).map { $0.id }
        ids.move(fromOffsets: source, toOffset: destination)
        settings.value.content.universes.customOrders[universe.id] = ids
    }
}

/// The Home row of universes: the ones the viewer follows or has started first, then the biggest.
struct HomeUniverseRow: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        let watched = Set(WatchedTitles.sources(library: library, diary: settings.value.content.diary).keys)
        let options = settings.value.content.universes
        let scored = UniverseCatalog.all.map { universe -> (UniverseDefinition, UniverseProgress, Int) in
            let progress = UniverseProgress.compute(universe, order: .release, watchedIDs: watched)
            let rank = options.followed.contains(universe.id) ? 0 : (progress.watched > 0 && !progress.isComplete ? 1 : 2)
            return (universe, progress, rank)
        }
        let list = scored.sorted { $0.2 < $1.2 }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Universe")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(list, id: \.0.id) { item in
                        NavigationLink(value: item.0) { UniverseCard(universe: item.0, progress: item.1, wide: true) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
            }
        }
    }
}
