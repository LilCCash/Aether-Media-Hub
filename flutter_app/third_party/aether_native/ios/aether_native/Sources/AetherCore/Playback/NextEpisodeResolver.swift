import Foundation

/// Episode navigation, following `MetaItem::next_video` in stremio-core:
/// no crossing into season 0 (specials) from a regular season, unreleased episodes are skipped, live items never advance.
public enum NextEpisodeResolver {
    public static func next(after videoID: String, in meta: MetaItem, now: Date = Date()) -> Video? {
        if meta.isLive { return nil }
        guard let index = meta.videos.firstIndex(where: { $0.id == videoID }) else { return nil }
        let currentSeason = meta.videos[index].season ?? 0
        let nextIndex = index + 1
        guard nextIndex < meta.videos.count else { return nil }
        let candidate = meta.videos[nextIndex]
        let candidateSeason = candidate.season ?? 0
        let released = candidate.released.map { $0 <= now } ?? true
        if (candidateSeason != 0 || currentSeason == candidateSeason) && released {
            return candidate
        }
        return nil
    }

    public static func previous(before videoID: String, in meta: MetaItem) -> Video? {
        if meta.isLive { return nil }
        guard let index = meta.videos.firstIndex(where: { $0.id == videoID }), index > 0 else { return nil }
        return meta.videos[index - 1]
    }

    /// First released, not-yet-watched episode strictly after `videoID`, never entering season 0 from a regular season.
    public static func nextUnwatched(after videoID: String, in meta: MetaItem, watched: Set<String>,
                                     now: Date = Date()) -> Video? {
        var cursor = videoID
        var guardCount = 0
        while let candidate = next(after: cursor, in: meta, now: now), guardCount < 2000 {
            if !watched.contains(candidate.id) { return candidate }
            cursor = candidate.id
            guardCount += 1
        }
        return nil
    }

    /// The episode to play when the user taps "Play" on a series: resume the in-progress one, otherwise the first
    /// unwatched after the last watched, otherwise the first regular-season episode.
    public static func episodeToPlay(in meta: MetaItem, watched: Set<String>, lastWatchedID: String?,
                                     inProgressID: String?, now: Date = Date()) -> Video? {
        if let inProgress = inProgressID, let video = meta.videos.first(where: { $0.id == inProgress }) {
            return video
        }
        if let last = lastWatchedID, let next = nextUnwatched(after: last, in: meta, watched: watched, now: now) {
            return next
        }
        let regular = meta.videos.filter { ($0.season ?? 1) != 0 && ($0.released.map { $0 <= now } ?? true) }
        if let firstUnwatched = regular.first(where: { !watched.contains($0.id) }) { return firstUnwatched }
        return regular.first ?? meta.videos.first
    }
}
