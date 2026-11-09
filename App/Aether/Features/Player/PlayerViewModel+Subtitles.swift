import SwiftUI
import AVFoundation
import AetherCore

/// Subtitles: tracks, addons and catalogue, automatic choice, choosing one, translation. Part of `PlayerViewModel`, split by subject so that a change
/// to one part cannot disturb the others by accident (same behaviour as when it was one file).
extension PlayerViewModel {
    // MARK: Subtitles

    func refreshEmbeddedSubtitleOptions() {
        var options: [SubtitleOption] = []
        for track in engine.embeddedSubtitleTracks() {
            let code = TrackPreferences.languageCode(language: track.language, title: track.title)
            options.append(SubtitleOption(id: "embedded-\(track.id)", title: track.title, detail: "Incorporato",
                                          language: track.language, kind: .embedded(track.id), languageCode: code))
        }
        embeddedOptions = options
        // The embedded track that was on is no longer reported: do not claim it still is.
        if let selected = selectedOption, case .embedded = selected.kind {
            let stillThere = options.contains(where: { (option: SubtitleOption) -> Bool in
                return option.id == selected.id
            })
            if !stillThere {
                selectedSubtitleID = nil
                selectedOption = nil
            }
        }
        publishSubtitleOptions()
    }

    /// `subtitleOptions` = embedded tracks first, then the addon subtitles in the order of the groups, then imported files.
    func publishSubtitleOptions() {
        var addonOptions: [SubtitleOption] = []
        for group in subtitleGroups {
            for candidate in group.candidates { addonOptions.append(SubtitleOption.addon(candidate)) }
        }
        subtitleOptions = embeddedOptions + addonOptions + localOptions
    }

    // MARK: Subtitles from addons

    /// Languages for the ranking of the list and for the automatic choice: what the viewer picked by hand for this title, then the
    /// preferred language, then the secondary one ("off" means none).
    func subtitleWishes() -> (ranking: [String], automatic: [String]) {
        let remembered = trackMemory.subtitleChoiceToApply(forMeta: meta.id)
        let primary = SettingsStore.resolvedLanguage(playback.preferredSubtitleLanguage)
        let secondary = SettingsStore.resolvedLanguage(playback.secondarySubtitleLanguage)
        let ranking = TrackPreferences.subtitleRanking(remembered: remembered, primary: primary, secondary: secondary)
        let automatic = TrackPreferences.automaticSubtitleLanguages(remembered: remembered, primary: primary, secondary: secondary)
        return (ranking, automatic)
    }

    /// Asks every installed subtitles addon for this video. The first answer carries what the stream announces (hash, size, file
    /// name) and never waits for anything else. When the stream announces no hash, one is computed on this device in the
    /// background (`SubtitleHashProbe`, once per stream and session; never for downloads, HLS or non-public http) and the addons
    /// are asked again with it: both answers end up in the list.
    func loadSubtitleOptions() async {
        subtitleGeneration += 1
        let generation = subtitleGeneration
        subtitleHashTask?.cancel()
        subtitleHashTask = nil

        let stream = currentStream
        let type = meta.type
        let videoID = currentVideo?.id ?? meta.id
        var announced: [AddonSubtitle] = []
        for subtitle in stream?.subtitles ?? [] {
            var entry = subtitle
            if entry.addonName == nil { entry.addonName = stream?.addonName }
            announced.append(entry)
        }
        streamSubtitles = announced
        plainSubtitles = []
        hashedSubtitles = []
        catalogSubtitles = []
        subtitleAddonsFinished = false
        catalogLoading = startCatalogSearch(videoID: videoID, generation: generation)
        subtitleListPhase = .loading
        rebuildSubtitleList()
        applyPreferredSubtitleIfNeeded()

        let handles = await env.service.handles()
        guard generation == subtitleGeneration, !tornDown else { return }
        let providers = SubtitleAddonSupport.providers(in: handles, type: type, videoID: videoID)
        hasSubtitleProvider = !providers.isEmpty || catalogLoading || !catalogSubtitles.isEmpty
        if providers.isEmpty {
            finishSubtitleLoading()
            return
        }

        var known: SubtitleHashResult?
        if let stream = stream { known = localHashes[stream.id] }
        let params = SubtitleVideoParams.resolve(stream: stream, local: known, filename: nil)
        startHashProbeIfNeeded(generation: generation, type: type, videoID: videoID)
        let answer = await env.service.subtitles(type: type, videoID: videoID, params: params)
        guard generation == subtitleGeneration, !tornDown else { return }
        if known != nil { hashedSubtitles = answer } else { plainSubtitles = answer }
        finishSubtitleLoading()
    }

