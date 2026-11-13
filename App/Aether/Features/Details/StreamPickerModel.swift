import SwiftUI
import AetherCore

struct StreamPickerRequest: Identifiable {
    let id = UUID()
    var meta: MetaItem
    var video: Video?
    var resumeAt: Double?
}

extension AppEnvironment {
    /// Stream ranking preferences derived from settings and the user's addon order.
    func streamPreferences() -> StreamPreferences {
        let value = settings.value
        var server: URL?
        if value.advanced.useExternalStreamingServer {
            let trimmed = value.advanced.streamingServerURL.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                server = url
            }
        }
        // A torrent counts as playable when the active debrid provider has credentials (it is resolved on demand).
        var capabilities = PlaybackEngineFactory.capabilities
        capabilities.debridAvailable = debrid.isConfigured
        return StreamPreferences(
            qualityCap: value.playback.qualityCap,
            preferredLanguage: SettingsStore.resolvedLanguage(value.playback.preferredAudioLanguage),
            preferLanguage: value.playback.preferStreamsInPreferredAudioLanguage,
            addonOrder: addons.addons.map { $0.id.uuidString },
            ordering: value.playback.streamOrdering,
            streamingServer: server,
            capabilities: capabilities,
            scoring: value.playback.sourceScoring)
    }

    func bingeGroup(forMeta metaID: String) -> String? {
        return UserDefaults.standard.string(forKey: "aether.binge.\(metaID)")
    }

    func setBingeGroup(_ group: String?, forMeta metaID: String) {
        if let group = group, !group.isEmpty {
            UserDefaults.standard.set(group, forKey: "aether.binge.\(metaID)")
        } else {
            UserDefaults.standard.removeObject(forKey: "aether.binge.\(metaID)")
        }
    }

    /// Validates the media URL against the network policy (local-network opt-in, loopback…) before playback/cast.
    func validateMediaURL(_ url: URL) async -> AddonError? {
        // Aether's own server on this phone (a video read from inside a ZIP): the one loopback address that is allowed.
        if localRemux.serves(url) { return nil }
        let policy = settings.snapshot.get().networkPolicy(allowLoopback: isUITesting)
        do {
            try await policy.validate(url, purpose: .mediaPlayback)
            return nil
        } catch let error as AddonError {
            return error
        } catch {
            return nil
        }
    }
}

// MARK: - TorBox state of the picker

/// The torrent row that is being turned into a link right now.
struct DebridRowResolution: Equatable {
    var itemID: String
    var mode: DebridMode
    var progress: DebridProgress?

    var providerTitle: String = "TorBox"

    var message: String {
        if let progress = progress { return progress.message.replacingOccurrences(of: "TorBox", with: providerTitle) }
        return mode == DebridMode.startIfNeeded ? "Preparo la sorgente su \(providerTitle)…" : "Controllo \(providerTitle)…"
    }

    /// "42% · 15 MB/s · ancora 3 s" (only what TorBox reported).
    var detail: String? { return DebridFormat.detail(for: progress) }

    /// A bar is shown only while TorBox itself is downloading and has reported a fraction.
    var determinateFraction: Double? {
        guard let progress = progress, progress.phase == DebridProgress.Phase.downloading,
              let fraction = progress.fraction, fraction.isFinite else { return nil }
        return min(1.0, max(0.0, fraction))
    }
}

/// Why a torrent row could not be played, shown under the row.
struct DebridRowFailure: Equatable {
    var itemID: String
    var message: String
    var isRetryable: Bool
    var mode: DebridMode
    var file: DebridFileCandidate?
}

/// The files of a torrent when the right one cannot be picked automatically.
struct DebridFileChoice: Identifiable {
    let id = UUID()
    let item: RankedStream
    let mode: DebridMode
    let candidates: [DebridFileCandidate]
}

/// What a torrent row shows besides the usual badges.
struct DebridRowAppearance: Equatable {
    var torBoxConfigured: Bool
    /// nil: nothing to show (the cache status is unknown).
    var badge: DebridCacheBadge?
}

