import SwiftUI
import AVFoundation
import AetherCore

/// Episodes of a series and season packs. Part of `PlayerViewModel`, split by subject so that a change
/// to one part cannot disturb the others by accident (same behaviour as when it was one file).
extension PlayerViewModel {
    // MARK: Episodes

    /// How an episode is opened: by the viewer's settings, from the pack already open, by searching the addons, or from a list.
    enum EpisodeVia { case automatic, pack, search, pick }

    func play(episode: Video, via: EpisodeVia = .automatic) async {
        await switchEpisode(to: episode, via: via, userInitiated: true)
    }

    func playPrevious() async {
        if let previous = previousEpisode { await switchEpisode(to: previous, via: .automatic, userInitiated: true) }
    }

    /// `userInitiated` is false for the automatic jump at the end of an episode: it never stops to ask for a source.
    func playNext(userInitiated: Bool = true) async {
        guard let next = nextEpisode else { return }
        await switchEpisode(to: next, via: .automatic, userInitiated: userInitiated)
    }

    // MARK: Season packs

    var currentTorrentStream: AddonStream? {
        var stream = currentStream
        if stream == nil, case .stream(let requested) = request.source { stream = requested }
        guard let found = stream, case .torrent = found.source else { return nil }
        return found
    }

    func refreshPack() {
        guard let stream = currentTorrentStream, case .torrent(let hash, _, _) = stream.source else {
            if !packFiles.isEmpty { packFiles = [] }
            return
        }
        let files = env.debrid.packFiles(forHash: hash)
        if files != packFiles { packFiles = files }
    }

    /// The episode is inside the file that is playing (a season pack): it can be opened from there without searching.
    func isInPack(_ video: Video) -> Bool {
        guard let season = video.season, let episode = video.episode else { return false }
        return packFiles.contains { (file: DebridPackFile) -> Bool in file.contains(season: season, episode: episode) }
    }

    var packEpisodeCount: Int { return packFiles.count }

    /// The episode is in the Downloads and plays from the file.
    func isDownloaded(_ video: Video) -> Bool {
        return env.downloads.completedItem(metaID: meta.id, videoID: video.id) != nil
    }

    func switchEpisode(to video: Video, via: EpisodeVia, userInitiated: Bool) async {
        guard !isResolvingNext else { return }
        var way = via
        if way == .automatic {
            // A downloaded episode opens from its file, offline too, before any search (switch it off in the settings).
            if playback.preferDownloaded, let file = env.downloads.completedItem(metaID: meta.id, videoID: video.id) {
                await commitDownloadedEpisode(video, item: file)
                return
            }
            if userInitiated && playback.episodeSwitch == .askEachTime {
                sourcePickerEpisode = video
                return
            }
            way = (playback.preferPack && isInPack(video)) ? .pack : .search
        }
        switch way {
        case .pick:
            sourcePickerEpisode = video
        case .pack:
            if await switchWithinPack(video) { return }
            await switchBySearch(video)
        case .search, .automatic:
            await switchBySearch(video)
        }
    }

    /// Opens the episode from the torrent that is already playing: the debrid service picks the file of that episode. False when it
    /// cannot (the file is not there, the service refuses): the caller then searches the addons as usual.
    func switchWithinPack(_ video: Video) async -> Bool {
        guard let stream = currentTorrentStream,
              let packRequest = DebridRequest(stream: stream, stremioID: video.id, mode: .cachedOnly),
              let best = StreamSelector.rank([stream], preferences: env.streamPreferences()).first else { return false }
        isResolvingNext = true
        defer { isResolvingNext = false }
        countdownTask?.cancel()
        nextCountdown = nil
        statusMessage = "Apro \(video.episodeLabel ?? "l'episodio") dal pack…"
        recordProgress(force: true)
        progressSuspended = true
        engine.pause()
        do {
            let result = try await env.debrid.resolve(packRequest, onProgress: nil)
            env.debrid.stashResolution(result, for: stream, stremioID: video.id)
        } catch {
            statusMessage = "Questo episodio non è nel pack: cerco una sorgente…"
            return false
        }
        await commitEpisode(video, best: best, ranked: [best])
        return true
    }