    /// Asks the OpenSubtitles.org catalogue for this video in the viewer's languages (at most two), next to the addons. Returns
    /// whether a search started; the list is final only once it has answered too.
    func startCatalogSearch(videoID: String, generation: Int) -> Bool {
        guard playback.openSubtitlesCatalog else { return false }
        var languages = subtitleWishes().ranking
        if languages.isEmpty, let system = Locale.preferredLanguages.first { languages = [LanguageCodes.normalise(system)] }
        var codes: [String] = []
        for language in languages {
            if let code = OpenSubtitlesCatalog.catalogLanguage(language), !codes.contains(code) { codes.append(code) }
        }
        let urls = codes.prefix(2).compactMap { OpenSubtitlesCatalog.searchURL(videoID: videoID, language: $0) }
        guard !urls.isEmpty else { return false }
        let http = env.http
        Task { [weak self] in
            var found: [AddonSubtitle] = []
            for url in urls {
                let request = HTTPRequest(url: url, headers: OpenSubtitlesCatalog.headers, timeout: 12, maxBytes: 4 << 20, purpose: .addonRequest)
                if let response = try? await http.send(request), response.isSuccess {
                    found.append(contentsOf: OpenSubtitlesCatalog.parse(response.data))
                }
            }
            guard let self = self, generation == self.subtitleGeneration, !self.tornDown else { return }
            self.catalogSubtitles = found
            self.catalogLoading = false
            self.env.diagnostics.logDetached(.info, "subtitles", "OpenSubtitles.org: \(found.count) sottotitoli nelle lingue scelte")
            if self.subtitleAddonsFinished { self.finishSubtitleLoading() } else { self.rebuildSubtitleList() }
        }
        return true
    }

    func finishSubtitleLoading() {
        subtitleAddonsFinished = true
        // The automatic choice waits for the catalogue too: it may have the only subtitle in the viewer's language.
        if catalogLoading {
            rebuildSubtitleList()
            return
        }
        subtitleListPhase = .ready
        rebuildSubtitleList()
        applyPreferredSubtitleIfNeeded()
    }

    func startHashProbeIfNeeded(generation: Int, type: String, videoID: String) {
        var isDownload = false
        if case .download = request.source { isDownload = true }
        guard let stream = currentStream, SubtitleHashPlan.shouldProbe(stream: stream, isDownload: isDownload) else { return }
        if localHashes[stream.id] != nil || attemptedHashStreams.contains(stream.id) { return }
        attemptedHashStreams.insert(stream.id)
        let probe = SubtitleHashProbe(http: env.http, policy: env.settings.value.networkPolicy(allowLoopback: env.isUITesting))
        subtitleHashTask = Task { [weak self] in
            let outcome = await probe.probe(stream: stream)
            if Task.isCancelled { return }
            await self?.hashProbeFinished(outcome, stream: stream, type: type, videoID: videoID, generation: generation)
        }
    }

    func hashProbeFinished(_ outcome: Result<SubtitleHashResult, SubtitleHashFailure>, stream: AddonStream,
                                   type: String, videoID: String, generation: Int) async {
        guard !tornDown else { return }
        switch outcome {
        case .failure(let reason):
            // Not an error for the viewer: the addons simply keep answering without a hash.
            if reason != .cancelled {
                env.diagnostics.logDetached(.info, "subtitles", "Hash del video non calcolato: \(reason.message)")
            }
        case .success(let hashed):
            localHashes[stream.id] = hashed
            guard generation == subtitleGeneration else { return }
            let params = SubtitleVideoParams.resolve(stream: stream, local: hashed, filename: nil)
            let refined = await env.service.subtitles(type: type, videoID: videoID, params: params)
            guard generation == subtitleGeneration, !tornDown else { return }
            hashedSubtitles = refined
            rebuildSubtitleList()
        }
    }