@MainActor
final class StreamPickerModel: ObservableObject {
    @Published private(set) var ranked: [RankedStream] = []
    @Published private(set) var errors: [String: AddonError] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var pendingAddons: [String] = []
    @Published var addonFilter: String?
    /// What the viewer typed in the search field: every word has to be in the source's name, quality, language, file name or addon.
    @Published var searchText = ""
    /// Quality / HDR / language chips (Aspetto › Scorciatoie › «Filtri rapidi nelle sorgenti»).
    @Published var quickFilter = StreamQuickFilter()
    @Published var blockedMessage: String?
    @Published var infoMessage: String?

    // TorBox
    @Published private(set) var cacheStatuses: [String: DebridCacheStatus] = [:]
    @Published private(set) var checkingHashes: Set<String> = []
    @Published private(set) var cacheCheckFailure: DebridError?
    @Published private(set) var resolution: DebridRowResolution? {
        didSet { launch?.resolution = resolution }
    }
    /// The black page of the player that stands in for it while the source is prepared (nil in Theater Mode, which has its own).
    @Published private(set) var launch: PlayerLaunch?
    private weak var launchRouter: AppRouter?
    /// The list is flying the film's logo to the middle of the screen: the black page waits this long before it comes up.
    var launchHold: TimeInterval = 0
    var usesLaunchPage: Bool { return launch != nil }
    @Published private(set) var rowFailure: DebridRowFailure?
    /// A torrent that is not in TorBox's cache and waits for the user's yes before anything is added to the account.
    @Published var pendingDownload: RankedStream?
    @Published var fileChoice: DebridFileChoice?

    private var collected: [AddonStream] = []
    private var seen = Set<String>()
    private var task: Task<Void, Never>?
    private(set) var request: StreamPickerRequest
    private weak var env: AppEnvironment?
    private var autoSelected = false

    private var pendingHashes: [String] = []
    private var requestedHashes = Set<String>()
    private var availabilityTask: Task<Void, Never>?
    private var availabilityGeneration = 0
    private var deferredAutoSelect: ((RankedStream) -> Void)?
    private var resolutionTask: Task<Void, Never>?
    private var resolutionToken = UUID()
    private var progressSequence = 0
    /// The picker is closing because playback is about to start: the work that opens the player must not be cancelled.
    private var handingOver = false

    init(request: StreamPickerRequest) {
        self.request = request
    }

    deinit {
        task?.cancel()
        availabilityTask?.cancel()
    }

    /// Torrents known to be cached by the active provider come first; the other rows keep their place.
    var playable: [RankedStream] {
        let list = ranked.filter { $0.info.support.isPlayable }
        // Real-Debrid mode only exposes torrent candidates that can be resolved through the selected RD account.
        // Direct URLs returned by unrelated addons must not leak into the RD-only source list.
        // The direct links of the addons that answer for Real-Debrid (Torrentio and Comet switched to it, an addon marked
        // «Real-Debrid») are Real-Debrid links, already ready: they stay.
        if debridProvider == .realdebrid && debridConfigured {
            return list.filter { item in
                DebridStreamLogic.isTorrent(item.stream) || realDebridAddonIDs.contains(item.stream.addonID ?? "")
            }
        }
        return DebridStreamLogic.cachedFirst(list, statuses: cacheStatuses)
    }
    var unplayable: [RankedStream] { ranked.filter { !$0.info.support.isPlayable } }

    var addonNames: [String] {
        var names: [String] = []
        for item in ranked {
            if let name = item.stream.addonName, !names.contains(name) { names.append(name) }
        }
        return names
    }

