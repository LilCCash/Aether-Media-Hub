import UIKit
import AetherCore

/// The fanart.tv logo of a title, fetched ahead of time (as soon as the title page or the source list opens) and kept in memory,
/// so the preparing page shows it the instant a source is chosen. Without a key nothing is asked.
@MainActor
final class FanartLogoStore {
    static let shared = FanartLogoStore()

    private var images: [String: UIImage] = [:]
    private var missing = Set<String>()
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    /// Already downloaded, or nil.
    func cached(_ metaID: String) -> UIImage? { return images[metaID] }

    /// True when a previous lookup found no logo for this title (the page then shows the title at once).
    func isKnownMissing(_ metaID: String) -> Bool { return missing.contains(metaID) }

    func prefetch(meta: MetaItem, env: AppEnvironment) {
        guard env.fanart.isConfigured, images[meta.id] == nil, tasks[meta.id] == nil, !missing.contains(meta.id) else { return }
        _ = start(meta: meta, env: env)
    }

    func load(meta: MetaItem, env: AppEnvironment) async -> UIImage? {
        if let image = images[meta.id] { return image }
        guard env.fanart.isConfigured, !missing.contains(meta.id) else { return nil }
        let task = tasks[meta.id] ?? start(meta: meta, env: env)
        return await task.value
    }

    private func start(meta: MetaItem, env: AppEnvironment) -> Task<UIImage?, Never> {
        let task = Task { [weak self] () -> UIImage? in
            let image = await FanartLogoStore.download(meta: meta, env: env)
            guard let self else { return image }
            if let image { self.images[meta.id] = image } else { self.missing.insert(meta.id) }
            self.tasks[meta.id] = nil
            return image
        }
        tasks[meta.id] = task
        return task
    }

    /// Films are looked up by IMDb (or TMDB) code, series by their TheTVDB code.
    private static func download(meta: MetaItem, env: AppEnvironment) async -> UIImage? {
        let language = MetadataEnricher.tmdbLanguage(preferred: env.settings.value.content.preferredLanguage)
        let ids = meta.externalIDs
        var found: URL?
        if meta.type == "series" {
            if let tvdb = ids.tvdb { found = await env.fanart.logoURL(kind: .tv, id: String(tvdb), language: language) }
        } else {
            if let imdb = ids.imdb ?? (meta.id.hasPrefix("tt") ? String(meta.id.prefix(while: { $0 != ":" })) : nil) {
                found = await env.fanart.logoURL(kind: .movie, id: imdb, language: language)
            }
            if found == nil, let tmdb = ids.tmdb { found = await env.fanart.logoURL(kind: .movie, id: String(tmdb), language: language) }
        }
        guard let url = found, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }
}