    /// Ranks and groups what the stream and the addons offered (`SubtitleCatalog`). Answers with the local hash come first.
    func rebuildSubtitleList() {
        var pool: [AddonSubtitle] = streamSubtitles
        pool.append(contentsOf: hashedSubtitles)
        pool.append(contentsOf: plainSubtitles)
        pool.append(contentsOf: catalogSubtitles)
        // The subtitle on screen stays in the list even if a refreshed answer no longer carries it.
        if let selected = selectedOption, case .addon(let subtitle) = selected.kind {
            let wanted = subtitle.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let present = pool.contains(where: { (entry: AddonSubtitle) -> Bool in
                return entry.url.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
            })
            if !present { pool.append(subtitle) }
        }
        let preferences = SubtitlePreferences(languages: subtitleWishes().ranking, preferHearingImpaired: false)
        let candidates = SubtitleCatalog.candidates(from: pool, preferences: preferences)
        subtitleCandidates = candidates
        let groups = SubtitleCatalog.groups(from: candidates)
        if groups != subtitleGroups { subtitleGroups = groups }
        publishSubtitleOptions()
    }

    // MARK: Automatic choice

    /// At the start of a video: an embedded track in the preferred language, otherwise the best addon subtitle for the preferred
    /// language, then the same for the secondary one. Nothing when both are "off". What the viewer picked by hand earlier for this
    /// title replaces the settings. Runs once the engine has reported its tracks and the addons have answered.
    func applyPreferredSubtitleIfNeeded() {
        guard !preferredSubtitleApplied, selectedSubtitleID == nil, subtitleTracksKnown, !tornDown else { return }
        let wishes = subtitleWishes().automatic
        if wishes.isEmpty {
            preferredSubtitleApplied = true
            silenceEngineSubtitles()
            return
        }
        var embedded: [EmbeddedSubtitleInfo] = []
        for option in embeddedOptions {
            embedded.append(EmbeddedSubtitleInfo(optionID: option.id, title: option.title, language: option.language))
        }
        let decision = TrackPreferences.decide(languages: wishes, embedded: embedded, candidates: subtitleCandidates,
                                               listIsFinal: subtitleListPhase == .ready)
        switch decision {
        case .embedded(let optionID):
            guard let option = embeddedOptions.first(where: { (item: SubtitleOption) -> Bool in
                return item.id == optionID
            }) else { return }
            preferredSubtitleApplied = true
            activateSubtitle(option)
        case .addon(let candidate):
            preferredSubtitleApplied = true
            activateSubtitle(SubtitleOption.addon(candidate))
        case .wait:
            return
        case .nothing:
            preferredSubtitleApplied = true
            silenceEngineSubtitles()
        }
    }

    /// No subtitle was chosen: an embedded track the engine switched on by itself (a default or forced track) is switched off, so
    /// that what the sheet says ("Disattivati") is what the viewer sees. Asked once per video.
    func silenceEngineSubtitles() {
        if engineSubtitlesSilenced { return }
        engineSubtitlesSilenced = true
        let engineHasOneOn = engine.embeddedSubtitleTracks().contains(where: { (track: EngineTrack) -> Bool in
            return track.isSelected
        })
        if engineHasOneOn { engine.selectEmbeddedSubtitle(id: nil) }
    }

    /// After an engine change the new engine may switch on a subtitle track of its own: when the viewer's subtitle is drawn by
    /// the app (downloaded or imported), it must be the only one on screen.
    func syncEngineSubtitleWithSelection() {
        if !engineSubtitleSyncPending || embeddedOptions.isEmpty { return }
        engineSubtitleSyncPending = false
        guard let selected = selectedOption else { return }
        switch selected.kind {
        case .addon, .local:
            engine.selectEmbeddedSubtitle(id: nil)
        case .embedded:
            return
        }
    }