    /// The viewer chose a source for the episode from the list.
    func playEpisode(_ video: Video, with item: RankedStream, ranked: [RankedStream]) async {
        guard !isResolvingNext else { return }
        isResolvingNext = true
        defer { isResolvingNext = false }
        countdownTask?.cancel()
        nextCountdown = nil
        statusMessage = "Apro \(video.episodeLabel ?? "l'episodio")…"
        recordProgress(force: true)
        progressSuspended = true
        engine.pause()
        await commitEpisode(video, best: item, ranked: ranked)
    }

    /// Opens the episode from the file in the Downloads: no search, no network.
    func commitDownloadedEpisode(_ video: Video, item: DownloadItem) async {
        guard !isResolvingNext else { return }
        isResolvingNext = true
        defer { isResolvingNext = false }
        countdownTask?.cancel()
        nextCountdown = nil
        statusMessage = "Apro \(video.episodeLabel ?? "l'episodio") dai download…"
        recordProgress(force: true)
        progressSuspended = true
        engine.pause()
        currentVideo = video
        currentStream = nil
        sourceName = "Download"
        request.video = video
        request.source = .download(item)
        engineChosenByFallback = false
        alternatives = []
        resetSubtitleStateForNewVideo()
        loadSkipSegments()
        lastRecordedPosition = -100
        didFinish = false
        nextStreamsTask = nil
        nextLinkTask?.cancel()
        nextLinkTask = nil
        updateNextEpisode()
        nowPlaying.setMetadata(title: meta.name, subtitle: episodeSubtitle(),
                               artworkURL: (video.thumbnail ?? meta.background ?? meta.poster).flatMap { URL.lenient($0) }, loader: env.images)
        await beginPlayback(startOverride: nil)
        await loadSubtitleOptions()
    }

    func switchBySearch(_ video: Video) async {
        guard !isResolvingNext else { return }
        isResolvingNext = true
        countdownTask?.cancel()
        nextCountdown = nil
        statusMessage = "Cerco la sorgente per \(video.episodeLabel ?? "l'episodio")…"
        defer { isResolvingNext = false }

        // Persist where we left the current episode before moving on, then stop recording until the new source is loaded:
        // finding it (and, for a torrent, TorBox's answer) can take a while and the old episode would be saved as the new one.
        recordProgress(force: true)
        progressSuspended = true
        engine.pause()

        let result: (streams: [AddonStream], errors: [String: AddonError])
        if let prefetched = nextStreamsTask, video.id == nextEpisode?.id {
            result = await prefetched.value
        } else {
            result = await env.service.allStreams(type: meta.type, videoID: video.id, debrid: env.debrid.streamContext)
        }
        let ranked = StreamSelector.rank(result.streams, preferences: env.streamPreferences())
        let binge = currentStream?.behaviorHints.bingeGroup ?? env.bingeGroup(forMeta: meta.id)
        let choices = await debridAutoSelectable(ranked)
        guard let best = StreamSelector.autoSelect(choices, previousBingeGroup: binge, ordering: env.streamPreferences().ordering) else {
            statusMessage = nil
            handleFailure(PlaybackFailure(kind: .notFound, detail: "Nessuna sorgente riproducibile per \(video.episodeLabel ?? "questo episodio")."))
            return
        }
        await commitEpisode(video, best: best, ranked: ranked)
    }