    func filtered(_ list: [RankedStream]) -> [RankedStream] {
        var result = list
        if let filter = addonFilter { result = result.filter { $0.stream.addonName == filter } }
        result = quickFilter.apply(result)
        let words = StreamPickerModel.fold(searchText).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return result }
        return result.filter { item in
            let fields: [String?] = [item.stream.name, item.stream.details, item.stream.behaviorHints.filename, item.stream.addonName,
                                     item.info.formatLabel, item.info.container]
            let text = StreamPickerModel.fold((fields.compactMap { $0 } + item.info.badges + item.info.languages).joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
    }

    private static func fold(_ text: String) -> String {
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    var debridConfigured: Bool { return env?.debrid.isConfigured ?? false }
    /// The addons whose links are Real-Debrid links (see `playable`).
    private(set) var realDebridAddonIDs: Set<String> = []
    var debridProvider: DebridService.ProviderChoice { return env?.debrid.selectedProvider ?? .torbox }

    var hasTorrentRows: Bool {
        return ranked.contains(where: { (item: RankedStream) -> Bool in return DebridStreamLogic.isTorrent(item.stream) })
    }

    func appearance(for item: RankedStream) -> DebridRowAppearance? {
        guard DebridStreamLogic.isTorrent(item.stream) else { return nil }
        // Real-Debrid does not expose the cache probe used for TorBox; don't show TorBox cache badges for RD.
        guard debridProvider == .torbox else { return nil }
        let configured = debridConfigured
        var badge: DebridCacheBadge?
        if configured, let hash = DebridStreamLogic.canonicalHash(of: item.stream) {
            badge = DebridCacheBadge.badge(status: cacheStatuses[hash], isChecking: checkingHashes.contains(hash))
        }
        return DebridRowAppearance(torBoxConfigured: configured, badge: badge)
    }

    func start(env: AppEnvironment, onAutoSelect: @escaping (RankedStream) -> Void) {
        self.env = env
        // The list shows again under the player (it closes itself afterwards): it must not start over and pick a source again.
        guard !handingOver else { return }
        FanartLogoStore.shared.prefetch(meta: request.meta, env: env)
        task?.cancel()
        availabilityTask?.cancel()
        availabilityTask = nil
        availabilityGeneration += 1
        pendingHashes = []
        requestedHashes = []
        checkingHashes = []
        cacheCheckFailure = nil
        deferredAutoSelect = nil
        collected = []
        seen = []
        errors = [:]
        isLoading = true
        task = Task { [weak self] in
            await self?.run(onAutoSelect: onAutoSelect)
        }
    }

    func stop() {
        task?.cancel()
        availabilityTask?.cancel()
        // Leaving the picker ends the wait. A download already started stays in the user's TorBox account.
        if !handingOver { cancelResolution() }
    }

    private func run(onAutoSelect: @escaping (RankedStream) -> Void) async {
        guard let env = env else { return }
        let videoID = request.video?.id ?? request.meta.id
        let type = request.meta.type

        if let embedded = request.video?.streams, !embedded.isEmpty {
            // The meta response carried its own streams: Stremio does not ask other addons in that case.
            ingest(embedded)
            isLoading = false
            maybeAutoSelect(env: env, onAutoSelect: onAutoSelect)
            return
        }

        let path = ResourcePath(resource: ResourceName.stream, type: type, id: videoID)
        let handles = await env.addons.handles()
        let debrid = env.debrid.streamContext
        let asked = RequestPlanner.addons(for: path, handles: handles)
            .filter { AddonDebridRouting.decide($0, context: debrid) != .skip }
        pendingAddons = asked.map { $0.addon.displayName }
        realDebridAddonIDs = Set(asked.compactMap { handle -> String? in
            guard debrid.service == .realDebrid else { return nil }
            if handle.addon.debridScope == .realDebrid { return handle.addon.id.uuidString }
            if case .use(_, let switched) = AddonDebridRouting.decide(handle, context: debrid), switched != nil {
                return handle.addon.id.uuidString
            }
            return nil
        })
        if pendingAddons.isEmpty {
            isLoading = false
            return
        }
        for await batch in env.service.streams(type: type, videoID: videoID, debrid: debrid) {
            if Task.isCancelled { return }
            pendingAddons.removeAll(where: { $0 == batch.addonName })
            if let error = batch.error { errors[batch.addonName] = error }
            ingest(batch.streams)
        }
        if Task.isCancelled { return }
        isLoading = false
        pendingAddons = []
        maybeAutoSelect(env: env, onAutoSelect: onAutoSelect)
    }

    private func ingest(_ streams: [AddonStream]) {
        guard let env = env else { return }
        for stream in streams where seen.insert(stream.id).inserted {
            collected.append(stream)
        }
        ranked = StreamSelector.rank(collected, preferences: env.streamPreferences())
        scheduleAvailabilityCheck()
    }

    private func maybeAutoSelect(env: AppEnvironment, onAutoSelect: @escaping (RankedStream) -> Void) {
        guard !autoSelected, env.settings.value.playback.autoSelectStream else { return }
        // Torrents wait for the active provider's cache check before automatic selection.
        if env.debrid.isConfigured && hasPendingCacheChecks {
            deferredAutoSelect = onAutoSelect
            return
        }
        // Continuity: prefer the release group of the previous episode of this series.
        let binge = env.bingeGroup(forMeta: request.meta.id)
        let candidates = DebridStreamLogic.autoSelectable(ranked, statuses: cacheStatuses, debridConfigured: env.debrid.isConfigured)
        guard resolution == nil, pendingDownload == nil, let best = StreamSelector.autoSelect(candidates, previousBingeGroup: binge, ordering: env.streamPreferences().ordering) else { return }
        autoSelected = true
        onAutoSelect(best)
    }

    // MARK: Cache check

    private var hasPendingCacheChecks: Bool { return availabilityTask != nil || !pendingHashes.isEmpty }

    /// Asks the active provider about torrents not checked yet, without blocking the list.
    private func scheduleAvailabilityCheck() {
        // Only TorBox supports the instant cache lookup used by this picker. RD candidates are routed
        // through RD's own add-magnet/prepare/link flow when selected.
        guard let env = env, env.debrid.isConfigured, env.debrid.selectedProvider == .torbox else { return }
        for hash in DebridStreamLogic.hashes(in: ranked) {
            if requestedHashes.insert(hash).inserted {
                pendingHashes.append(hash)
                checkingHashes.insert(hash)
            }
        }
        guard availabilityTask == nil, !pendingHashes.isEmpty else { return }
        let generation = availabilityGeneration
        availabilityTask = Task { [weak self] in
            // Answers of other addons that arrive within a moment join the same request.
            try? await Task.sleep(nanoseconds: 350_000_000)
            await self?.drainAvailability(generation: generation)
        }
    }

    private func drainAvailability(generation: Int) async {
        guard let env = env else { return }
        while !pendingHashes.isEmpty && !Task.isCancelled && generation == availabilityGeneration {
            let batch = pendingHashes
            pendingHashes = []
            let report = await env.debrid.availability(infoHashes: batch)
            if Task.isCancelled || generation != availabilityGeneration { return }
            applyAvailability(report, for: batch)
        }
        guard generation == availabilityGeneration else { return }
        availabilityTask = nil
        if !Task.isCancelled, let deferred = deferredAutoSelect {
            deferredAutoSelect = nil
            maybeAutoSelect(env: env, onAutoSelect: deferred)
        }
    }

    private func applyAvailability(_ report: DebridAvailabilityReport, for batch: [String]) {
        var statuses = cacheStatuses
        var unanswered = 0
        for hash in batch {
            let status = report.status(for: hash)
            if status == DebridCacheStatus.unknown {
                unanswered += 1
            } else {
                statuses[hash] = status
            }
        }
        cacheStatuses = statuses
        checkingHashes.subtract(batch)
        if let failure = report.failure {
            cacheCheckFailure = failure
        } else if unanswered == 0 {
            cacheCheckFailure = nil
        }
    }

    func retryCacheCheck() {
        cacheCheckFailure = nil
        for hash in DebridStreamLogic.hashes(in: ranked) where cacheStatuses[hash] == nil {
            requestedHashes.remove(hash)
        }
        scheduleAvailabilityCheck()
    }

    private func cacheStatus(of stream: AddonStream) -> DebridCacheStatus? {
        guard let hash = DebridStreamLogic.canonicalHash(of: stream) else { return nil }
        return cacheStatuses[hash]
    }

    // MARK: Playing

    /// Queues direct files as-is; torrents are resolved through TorBox first, then the resulting single-file URL
    /// enters the same offline queue. The signed CDN URL is never logged or persisted in diagnostics.
    func download(_ item: RankedStream, env: AppEnvironment) async {
        let allowLocal = env.settings.value.privacy.allowLocalNetwork
        if DebridStreamLogic.isTorrent(item.stream) {
            guard env.debrid.isTorBoxConfigured else {
                blockedMessage = "Per scaricare un torrent configura la chiave API TorBox nelle impostazioni."
                return
            }
            guard let request = DebridRequest(
                stream: item.stream,
                stremioID: DebridStreamLogic.stremioID(meta: self.request.meta, video: self.request.video),
                mode: .startIfNeeded
            ) else {
                blockedMessage = "Questa sorgente torrent non contiene un hash valido."
                return
            }
            do {
                let resolution = try await env.debrid.resolveWithTorBox(request, onProgress: nil)
                // A video inside an archive is downloaded as its byte range in the archive.
                let download = try await env.debrid.downloadableStream(resolution, for: item.stream,
                                                                       stremioID: DebridStreamLogic.stremioID(meta: self.request.meta, video: self.request.video))
                if let refusal = await env.downloads.enqueue(meta: self.request.meta, video: self.request.video,
                                                             stream: download.stream, allowLocalNetwork: allowLocal, ephemeralURL: download.url) {
                    blockedMessage = refusal
                } else {
                    infoMessage = "Download avviato tramite TorBox. Lo trovi in Libreria ▸ Download."
                }
            } catch let error as DebridError {
                blockedMessage = error.message
            } catch {
                blockedMessage = "TorBox non è riuscito a preparare il file. Riprova o scegli un'altra sorgente."
            }
            return
        }
        if let refusal = await env.downloads.enqueue(meta: request.meta, video: request.video, stream: item.stream, allowLocalNetwork: allowLocal) {
            blockedMessage = refusal
        } else {
            infoMessage = "Download avviato. Lo trovi in Libreria ▸ Download."
        }
    }

    /// The address to hand to an external player: the source's own link, or — for a torrent — the link the debrid service
    /// (TorBox or Real-Debrid) makes for it. A torrent that is not already in the service's cache is not added without asking.
    func externalPlayerURL(_ item: RankedStream, player: ExternalPlayer, env: AppEnvironment) async -> URL? {
        guard let media = await playbackLink(item, env: env) else { return nil }
        return player.url(for: media)
    }

    /// The address that plays the source: its own http(s) link, or — for a torrent — the one the debrid service makes for it.
    func playbackLink(_ item: RankedStream, env: AppEnvironment) async -> URL? {
        if let media = item.stream.directMediaURL { return media }
        guard DebridStreamLogic.isTorrent(item.stream) else { return nil }
        guard env.debrid.isConfigured else {
            blockedMessage = "Per aprire un torrent in un lettore esterno configura TorBox o Real-Debrid in Impostazioni ▸ Servizi."
            return nil
        }
        let stremioID = DebridStreamLogic.stremioID(meta: request.meta, video: request.video)
        guard let debridRequest = DebridRequest(stream: item.stream, stremioID: stremioID, mode: .cachedOnly) else {
            blockedMessage = "Questa sorgente torrent non contiene un hash valido."
            return nil
        }
        let provider = env.debrid.selectedProvider
        infoMessage = "Preparo il link con \(provider.title)…"
        do {
            let result = try await env.debrid.resolve(debridRequest, onProgress: nil)
            infoMessage = nil
            if let blocked = await env.validateMediaURL(result.url) {
                blockedMessage = blocked.message
                return nil
            }
            return result.url
        } catch let error as DebridError {
            infoMessage = nil
            if case .notCached = error {
                blockedMessage = "Questo torrent non è già pronto su \(provider.title). Avvialo una volta dalla riproduzione normale (viene aggiunto al tuo account) e poi riprova."
            } else {
                blockedMessage = error.message
            }
            return nil
        } catch {
            infoMessage = nil
            blockedMessage = DebridErrorText.describe(error, provider: provider)
            return nil
        }
    }

    func play(_ item: RankedStream, env: AppEnvironment, dismiss: @escaping () -> Void) async {
        cancelResolution()
        rowFailure = nil
        if DebridStreamLogic.isTorrent(item.stream) && env.debrid.isConfigured {
            if env.debrid.selectedProvider == .realdebrid {
                // RD decides whether the torrent is already ready or needs to be added/prepared, then returns its own link.
                startResolution(item, mode: .startIfNeeded, file: nil, env: env, dismiss: dismiss)
            } else {
                beginTorBox(item, env: env, dismiss: dismiss)
            }
            return
        }
        beginLaunch(env: env, dismiss: dismiss)
        if let url = StreamResolver.playbackURL(for: item.stream, streamingServer: env.streamPreferences().streamingServer) {
            if let blocked = await env.validateMediaURL(url) {
                endLaunch()
                OrientationController.restore()
                await settleCover()
                blockedMessage = blocked.message
                return
            }
        } else {
            endLaunch()
            OrientationController.restore()
            await settleCover()
            blockedMessage = "Questa sorgente non può essere riprodotta."
            return
        }
        await present(item, env: env, dismiss: dismiss)
    }

    /// Opens the player for the chosen stream. The player receives the stream as the addon gave it; a torrent is turned into a
    /// link there (the link resolved here is handed over through `DebridService`).
    private func present(_ item: RankedStream, env: AppEnvironment, dismiss: () -> Void) async {
        env.setBingeGroup(item.stream.behaviorHints.bingeGroup, forMeta: request.meta.id)
        let alternatives = playable.filter { $0.id != item.id }
        let player = PlayerRequest(meta: request.meta, video: request.video, source: .stream(item.stream), alternatives: alternatives)
        handingOver = true
        if env.router.launch != nil {
            // The black page is already up over the list: the player takes its place there, and the list leaves when the player closes.
            if let page = env.router.launch, page.intro {
                // The start screen waits for the viewer: the source is ready, «Guarda» starts the film.
                page.resolution = nil
                page.pending = player
                page.ready = true
                return
            }
            env.router.play(player)
            return
        }
        dismiss()
        // Present after the sheet is gone to avoid overlapping presentations.
        try? await Task.sleep(nanoseconds: 350_000_000)
        env.router.play(player)
    }

    // MARK: Playing a torrent through the selected debrid provider

    /// A torrent reported as not cached is never started without confirmation; otherwise it is resolved in `cachedOnly` mode.
    private func beginTorBox(_ item: RankedStream, env: AppEnvironment, dismiss: @escaping () -> Void) {
        if cacheStatus(of: item.stream) == DebridCacheStatus.notCached {
            pendingDownload = item
            return
        }
        startResolution(item, mode: DebridMode.cachedOnly, file: nil, env: env, dismiss: dismiss)
    }

    func confirmDownload(_ item: RankedStream, env: AppEnvironment, dismiss: @escaping () -> Void) {
        pendingDownload = nil
        startResolution(item, mode: DebridMode.startIfNeeded, file: nil, env: env, dismiss: dismiss)
    }

    func chooseFile(_ file: DebridFileCandidate, from choice: DebridFileChoice, env: AppEnvironment,
                    dismiss: @escaping () -> Void) {
        fileChoice = nil
        startResolution(choice.item, mode: choice.mode, file: file, env: env, dismiss: dismiss)
    }

    func retryResolution(env: AppEnvironment, dismiss: @escaping () -> Void) {
        guard let failure = rowFailure,
              let item = ranked.first(where: { (candidate: RankedStream) -> Bool in return candidate.id == failure.itemID }) else { return }
        startResolution(item, mode: failure.mode, file: failure.file, env: env, dismiss: dismiss)
    }

    /// Stops waiting for the selected provider. A torrent already added to the account stays there: Aether never deletes items.
    func cancelResolution() {
        resolutionTask?.cancel()
        resolutionTask = nil
        resolutionToken = UUID()
        resolution = nil
        endLaunch()
        OrientationController.restore()
    }

    /// Puts the player's black page (logo, progress) on screen at once, over the list, turning the screen only once.
    private func beginLaunch(env: AppEnvironment, dismiss: @escaping () -> Void) {
        endLaunch()
        let page = PlayerLaunch(meta: request.meta) { [weak self] in self?.cancelResolution() }
        page.intro = env.settings.value.playback.introEnabled(forType: request.meta.type)
        page.resolution = resolution
        if launchHold > 0 {
            page.holdUntil = Date().addingTimeInterval(launchHold)
            page.arrivesFromPicker = true
            launchHold = 0
        }
        launch = page
        launchRouter = env.router
        env.router.launch = page
        env.router.afterPlayer = dismiss
        env.diagnostics.logDetached(.info, "player", "Apertura: pagina nera messa su schermo")
        // The black page goes over this list: the list «disappears» for SwiftUI, but nothing was left, so its onDisappear must not cancel.
        handingOver = true
    }

    /// Takes the page down (the source could not be played, or the wait was cancelled).
    private func endLaunch() {
        if launch != nil {
            handingOver = false
            launchRouter?.note("Apertura: pagina nera tolta (preparazione finita male o annullata)")
        }
        guard let router = launchRouter else { launch = nil; return }
        if router.launch === launch, router.player == nil {
            router.launch = nil
            router.afterPlayer = nil
        }
        launch = nil
        launchRouter = nil
    }

    private func startResolution(_ item: RankedStream, mode: DebridMode, file: DebridFileCandidate?,
                                 env: AppEnvironment, dismiss: @escaping () -> Void) {
        resolutionTask?.cancel()
        let token = UUID()
        resolutionToken = token
        progressSequence = 0
        rowFailure = nil
        resolution = DebridRowResolution(itemID: item.id, mode: mode, progress: nil,
                                         providerTitle: env.debrid.selectedProvider.title)
        beginLaunch(env: env, dismiss: dismiss)
        resolutionTask = Task {
            await self.runResolution(item, mode: mode, file: file, token: token, env: env, dismiss: dismiss)
        }
    }

    private func runResolution(_ item: RankedStream, mode: DebridMode, file: DebridFileCandidate?, token: UUID,
                               env: AppEnvironment, dismiss: @escaping () -> Void) async {
        let stremioID = DebridStreamLogic.stremioID(meta: request.meta, video: request.video)
        guard var debridRequest = DebridRequest(stream: item.stream, stremioID: stremioID, mode: mode) else {
            finishResolution(token)
            blockedMessage = "Questa sorgente non può essere riprodotta."
            return
        }
        if let file = file { debridRequest.filename = file.path }
        let relay = DebridProgressRelay()
        let sink: @Sendable (DebridProgress) -> Void = { (progress: DebridProgress) -> Void in
            let sequence = relay.next()
            Task { @MainActor in
                self.receive(progress, sequence: sequence, token: token)
            }
        }
        do {
            let result = try await env.debrid.resolve(debridRequest, onProgress: sink)
            try Task.checkCancellation()
            guard token == resolutionToken else { return }
            if let blocked = await env.validateMediaURL(result.url) {
                finishResolution(token)
                await settleCover()
                blockedMessage = blocked.message
                return
            }
            guard token == resolutionToken, !Task.isCancelled else { return }
            env.debrid.stashResolution(result, for: item.stream, stremioID: stremioID)
            // The full-screen page stays up while the sheet leaves, so the viewer sees no flash of the list before the player.
            await present(item, env: env, dismiss: dismiss)
            // Keep landscape active as the player takes over the preparing cover.
            finishResolution(token, restoreOrientation: false)
        } catch is CancellationError {
            finishResolution(token)
        } catch let error as DebridError {
            guard token == resolutionToken else { return }
            finishResolution(token)
            await settleCover()
            handle(error, item: item, mode: mode, file: file, provider: env.debrid.selectedProvider)
        } catch {
            guard token == resolutionToken else { return }
            finishResolution(token)
            await settleCover()
            rowFailure = DebridRowFailure(itemID: item.id, message: DebridErrorText.describe(error, provider: env.debrid.selectedProvider), isRetryable: false,
                                          mode: mode, file: file)
        }
    }

    /// A dialog asked for while the full-screen page is still leaving is dropped by iOS: wait for it to be gone.
    /// The black player page leaves and the screen turns back first (up to about two seconds); a dialog asked for while that happens is dropped.
    private func settleCover() async {
        for _ in 0..<20 {
            if !LandscapeHostingController.isShowing { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
    }

    private func receive(_ progress: DebridProgress, sequence: Int, token: UUID) {
        guard token == resolutionToken, sequence > progressSequence, var current = resolution else { return }
        progressSequence = sequence
        current.progress = progress
        resolution = current
    }

    private func finishResolution(_ token: UUID, restoreOrientation: Bool = true) {
        guard token == resolutionToken else { return }
        resolution = nil
        if restoreOrientation {
            endLaunch()
            OrientationController.restore()
        }
    }

    private func handle(_ error: DebridError, item: RankedStream, mode: DebridMode, file: DebridFileCandidate?,
                        provider: DebridService.ProviderChoice) {
        switch error {
        case .notCached:
            if mode == DebridMode.cachedOnly {
                // Not in cache after all: ask before anything is added to the user's account.
                pendingDownload = item
                return
            }
        case .noMatchingFile(let candidates):
            if !candidates.isEmpty {
                fileChoice = DebridFileChoice(item: item, mode: mode, candidates: candidates)
                return
            }
        default:
            break
        }
        rowFailure = DebridRowFailure(itemID: item.id, message: DebridErrorText.message(for: error, provider: provider),
                                      isRetryable: error.isRetryable, mode: mode, file: file)
    }
}

// MARK: - Views