    /// After an engine change the embedded track that was on is looked up again by language: track ids differ between engines.
    func reselectEmbeddedAfterEngineChange() {
        guard let language = pendingEmbeddedLanguage, !embeddedOptions.isEmpty else { return }
        pendingEmbeddedLanguage = nil
        guard selectedSubtitleID == nil else { return }
        var embedded: [EmbeddedSubtitleInfo] = []
        for option in embeddedOptions {
            embedded.append(EmbeddedSubtitleInfo(optionID: option.id, title: option.title, language: option.language))
        }
        if let match = TrackPreferences.embeddedMatch(embedded, language: language),
           let option = embeddedOptions.first(where: { (item: SubtitleOption) -> Bool in return item.id == match.optionID }) {
            activateSubtitle(option)
        } else {
            statusMessage = "I sottotitoli incorporati non sono disponibili con questo motore."
            scheduleStatusClear()
        }
    }

    /// A new video (next episode, other source): the subtitle on screen, the lists and the one-time decisions start over.
    /// What the viewer chose by hand (`trackMemory`) is kept: it applies to the next video of the same title.
    func resetSubtitleStateForNewVideo() {
        conversionAudio = nil
        forcedConversion = false
        subtitleTask?.cancel()
        subtitleHashTask?.cancel()
        subtitleHashTask = nil
        subtitleGeneration += 1
        timeline = nil
        activeCues = []
        selectedSubtitleID = nil
        selectedOption = nil
        subtitleError = nil
        failedSubtitle = nil
        cueCache = [:]
        streamSubtitles = []
        plainSubtitles = []
        hashedSubtitles = []
        subtitleCandidates = []
        subtitleGroups = []
        embeddedOptions = []
        localOptions = []
        subtitleOptions = []
        audioTracks = []
        subtitleListPhase = .loading
        hasSubtitleProvider = false
        preferredAudioApplied = false
        preferredSubtitleApplied = false
        subtitleTracksKnown = false
        engineSubtitlesSilenced = false
        engineSubtitleSyncPending = false
        pendingEmbeddedLanguage = nil
    }

    // MARK: Second subtitle

    /// Whether `option` can be the second subtitle (a downloaded or imported file, not the one already shown).
    func canBeSecondary(_ option: SubtitleOption) -> Bool {
        if option.isEmbedded { return false }
        return option.id != selectedSubtitleID
    }

    /// Shows `option` together with the main subtitle (nil turns the second one off).
    func selectSecondarySubtitle(_ option: SubtitleOption?) {
        secondaryTask?.cancel()
        guard let option = option, canBeSecondary(option) else {
            secondarySubtitleID = nil
            secondaryTimeline = nil
            secondaryCues = []
            return
        }
        secondarySubtitleID = option.id
        if let cached = cueCache[option.id] {
            secondaryTimeline = cached
            updateSecondaryCues()
            return
        }
        secondaryTimeline = nil
        secondaryCues = []
        let fetch: () async throws -> Data
        switch option.kind {
        case .embedded:
            return
        case .addon(let subtitle):
            guard let url = URL.lenient(subtitle.url) else { return }
            let loader = SubtitleFileLoader(http: env.http)
            fetch = { try await loader.download(url: url) }
        case .local(let url):
            fetch = {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }
        }
        let language = option.language
        let encoding = option.encodingHint
        secondaryTask = Task { [weak self] in
            do {
                let data = try await fetch()
                let cues = try await SubtitleFileLoader.parse(data, languageHint: language, encodingHint: encoding)
                if Task.isCancelled { return }
                guard let self = self, self.secondarySubtitleID == option.id else { return }
                let loaded = SubtitleTimeline(cues: cues)
                self.cueCache[option.id] = loaded
                self.secondaryTimeline = loaded
                self.updateSecondaryCues()
            } catch {
                if Task.isCancelled { return }
                guard let self = self, self.secondarySubtitleID == option.id else { return }
                self.secondarySubtitleID = nil
                self.statusMessage = "Seconda lingua: " + SubtitleFileLoader.message(for: error)
                self.scheduleStatusClear()
            }
        }
    }

