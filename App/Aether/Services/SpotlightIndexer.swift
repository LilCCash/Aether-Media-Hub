import CoreSpotlight
import UIKit
import UniformTypeIdentifiers
import AetherCore

/// One title in the system search.
struct SpotlightTitle: Codable, Hashable {
    var id: String
    var type: String
    var name: String
    var info: String?
    var poster: String?
    var background: String?
}

/// Puts titles in the system search so they can be found from the Home screen: the library (watchlist, favourites), what was watched, and the
/// last few hundred titles the app showed (the newest drop out first). Only on the phone; nothing is sent anywhere.
@MainActor
enum SpotlightIndexer {
    static let domain = "app.aether.library"
    private static let seenKey = "aether.spotlight.seen.v1"
    /// Le scelte di Impostazioni ▸ Indicizzazione (aggiornate dall'ambiente a ogni modifica).
    static var options = IndexingSettings()
    private static var seenLimit: Int { return options.limit }
    /// Vero mentre «Indicizza ora» lavora: l'aggiornamento automatico aspetta.
    private(set) static var busy = false
    private static var seen: [SpotlightTitle] = {
        guard let data = UserDefaults.standard.data(forKey: SpotlightIndexer.seenKey),
              let decoded = try? JSONDecoder().decode([SpotlightTitle].self, from: data) else { return [] }
        return decoded
    }()
    private static var library: [SpotlightTitle] = []
    private static var pending: Task<Void, Never>?
    /// Posters that could not be fetched: not asked for again until the app is reopened.
    private static var failedPosters = Set<String>()
    private static let posterDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("spotlight-posters", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func posterFile(_ id: String) -> URL {
        let name = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return posterDirectory.appendingPathComponent(name + ".jpg")
    }

    /// Titles the app showed (catalogs, search, what was watched): kept, up to a limit, and indexed a few seconds later.
    static func record(_ items: [MetaItem]) {
        if merge(items) { schedule() }
    }

    /// Aggiunge i titoli all'elenco dei visti, senza avviare l'indicizzazione. Dice se è cambiato qualcosa.
    @discardableResult
    private static func merge(_ items: [MetaItem]) -> Bool {
        var changed = false
        for item in items where !item.name.isEmpty && (item.type == "movie" || item.type == "series") {
            if let index = seen.firstIndex(where: { $0.id == item.id }) {
                if seen[index].poster == nil, let poster = item.poster {
                    seen[index].poster = poster
                    changed = true
                }
                if seen[index].background == nil, let background = item.background {
                    seen[index].background = background
                    changed = true
                }
                continue
            }
            seen.append(SpotlightTitle(id: item.id, type: item.type, name: item.name, info: item.releaseInfo, poster: item.poster, background: item.background))
            changed = true
        }
        guard changed else { return false }
        if seen.count > seenLimit { seen.removeFirst(seen.count - seenLimit) }
        if let data = try? JSONEncoder().encode(seen) { UserDefaults.standard.set(data, forKey: seenKey) }
        return true
    }

    static func setLibrary(_ entries: [LibraryEntry]) {
        library = entries.filter { !$0.isRemoved }.map { SpotlightTitle(id: $0.id, type: $0.type, name: $0.name, info: $0.releaseInfo, poster: $0.poster, background: $0.background) }
        schedule()
    }

    private static func schedule() {
        guard options.automatic, !busy else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { reindexNow() }
        }
    }

    /// I titoli da indicizzare: prima la libreria, poi i più recenti tra i visti, senza doppioni e fino al numero scelto.
    static func titlesToIndex() -> [SpotlightTitle] {
        var ids = Set<String>()
        var titles: [SpotlightTitle] = []
        for title in library + seen.reversed() where ids.insert(title.id).inserted {
            titles.append(title)
            if titles.count >= options.limit { break }
        }
        return titles
    }

