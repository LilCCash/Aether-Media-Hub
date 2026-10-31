import UIKit
import AetherCore

/// The logo of a title (transparent PNG), fetched ahead of time (as soon as a title page, a source list or a Home row shows it) and
/// kept on the phone, so the preparing page shows it the instant a source is chosen. Looked for in this order, each one only when the
/// one before has none: fanart.tv (with the viewer's key), TMDB (the viewer's key), the logo the catalog itself gives, the public
/// logo service the catalogs use. A title without any logo is not asked again for a day.
@MainActor
final class FanartLogoStore {
    static let shared = FanartLogoStore()

    private static let missingKey = "aether.logos.missing.v1"
    private static let missingFor: TimeInterval = 24 * 3600

    private var images: [String: UIImage] = [:]
    private var missingUntil: [String: Date]
    private var tasks: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: FanartLogoStore.missingKey) as? [String: Double] ?? [:]
        missingUntil = stored.mapValues { Date(timeIntervalSince1970: $0) }.filter { $0.value > Date() }
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ metaID: String) -> URL {
        let name = metaID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(name + ".png")
    }

    /// Already downloaded (in memory or on the phone), or nil.
    func cached(_ metaID: String) -> UIImage? {
        if let image = images[metaID] { return image }
        if let data = try? Data(contentsOf: file(metaID)), let image = UIImage(data: data) {
            images[metaID] = image
            return image
        }
        return nil
    }

    /// True when a recent lookup found no logo for this title (the page then shows the title at once).
    func isKnownMissing(_ metaID: String) -> Bool {
        guard let until = missingUntil[metaID] else { return false }
        return until > Date()
    }

    func prefetch(meta: MetaItem, env: AppEnvironment) {
        guard cached(meta.id) == nil, tasks[meta.id] == nil, !isKnownMissing(meta.id) else { return }
        _ = start(meta: meta, env: env)
    }

    /// Prefetches a list of titles one after the other (a Home row), without opening dozens of requests at once.
    func prefetch(_ metas: [MetaItem], env: AppEnvironment) {
        Task { @MainActor in
            for meta in metas.prefix(24) {
                prefetch(meta: meta, env: env)
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    func load(meta: MetaItem, env: AppEnvironment) async -> UIImage? {
        if let image = cached(meta.id) { return image }
        guard !isKnownMissing(meta.id) else { return nil }
        let task = tasks[meta.id] ?? start(meta: meta, env: env)
        return await task.value
    }

    private func start(meta: MetaItem, env: AppEnvironment) -> Task<UIImage?, Never> {
        let task = Task { [weak self] () -> UIImage? in
            let found = await FanartLogoStore.download(meta: meta, env: env)
            guard let self else { return found?.image }
            if let found {
                self.images[meta.id] = found.image
                try? found.data.write(to: self.file(meta.id), options: .atomic)
            } else {
                self.missingUntil[meta.id] = Date().addingTimeInterval(FanartLogoStore.missingFor)
                let stored = self.missingUntil.mapValues { $0.timeIntervalSince1970 }
                UserDefaults.standard.set(stored, forKey: FanartLogoStore.missingKey)
            }
            self.tasks[meta.id] = nil
            return found?.image
        }
        tasks[meta.id] = task
        return task
    }

    private static func fetch(_ url: URL?) async -> (data: Data, image: UIImage)? {
        guard let url, url.scheme?.lowercased() == "https",
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        return (data, image)
    }

    private static func download(meta: MetaItem, env: AppEnvironment) async -> (data: Data, image: UIImage)? {
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        let ids = meta.externalIDs
        let imdb = ids.imdb ?? (meta.id.hasPrefix("tt") ? String(meta.id.prefix(while: { $0 != ":" })) : nil)
        // 1. fanart.tv, with the viewer's key. Series are known to it by their TheTVDB code, which TMDB can tell.
        if env.fanart.isConfigured {
            var url: URL?
            if meta.type == "series" {
                let tvdb: Int?
                if let known = ids.tvdb { tvdb = known } else { tvdb = await env.metadata.tvdbID(for: meta) }
                if let tvdb { url = await env.fanart.logoURL(kind: .tv, id: String(tvdb), language: language) }
            } else {
                if let imdb { url = await env.fanart.logoURL(kind: .movie, id: imdb, language: language) }
                if url == nil, let tmdb = ids.tmdb { url = await env.fanart.logoURL(kind: .movie, id: String(tmdb), language: language) }
            }
            if let found = await fetch(url) { return found }
        }
        // 2. TMDB, with the viewer's key.
        if let found = await fetch(await env.metadata.logoURL(for: meta, language: language)) { return found }
        // 3. The logo the catalog gave with the title.
        if let raw = meta.logo, let found = await fetch(URL(string: raw)) { return found }
        // 4. The public logo service the catalogs use, by IMDb code.
        if let imdb, let found = await fetch(URL(string: "https://images.metahub.space/logo/medium/\(imdb)/img")) { return found }
        return nil
    }
}