    func updateSecondaryCues() {
        guard let timeline = secondaryTimeline else {
            if !secondaryCues.isEmpty { secondaryCues = [] }
            return
        }
        var cues = timeline.active(at: engine.currentTime(), delay: subtitleDelay)
        if playback.stripHearingImpairedTags {
            cues = cues.compactMap { cue -> SubtitleCue? in
                let text = SubtitleCleaner.stripHearingImpaired(cue.text)
                return text.isEmpty ? nil : SubtitleCue(start: cue.start, end: cue.end, text: text)
            }
        }
        if cues != secondaryCues { secondaryCues = cues }
    }

    // MARK: Choosing a subtitle

    /// Subtitles off, chosen by the viewer. Remembered for the next episode of this series.
    func disableSubtitles() {
        preferredSubtitleApplied = true
        trackMemory.rememberSubtitle(.off, metaID: meta.id)
        selectSecondarySubtitle(nil)
        subtitleTask?.cancel()
        selectedSubtitleID = nil
        selectedOption = nil
        timeline = nil
        activeCues = []
        subtitleError = nil
        failedSubtitle = nil
        engine.selectEmbeddedSubtitle(id: nil)
    }

    /// A subtitle chosen by the viewer. Its language is remembered for the next episode of this series.
    func selectSubtitle(_ option: SubtitleOption) {
        preferredSubtitleApplied = true
        switch option.kind {
        case .embedded, .addon:
            if let code = option.languageCode {
                trackMemory.rememberSubtitle(.language(code), metaID: meta.id)
            } else {
                trackMemory.forgetSubtitle()
            }
        case .local:
            trackMemory.forgetSubtitle()
        }
        activateSubtitle(option)
    }

    /// Switches a subtitle on without touching the memory of what the viewer chose (used by the automatic choice as well).
    func activateSubtitle(_ option: SubtitleOption) {
        if option.id == secondarySubtitleID { selectSecondarySubtitle(nil) }
        subtitleTask?.cancel()
        subtitleError = nil
        failedSubtitle = nil
        selectedSubtitleID = option.id
        selectedOption = option
        switch option.kind {
        case .embedded(let id):
            timeline = nil
            activeCues = []
            engine.selectEmbeddedSubtitle(id: id)
        case .addon(let subtitle):
            engine.selectEmbeddedSubtitle(id: nil)
            guard let url = URL.lenient(subtitle.url) else {
                subtitleDidFail(option, message: "L'indirizzo dei sottotitoli non è valido.")
                return
            }
            let loader = SubtitleFileLoader(http: env.http)
            loadExternal(option) { () async throws -> Data in
                return try await loader.download(url: url)
            }
        case .local(let url):
            engine.selectEmbeddedSubtitle(id: nil)
            loadExternal(option) { () async throws -> Data in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }
        }
    }

    /// Downloads (or reads) and parses a subtitle; the cues are drawn by the app's own overlay, so they do not depend on the engine.
    func loadExternal(_ option: SubtitleOption, fetch: @escaping () async throws -> Data) {
        if let cached = cueCache[option.id] {
            timeline = cached
            updateCues()
            return
        }
        timeline = nil
        activeCues = []
        let language = option.language
        let encoding = option.encodingHint
        subtitleTask = Task { [weak self] in
            do {
                let data = try await fetch()
                let cues = try await SubtitleFileLoader.parse(data, languageHint: language, encodingHint: encoding)
                if Task.isCancelled { return }
                self?.subtitleDidLoad(option, cues: cues)
            } catch {
                if Task.isCancelled { return }
                self?.subtitleDidFail(option, message: SubtitleFileLoader.message(for: error))
            }
        }
    }

    func subtitleDidLoad(_ option: SubtitleOption, cues: [SubtitleCue]) {
        let loaded = SubtitleTimeline(cues: cues)
        cueCache[option.id] = loaded
        guard selectedSubtitleID == option.id else { return }
        timeline = loaded
        updateCues()
    }

    /// The file could not be downloaded or read: say so, clear the selection and leave playback alone.
    func subtitleDidFail(_ option: SubtitleOption, message: String) {
        guard selectedSubtitleID == option.id else { return }
        selectedSubtitleID = nil
        selectedOption = nil
        timeline = nil
        activeCues = []
        subtitleError = message
        failedSubtitle = option
        statusMessage = message
        scheduleStatusClear()
        env.diagnostics.logDetached(.warning, "subtitles", message)
    }