    private static func buildItems(_ titles: [SpotlightTitle]) -> [CSSearchableItem] {
        return titles.map { title -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: UTType.content)
            attributes.title = title.name
            attributes.contentDescription = [title.type == "movie" ? "Film" : "Serie", title.info].compactMap { $0 }.joined(separator: " · ")
            // Spotlight matches words: "Spider-Man" must also be found as "Spiderman" or "Spider Man".
            attributes.keywords = Array(Set([title.name, title.name.replacingOccurrences(of: "-", with: ""),
                                             title.name.replacingOccurrences(of: "-", with: " ")]))
            let file = posterFile(title.id)
            if FileManager.default.fileExists(atPath: file.path) { attributes.thumbnailURL = file }
            return CSSearchableItem(uniqueIdentifier: "\(title.type)/\(title.id)", domainIdentifier: domain, attributeSet: attributes)
        }
    }

    private static func reindexNow() {
        guard !busy else { return }
        let titles = titlesToIndex()
        let items = buildItems(titles)
        fetchMissingPosters(for: titles)
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            if !items.isEmpty { index.indexSearchableItems(items) { _ in } }
        }
    }

    // MARK: Indicizza ora

    enum IndexProgress: Equatable {
        case collecting(done: Int, target: Int)
        case indexing
        case posters(done: Int, total: Int)
        case finished(titles: Int, posters: Int)
        case cancelled
    }

    /// Sostituisce tutto l'indice di Aether e aspetta che il sistema abbia finito.
    private static func replaceIndex(_ items: [CSSearchableItem]) async {
        let index = CSSearchableIndex.default()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                if items.isEmpty {
                    continuation.resume()
                } else {
                    index.indexSearchableItems(items) { _ in continuation.resume() }
                }
            }
        }
    }

    /// «Indicizza ora»: raccoglie i titoli (se serve, dai cataloghi), li indicizza e scarica le locandine, raccontando i progressi.
    static func indexNow(service: AddonService, report: @escaping @MainActor (IndexProgress) -> Void) async {
        guard !busy else { return }
        busy = true
        pending?.cancel()
        defer { busy = false }
        let target = options.limit

        // 1. Titoli: quelli che l'app già conosce, poi i cataloghi finché si arriva al numero scelto.
        report(.collecting(done: titlesToIndex().count, target: target))
        if options.fillFromCatalogs && titlesToIndex().count < target {
            let handles = await service.handles()
            let refs = RequestPlanner.feedCatalogs(handles: handles).filter { (ref: CatalogRef) -> Bool in
                let kind = ContentTypes.canonicalID(ref.catalog.type)
                return kind == "movie" || kind == "series"
            }
            for ref in refs {
                if Task.isCancelled { report(.cancelled); return }
                if titlesToIndex().count >= target { break }
                let pager = CatalogPager(ref: ref, service: service)
                var pages = 0
                while titlesToIndex().count < target, pages < 10 {
                    if Task.isCancelled { report(.cancelled); return }
                    guard await pager.hasMore else { break }
                    guard let page = try? await pager.loadNext(), !page.newItems.isEmpty else { break }
                    merge(page.newItems)
                    pages += 1
                    report(.collecting(done: min(titlesToIndex().count, target), target: target))
                }
            }
        }
        let titles = titlesToIndex()

        // 2. Indice.
        report(.indexing)
        await replaceIndex(buildItems(titles))

        // 3. Locandine: tutte quelle che mancano, qualche scarico alla volta; poi l'indice si rifà con le immagini.
        var downloaded = 0
        if options.includePosters {
            failedPosters.removeAll()
            let jobs = titles.compactMap { (title: SpotlightTitle) -> (id: String, remote: URL, file: URL)? in
                let file = posterFile(title.id)
                guard !FileManager.default.fileExists(atPath: file.path),
                      let address = PosterOverrides.shared.url(for: title.id) ?? title.poster, let remote = URL(string: address) else { return nil }
                return (title.id, remote, file)
            }
            report(.posters(done: 0, total: jobs.count))
            var done = 0
            var next = 0
            await withTaskGroup(of: Bool.self) { (group: inout TaskGroup<Bool>) in
                func launch() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask(priority: .utility) { await downloadPoster(from: job.remote, to: job.file) }
                }
                for _ in 0..<4 { launch() }
                while let ok = await group.next() {
                    done += 1
                    if ok { downloaded += 1 }
                    report(.posters(done: done, total: jobs.count))
                    if Task.isCancelled { group.cancelAll(); continue }
                    launch()
                }
            }
            if downloaded > 0 {
                report(.indexing)
                await replaceIndex(buildItems(titles))
            }
        }
        report(Task.isCancelled ? .cancelled : .finished(titles: titles.count, posters: posterCount()))
    }

    /// Scarica una locandina e la salva piccola (200×300, JPEG).
    private nonisolated static func downloadPoster(from remote: URL, to file: URL) async -> Bool {
        guard let (data, _) = try? await URLSession.shared.data(from: remote), let image = UIImage(data: data),
              let small = image.preparingThumbnail(of: CGSize(width: 200, height: 300)), let jpeg = small.jpegData(compressionQuality: 0.7) else { return false }
        return (try? jpeg.write(to: file)) != nil
    }

    // MARK: Stato

    static func posterCount() -> Int {
        return (try? FileManager.default.contentsOfDirectory(at: posterDirectory, includingPropertiesForKeys: nil))?.count ?? 0
    }

    static func posterBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: posterDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { (total: Int64, url: URL) -> Int64 in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static var knownTitleCount: Int { return titlesToIndex().count }

    /// Toglie dal sistema i titoli di Aether e cancella le locandine salvate.
    static func clearAll() async {
        pending?.cancel()
        await replaceIndex([])
        for file in (try? FileManager.default.contentsOfDirectory(at: posterDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        failedPosters.removeAll()
    }

    /// Downloads the posters the index does not have yet (small JPEGs, a few at a time); when some arrive the index is made again with them.
    private static func fetchMissingPosters(for titles: [SpotlightTitle]) {
        var jobs: [(id: String, remote: URL, file: URL)] = []
        for title in titles where jobs.count < 40 {
            let file = posterFile(title.id)
            guard !FileManager.default.fileExists(atPath: file.path), !failedPosters.contains(title.id),
                  let address = PosterOverrides.shared.url(for: title.id) ?? title.poster, let remote = URL(string: address) else { continue }
            jobs.append((title.id, remote, file))
        }
        guard !jobs.isEmpty else { return }
        let work = jobs
        Task.detached(priority: .utility) {
            var arrived = false
            for job in work {
                if let (data, _) = try? await URLSession.shared.data(from: job.remote), let image = UIImage(data: data),
                   let small = image.preparingThumbnail(of: CGSize(width: 200, height: 300)), let jpeg = small.jpegData(compressionQuality: 0.7),
                   (try? jpeg.write(to: job.file)) != nil {
                    arrived = true
                } else {
                    await MainActor.run { _ = failedPosters.insert(job.id) }
                }
            }
            if arrived { await MainActor.run { schedule() } }
        }
    }

    /// The title page for an indexed title, with what is known about it already (name, poster) so it does not open empty. The stored backdrop is not used: until the real page arrives the poster, blurred, fills the header.
    static func route(forIdentifier identifier: String) -> MetaRoute? {
        let parts = identifier.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let known = (library + seen).first { $0.id == parts[1] }
        let preview = known.map { MetaItem(id: $0.id, type: parts[0], name: $0.name, poster: $0.poster, releaseInfo: $0.info) }
        return MetaRoute(type: parts[0], id: parts[1], preview: preview)
    }
}
