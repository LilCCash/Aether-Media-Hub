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

private extension UniverseDefinition {
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: universe.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            RemoteImage(urlString: UniverseArt.background(universe.hero), width: 480, contentMode: .fill, placeholderSeed: universe.name, systemPlaceholder: "sparkles")
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(universe.name).font(.system(size: wide ? 20 : 17, weight: .heavy, design: .rounded)).lineLimit(2).minimumScaleFactor(0.8)
                Text(universe.countsLine).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                if progress.watched > 0 {
                    ProgressView(value: progress.fraction).tint(.white).scaleEffect(y: 0.7)
                    Text("\(progress.watched)/\(progress.total) visti").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(width: wide ? 250 : nil, height: wide ? 150 : 130)
        .frame(maxWidth: wide ? 250 : .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(universe.name), \(universe.countsLine)" + (progress.watched > 0 ? ", \(progress.percent) per cento visto" : ""))
    }
}

// MARK: Detail

struct UniverseDetailView: View {
    let universe: UniverseDefinition
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var router: AppRouter
    @State private var order: UniverseOrder = .release
    @State private var filter: Filter = .all
    @State private var editing = false

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
            List {
                Section { header.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                Section {
                    controls.listRowBackground(Color.clear)
                }
                Section {
                    ForEach(shown) { entry in row(entry) }
                        .onMove { source, destination in moveEntries(source, destination) }
                } header: {
                    Text(order.title + " · " + universe.trust(of: order).label).font(.caption).textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(editing ? .active : .inactive))
        }
        .navigationTitle(universe.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings.value.content.universes.toggleFollow(universe.id) } label: {
                    Image(systemName: follows ? "star.fill" : "star")
                }
                .accessibilityLabel(follows ? "Non seguire più l'universo" : "Segui l'universo")
            }
        }
        .onAppear { order = settings.value.content.universes.lastOrder[universe.id] ?? .release }
        .onChange(of: order) { _, new in
            settings.value.content.universes.lastOrder[universe.id] = new
            if new != .custom { editing = false }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: universe.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            RemoteImage(urlString: UniverseArt.background(universe.hero), width: 800, contentMode: .fill, placeholderSeed: universe.name, systemPlaceholder: "sparkles")
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(universe.name).font(.system(size: 30, weight: .heavy, design: .rounded))
                Text(universe.summary).font(.subheadline).foregroundStyle(.white.opacity(0.88))
                HStack(spacing: 14) {
                    stat("\(universe.entries.count)", "contenuti")
                    stat("\(universe.films.count)", "film")
                    stat("\(universe.series.count)", "serie")
                    if let years = universe.years { stat("\(years.lowerBound)–\(years.upperBound)", "anni") }
                }
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction).tint(.white)
                    Text("\(progress.percent)%").font(.subheadline.weight(.bold))
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
        .frame(minHeight: 330)
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
            Picker("Ordine", selection: $order) {
                ForEach(UniverseOrder.allCases.filter { $0 != .chronological || universe.hasChronological }, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if order == .chronological, let note = universe.chronologicalNote {
                Text(note).font(.caption).foregroundStyle(Color.aetherSecondary)
            }
            if order == .custom {
                HStack {
                    Button(editing ? "Fatto" : "Riordina") { editing.toggle() }.buttonStyle(.bordered)
                    if custom != nil {
                        Button("Ripristina") { settings.value.content.universes.customOrders[universe.id] = nil }.buttonStyle(.bordered)
                    }
                }
            }
            Picker("Mostra", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    private func row(_ entry: UniverseEntry) -> some View {
        let source = sources[entry.id]
        return HStack(spacing: 12) {
            Button { open(entry) } label: {
                HStack(spacing: 12) {
                    RemoteImage(urlString: UniverseArt.poster(entry.id), width: 140, placeholderSeed: entry.name, systemPlaceholder: "film")
                        .frame(width: 52, height: 78).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(entry.year) · \(entry.isSeries ? "Serie" : "Film")").font(.caption).foregroundStyle(Color.aetherSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            Button { toggleWatched(entry, source: source) } label: {
                Image(systemName: source == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title2).foregroundStyle(source == nil ? Color.aetherSecondary : Color.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(source == nil ? "Segna come visto" : "Visto")
            .accessibilityHint(source == .history ? "Visto con il player; si toglie dalla cronologia" : "")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button { toggleWatched(entry, source: source) } label: { Label(source == nil ? "Segna come visto" : "Togli il segno di visto", systemImage: "checkmark.circle") }
            Button { open(entry) } label: { Label("Apri la scheda", systemImage: "info.circle") }
        }
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