    // MARK: Subtitle translation (Funzioni extra ▸ Offri la traduzione dei sottotitoli)

    /// The button is shown at all (switch on, iOS 18 or later).
    var translationOffered: Bool {
        guard #available(iOS 18.0, *) else { return false }
        return env.settings.value.advanced.extras.translateSubtitles
    }

    var translationTarget: String {
        return SettingsStore.resolvedLanguage(playback.preferredSubtitleLanguage) ?? SettingsStore.resolvedLanguage("system") ?? "it"
    }

    /// Only subtitles the app draws itself (from an addon or a file) have cues it can translate; the ones inside the video are drawn by the engine.
    var canTranslateSubtitle: Bool {
        guard translationOffered, translationJob == nil, let option = selectedOption, timeline != nil, translatedOptionID != option.id else { return false }
        return SubtitleTranslationPlan.shouldOffer(subtitleLanguage: option.languageCode ?? option.language, target: translationTarget)
    }

    func translateSelectedSubtitle() {
        guard canTranslateSubtitle, let option = selectedOption, let current = timeline else { return }
        let cues = current.cues
        let batches = SubtitleTranslationPlan.batches(for: cues).map { group in
            group.map { (index: $0, text: SubtitleTranslationPlan.plainText(cues[$0].text)) }
        }
        let sourceCode = (option.languageCode ?? option.language).map { String($0.prefix(2)) }
        translationJob = SubtitleTranslationJob(optionID: option.id, source: sourceCode.map { Locale.Language(identifier: $0) },
                                                target: Locale.Language(identifier: String(translationTarget.prefix(2))), batches: batches)
        translationStatus = "Traduco i sottotitoli…"
    }

    func translationProgress(done: Int, total: Int) {
        translationStatus = "Traduco i sottotitoli… \(done)/\(total)"
    }

    func finishTranslation(_ job: SubtitleTranslationJob, results: [Int: String]) {
        translationJob = nil
        guard job.optionID == selectedOption?.id, let current = timeline else { return }
        let translated = SubtitleTimeline(cues: SubtitleTranslationPlan.apply(results, to: current.cues))
        cueCache[job.optionID] = translated
        timeline = translated
        translatedOptionID = job.optionID
        translationStatus = "Sottotitoli tradotti sul telefono."
        updateCues()
    }

    func failTranslation(_ message: String) {
        translationJob = nil
        translationStatus = "Traduzione non riuscita: \(message)"
        env.diagnostics.logDetached(.warning, "subtitles", "Traduzione: \(message)")
    }

    /// Tries again with the subtitle that failed.
    func retrySubtitle() {
        guard let option = failedSubtitle else { return }
        activateSubtitle(option)
    }

    func importLocalSubtitle(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        let option = SubtitleOption(id: "local-\(url.lastPathComponent)", title: name, detail: "File locale", language: nil, kind: .local(url))
        localOptions.removeAll(where: { (item: SubtitleOption) -> Bool in return item.id == option.id })
        localOptions.append(option)
        // A file with the same name may have been replaced since the last import.
        cueCache.removeValue(forKey: option.id)
        publishSubtitleOptions()
        selectSubtitle(option)
    }

    func adjustSubtitleDelay(by amount: Double) {
        subtitleDelay = min(60, max(-60, subtitleDelay + amount))
        engine.setEmbeddedSubtitleDelay(subtitleDelay)
        updateCues()
    }

    func startCueTimer() {
        cueTimer?.invalidate()
        cueTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCues() }
        }
    }

    func updateCues() {
        updateSecondaryCues()
        guard let timeline = timeline else {
            if !activeCues.isEmpty { activeCues = [] }
            return
        }
        var cues = timeline.active(at: engine.currentTime(), delay: subtitleDelay)
        if playback.stripHearingImpairedTags {
            cues = cues.compactMap { cue -> SubtitleCue? in
                let text = SubtitleCleaner.stripHearingImpaired(cue.text)
                return text.isEmpty ? nil : SubtitleCue(start: cue.start, end: cue.end, text: text)
            }
        }
        if cues != activeCues { activeCues = cues }
    }
}
