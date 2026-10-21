import Foundation
import AetherCore

/// Pure rules about torrent streams and TorBox, kept apart from the views so they can be tested without a UI.
enum DebridStreamLogic {
    static func isTorrent(_ stream: AddonStream) -> Bool {
        if case .torrent = stream.source { return true }
        return false
    }

    /// 40 lowercase hex characters, or nil for a stream that is not a torrent or whose hash is not valid.
    static func canonicalHash(of stream: AddonStream) -> String? {
        guard case .torrent(let hash, _, _) = stream.source else { return nil }
        return DebridHash.normalize(hash)
    }

    /// The canonical hashes of the torrent rows, each once, in list order.
    static func hashes(in list: [RankedStream]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for item in list {
            guard let hash = canonicalHash(of: item.stream) else { continue }
            if seen.insert(hash).inserted { result.append(hash) }
        }
        return result
    }

    /// Torrents known to be in the provider's cache move ahead of the other torrents. Every row keeps the slot it had:
    /// only the slots occupied by torrents are refilled, so direct links never change position.
    static func cachedFirst(_ list: [RankedStream], statuses: [String: DebridCacheStatus]) -> [RankedStream] {
        var slots: [Int] = []
        var cached: [RankedStream] = []
        var others: [RankedStream] = []
        for (index, item) in list.enumerated() {
            guard isTorrent(item.stream) else { continue }
            slots.append(index)
            if let hash = canonicalHash(of: item.stream), statuses[hash] == DebridCacheStatus.cached {
                cached.append(item)
            } else {
                others.append(item)
            }
        }
        if slots.isEmpty || cached.isEmpty { return list }
        let ordered = cached + others
        var result = list
        for (position, slot) in slots.enumerated() {
            result[slot] = ordered[position]
        }
        return result
    }

    /// What "choose the best source automatically" may pick. With TorBox configured a torrent qualifies only when the cache
    /// check said it is in cache: automatic choice never starts a download and never guesses. Without TorBox nothing is filtered
    /// (a torrent can then only be playable through an external streaming server, which is the user's explicit choice).
    static func autoSelectable(_ list: [RankedStream], statuses: [String: DebridCacheStatus],
                               debridConfigured: Bool) -> [RankedStream] {
        if !debridConfigured { return list }
        return list.filter { (item: RankedStream) -> Bool in
            guard isTorrent(item.stream) else { return true }
            guard let hash = canonicalHash(of: item.stream) else { return false }
            return statuses[hash] == DebridCacheStatus.cached
        }
    }

    /// The Stremio id the file matcher needs: the video id of an episode, the title id of a movie.
    static func stremioID(meta: MetaItem, video: Video?) -> String {
        return video?.id ?? meta.id
    }
}

/// Orders progress reports that arrive from the resolver's background actor so that a late one never overwrites a newer one.
final class DebridProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func next() -> Int {
        lock.lock()
        counter += 1
        let value = counter
        lock.unlock()
        return value
    }
}

/// How a TorBox failure is shown by the player.
enum DebridPlayback {
    static let notCachedInPlayer = "Questo contenuto non è nella cache di TorBox, quindi andrebbe prima scaricato. Torna all'elenco delle sorgenti per avviare il download oppure scegli un'altra sorgente."

    static let fileChoiceInPlayer = "Non trovo con certezza il file di questo episodio nel torrent. Chiudi il player e riapri la sorgente dall'elenco: potrai scegliere il file."

    /// The player shows `PlaybackFailure.message`: connectivity problems keep their own kinds (so the network-recovery logic still
    /// applies), everything else is carried in the detail text of an `.unknown` failure.
    static func failure(for error: DebridError) -> PlaybackFailure {
        switch error {
        case .offline:
            return PlaybackFailure(kind: PlaybackFailureKind.offline, detail: error.message)
        case .timeout:
            return PlaybackFailure(kind: PlaybackFailureKind.timeout, detail: error.message)
        case .unreachable:
            return PlaybackFailure(kind: PlaybackFailureKind.unreachable, detail: error.message)
        case .notCached:
            return PlaybackFailure(kind: PlaybackFailureKind.unknown, detail: notCachedInPlayer)
        case .noMatchingFile:
            return PlaybackFailure(kind: PlaybackFailureKind.unknown, detail: fileChoiceInPlayer)
        default:
            return PlaybackFailure(kind: PlaybackFailureKind.unknown, detail: DebridErrorText.message(for: error))
        }
    }

    /// Any error from a TorBox call.
    static func failure(forAny error: Error) -> PlaybackFailure {
        if let debrid = error as? DebridError { return failure(for: debrid) }
        return PlaybackFailure(kind: PlaybackFailureKind.unknown, detail: "Errore imprevisto durante la comunicazione con TorBox.")
    }

    /// A playback error text may echo the URL of the file; the CDN link of a download carries a token, so the text is
    /// run through the same redaction as the diagnostic log before it is kept or shown.
    static func redacted(_ failure: PlaybackFailure) -> PlaybackFailure {
        return PlaybackFailure(kind: failure.kind, detail: Redactor.redact(failure.detail))
    }

    /// The link expired or was refused by the CDN: it must not be reused.
    static func invalidatesResolvedLink(_ failure: PlaybackFailure) -> Bool {
        switch failure.kind {
        case .forbidden, .notFound: return true
        default: return false
        }
    }
}