    /// Puts the chosen source on screen for the episode: state, subtitles, skip data, then playback.
    func commitEpisode(_ video: Video, best: RankedStream, ranked: [RankedStream]) async {
        currentVideo = video
        currentStream = best.stream
        reliabilityCounted = false
        sourceName = best.stream.name ?? best.stream.addonName ?? "Sorgente"
        request.video = video
        request.source = .stream(best.stream)
        engineChosenByFallback = false
        alternatives = ranked.filter { $0.info.support.isPlayable && $0.id != best.id }
        resetSubtitleStateForNewVideo()
        loadSkipSegments()
        lastRecordedPosition = -100
        didFinish = false
        nextStreamsTask = nil
        nextLinkTask?.cancel()
        nextLinkTask = nil
        updateNextEpisode()
        env.setBingeGroup(best.stream.behaviorHints.bingeGroup, forMeta: meta.id)
        nowPlaying.setMetadata(title: meta.name, subtitle: episodeSubtitle(),
                               artworkURL: (video.thumbnail ?? meta.background ?? meta.poster).flatMap { URL.lenient($0) }, loader: env.images)
        await beginPlayback(startOverride: nil)
        await loadSubtitleOptions()
    }

    /// Near the end of an episode: prefetch the next one's sources and, if autoplay is on, run the countdown.
    func evaluateNextEpisodePrompt() {
        guard let next = nextEpisode, snapshot.duration > 120, !snapshot.isLive else { return }
        let remaining = snapshot.duration - snapshot.position
        let nextIsDownloaded = playback.preferDownloaded && env.downloads.completedItem(metaID: meta.id, videoID: next.id) != nil
        if nextStreamsTask == nil, !nextIsDownloaded, snapshot.position / snapshot.duration > 0.8 {
            let service = env.service
            let type = meta.type
            let debrid = env.debrid.streamContext
            nextStreamsTask = Task { await service.allStreams(type: type, videoID: next.id, debrid: debrid) }
        }
        if !nextIsDownloaded { prefetchNextLink(for: next) }
        let countdown = playback.nextEpisodeCountdownSeconds
        guard playback.autoplayNextEpisode, countdown > 0 else { return }
        if remaining <= Double(countdown) + 1, remaining > 0.5, countdownTask == nil, nextCountdown == nil, snapshot.isPlaying {
            startCountdown(from: countdown)
        } else if remaining > Double(countdown) + 3 {
            cancelCountdown()
        }
    }

    /// Near the end of an episode: when the next one is a torrent the debrid service has in its cache, ask for its link now and keep it,
    /// so that «Prossimo» opens it at once (the player takes a kept link before asking again). Never starts a download. Switch:
    /// Funzioni extra ▸ Precarica il prossimo episodio.
    func prefetchNextLink(for next: Video) {
        guard nextLinkTask == nil, env.settings.value.advanced.extras.prefetchNextLink, env.debrid.isConfigured,
              let streamsTask = nextStreamsTask else { return }
        let videoID = next.id
        nextLinkTask = Task { [weak self] in
            let found = await streamsTask.value
            guard let self = self, !Task.isCancelled, !self.tornDown, self.nextEpisode?.id == videoID else { return }
            let preferences = self.env.streamPreferences()
            let ranked = StreamSelector.rank(found.streams, preferences: preferences)
            let binge = self.currentStream?.behaviorHints.bingeGroup ?? self.env.bingeGroup(forMeta: self.meta.id)
            let choices = await self.debridAutoSelectable(ranked)
            guard let best = StreamSelector.autoSelect(choices, previousBingeGroup: binge, ordering: preferences.ordering),
                  DebridStreamLogic.isTorrent(best.stream) else { return }
            let stremioID = DebridStreamLogic.stremioID(meta: self.meta, video: next)
            guard let request = DebridRequest(stream: best.stream, stremioID: stremioID, mode: .cachedOnly),
                  let resolution = try? await self.env.debrid.resolve(request, onProgress: nil), !self.tornDown else { return }
            self.env.debrid.stashResolution(resolution, for: best.stream, stremioID: stremioID)
            self.env.diagnostics.logDetached(.info, "player", "Link del prossimo episodio preparato in anticipo")
        }
    }

    func startCountdown(from seconds: Int) {
        nextCountdown = seconds
        countdownTask = Task { [weak self] in
            var left = seconds
            while left > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                self?.nextCountdown = left
            }
            if Task.isCancelled { return }
            self?.countdownTask = nil
            await self?.playNext(userInitiated: false)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        nextCountdown = nil
    }
}
