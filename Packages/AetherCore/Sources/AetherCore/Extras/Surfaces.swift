import Foundation

// Pure logic behind the widget, the download Live Activity and SharePlay (the platform parts live in the app).

// MARK: Continue watching (widget)

public struct ContinueItem: Equatable, Sendable {
    public var metaID: String
    public var type: String
    public var videoID: String
    public var title: String
    public var subtitle: String?
    public var poster: String?
    public var progress: Double
}

public enum ContinueWatchingPlanner {
    /// Unfinished titles, most recent first, one per title (the latest episode of a series), at most `limit`.
    public static func items(from history: [PlaybackProgress], limit: Int = 6) -> [ContinueItem] {
        var seen = Set<String>()
        var result: [ContinueItem] = []
        for entry in history.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard entry.duration > 0, entry.position >= 20 else { continue }
            let fraction = entry.position / entry.duration
            guard fraction > 0.01, fraction < 0.95, seen.insert(entry.metaID).inserted else { continue }
            var subtitle: String?
            if let season = entry.season, let episode = entry.episode {
                subtitle = ["S\(season)E\(episode)", entry.episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            }
            result.append(ContinueItem(metaID: entry.metaID, type: entry.type, videoID: entry.videoID, title: entry.title, subtitle: subtitle,
                                       poster: entry.poster, progress: min(1, max(0, fraction))))
            if result.count >= limit { break }
        }
        return result
    }
}

// MARK: Downloads (Live Activity)

public struct DownloadSummary: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var fraction: Double
    public var count: Int
}

public enum DownloadActivityPlanner {
    /// What the Live Activity shows for the downloads running now; nil when none is running.
    public static func summary(_ items: [DownloadItem]) -> DownloadSummary? {
        let active = items.filter { $0.state == .downloading }
        guard let first = active.first else { return nil }
        let written = active.reduce(Int64(0)) { $0 + max(0, $1.bytesWritten) }
        let total = active.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
        let fraction = total > 0 ? Double(written) / Double(total) : active.map { $0.fraction }.reduce(0, +) / Double(active.count)
        return DownloadSummary(title: active.count == 1 ? first.title : "\(active.count) download",
                               subtitle: active.count == 1 ? first.subtitle : nil,
                               fraction: min(1, max(0, fraction)), count: active.count)
    }
}

// MARK: Watching together (SharePlay)

/// What one participant tells the others: playing or paused, and where. `sentAt` is the sender's clock (seconds since 1970).
public struct PlaybackSyncMessage: Codable, Equatable, Sendable {
    public var isPlaying: Bool
    public var position: Double
    public var sentAt: Double

    public init(isPlaying: Bool, position: Double, sentAt: Double) {
        self.isPlaying = isPlaying
        self.position = position
        self.sentAt = sentAt
    }
}

public enum PlaybackSyncPlanner {
    public enum Action: Equatable, Sendable {
        case seek(Double), play, pause
    }

    /// What to do locally to follow `remote`. The sender's position is moved forward by the time the message took (capped, because the two
    /// clocks can disagree) when it is playing; a small difference is left alone so that nobody jumps around.
    public static func actions(localPlaying: Bool, localPosition: Double, remote: PlaybackSyncMessage, now: Double, tolerance: Double = 1.5) -> [Action] {
        let lag = remote.isPlaying ? min(3, max(0, now - remote.sentAt)) : 0
        let target = max(0, remote.position + lag)
        var result: [Action] = []
        let limit = remote.isPlaying ? tolerance : 0.4
        if abs(localPosition - target) > limit { result.append(.seek(target)) }
        if remote.isPlaying && !localPlaying { result.append(.play) }
        if !remote.isPlaying && localPlaying { result.append(.pause) }
        return result
    }
}
