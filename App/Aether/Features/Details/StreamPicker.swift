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
            capabilities: capabilities)
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
    private var launch: PlayerLaunch?
    private weak var launchRouter: AppRouter?
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
        if debridProvider == .realdebrid && debridConfigured {
            return list.filter { DebridStreamLogic.isTorrent($0.stream) }
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
        pendingAddons = RequestPlanner.addons(for: path, handles: handles).map { $0.addon.displayName }
        if pendingAddons.isEmpty {
            isLoading = false
            return
        }
        for await batch in env.service.streams(type: type, videoID: videoID) {
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
                let resolvedStream = resolution.playableStream(from: item.stream)
                if let refusal = await env.downloads.enqueue(meta: self.request.meta, video: self.request.video,
                                                             stream: resolvedStream, allowLocalNetwork: allowLocal, ephemeralURL: resolution.url) {
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

    /// Puts the player's black page (logo, progress) on screen at once, over the list, turning the screen only once. Not in Theater Mode.
    private func beginLaunch(env: AppEnvironment, dismiss: @escaping () -> Void) {
        guard !env.router.theater, env.settings.value.playback.instantLaunchPage else { return }
        endLaunch()
        let page = PlayerLaunch(meta: request.meta) { [weak self] in self?.cancelResolution() }
        page.resolution = resolution
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

private enum PickerEntry: Identifiable {
    case stream(offset: Int, item: RankedStream)
    case progress(itemID: String)
    case failure(itemID: String)

    var id: String {
        switch self {
        case .stream(_, let item): return "stream:" + item.id
        case .progress(let itemID): return "progress:" + itemID
        case .failure(let itemID): return "failure:" + itemID
        }
    }
}

struct StreamPickerSheet: View {
    let request: StreamPickerRequest
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var model: StreamPickerModel
    @State private var showUnplayable = false
    @State private var packItem: RankedStream?

    init(request: StreamPickerRequest) {
        self.request = request
        _model = StateObject(wrappedValue: StreamPickerModel(request: request))
    }

    var body: some View {
        NavigationStack {
            List {
                header
                if model.addonNames.count > 1 {
                    Section { chips }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                if let failure = model.cacheCheckFailure, model.hasTorrentRows, model.debridProvider == .torbox {
                    Section { cacheNotice(failure) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                let playable = model.filtered(model.playable)
                if !playable.isEmpty {
                    Section(header: Text("Sorgenti riproducibili")) {
                        ForEach(entries(for: playable)) { entry in
                            entryRow(entry)
                        }
                    }
                }
                if model.isLoading {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playable.isEmpty ? "Cerco sorgenti…" : "Altre sorgenti in arrivo…").font(.subheadline.weight(.medium))
                                if !model.pendingAddons.isEmpty {
                                    Text("In attesa di: \(model.pendingAddons.joined(separator: ", "))").font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("stream.loading")
                    }
                } else if model.ranked.isEmpty || (!model.isLoading && model.debridProvider == .realdebrid && model.debridConfigured && model.playable.isEmpty) {
                    Section { emptyState }
                }
                let unplayable = model.filtered(model.unplayable)
                if !unplayable.isEmpty {
                    Section {
                        DisclosureGroup("Non riproducibili su iOS (\(unplayable.count))", isExpanded: $showUnplayable) {
                            ForEach(unplayable) { item in
                                StreamRow(item: item, isBest: false, debrid: model.appearance(for: item)) { openExternally(item) }
                                    .contextMenu {
                                        copyLinkButton(item)
                                        externalPlayerMenu(item)
                                    }
                            }
                        }
                    }
                }
                if !model.errors.isEmpty {
                    Section(header: Text("Addon con problemi")) {
                        ForEach(model.errors.keys.sorted(), id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.subheadline.weight(.semibold))
                                Text(model.errors[name]?.message ?? "").font(.caption).foregroundStyle(Color.aetherSecondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Scegli la sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Cerca tra le sorgenti (nome, qualità, lingua…)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
            .alert("Impossibile completare", isPresented: Binding(get: { model.blockedMessage != nil }, set: { if !$0 { model.blockedMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.blockedMessage ?? "")
            }
            .overlay(alignment: .bottom) {
                if let info = model.infoMessage {
                    Text(info)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .aetherGlassCapsule()
                        .padding(.bottom, 20)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            model.infoMessage = nil
                        }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.infoMessage)
        }
        .presentationDetents([.large])
        .sheet(item: $packItem) { item in
            PackDownloadSheet(item: item, meta: model.request.meta, video: model.request.video)
        }
        .confirmationDialog(DebridUserText.downloadConfirmationTitle,
                            isPresented: Binding(get: { model.pendingDownload != nil }, set: { if !$0 { model.pendingDownload = nil } }),
                            titleVisibility: .visible,
                            presenting: model.pendingDownload) { (pending: RankedStream) in
            Button("Avvia il download") { model.confirmDownload(pending, env: env) { dismiss() } }
            Button("Annulla", role: .cancel) {}
        } message: { (_: RankedStream) in
            Text(DebridUserText.downloadConfirmationMessage)
        }
        // The page of the player opens at once while TorBox is contacted: the film's logo (with a fanart.tv key) or its title.
        .fullScreenCover(isPresented: Binding(get: { model.resolution != nil && !model.usesLaunchPage }, set: { if !$0 { model.cancelResolution() } })) {
            PlaybackPreparingView(meta: request.meta, resolution: model.resolution) { model.cancelResolution() }
                .environmentObject(env)
        }
        .sheet(item: $model.fileChoice) { (choice: DebridFileChoice) in
            DebridFileChoiceSheet(choice: choice) { (file: DebridFileCandidate) in
                model.chooseFile(file, from: choice, env: env) { dismiss() }
            }
        }
        .onAppear {
            model.start(env: env) { best in
                Task { await model.play(best, env: env) { dismiss() } }
            }
        }
        .onDisappear { model.stop() }
    }

    private func entries(for list: [RankedStream]) -> [PickerEntry] {
        var result: [PickerEntry] = []
        for (offset, item) in list.enumerated() {
            result.append(PickerEntry.stream(offset: offset, item: item))
            if model.resolution?.itemID == item.id { result.append(PickerEntry.progress(itemID: item.id)) }
            if model.rowFailure?.itemID == item.id { result.append(PickerEntry.failure(itemID: item.id)) }
        }
        return result
    }

    @ViewBuilder
    private func entryRow(_ entry: PickerEntry) -> some View {
        switch entry {
        case .stream(let offset, let item):
            streamRow(offset: offset, item: item)
        case .progress:
            if let state = model.resolution {
                DebridProgressRow(state: state) { model.cancelResolution() }
            }
        case .failure:
            if let failure = model.rowFailure {
                DebridFailureRow(failure: failure) { model.retryResolution(env: env) { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func streamRow(offset: Int, item: RankedStream) -> some View {
        StreamRow(item: item, isBest: offset == 0, debrid: model.appearance(for: item)) {
            Task { await model.play(item, env: env) { dismiss() } }
        }
        .accessibilityIdentifier("stream.row.\(offset)")
        .swipeActions(edge: .trailing) {
            Button { Task { await model.download(item, env: env) } } label: {
                Label("Scarica", systemImage: "arrow.down.circle")
            }
            .tint(settings.accentColor)
        }
        .contextMenu {
            Button { Task { await model.play(item, env: env) { dismiss() } } } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            Button { Task { await model.download(item, env: env) } } label: {
                Label("Scarica per guardarlo offline", systemImage: "arrow.down.circle")
            }
            if DebridStreamLogic.isTorrent(item.stream), model.request.meta.type == "series" {
                Button { packItem = item } label: {
                    Label("Scarica più episodi del pack…", systemImage: "arrow.down.square.stack")
                }
            }
            copyLinkButton(item)
            externalPlayerMenu(item)
        }
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                RemoteImage(urlString: model.request.meta.poster, width: 120, placeholderSeed: model.request.meta.name)
                    .frame(width: 52, height: 77)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.request.meta.name).font(.headline).lineLimit(2)
                    if let video = model.request.video, let label = video.episodeLabel {
                        Text("\(label) · \(video.title)").font(.subheadline).foregroundStyle(Color.aetherSecondary).lineLimit(2)
                    }
                    if let resume = model.request.resumeAt, resume > 0 {
                        Text("Riprende da \(Format.duration(resume))").font(.caption).foregroundStyle(settings.accentColor)
                    }
                }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                FilterChip(title: "Tutti", isSelected: model.addonFilter == nil) { model.addonFilter = nil }
                ForEach(model.addonNames, id: \.self) { name in
                    FilterChip(title: name, isSelected: model.addonFilter == name) { model.addonFilter = name }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    /// The cache check failed: the torrent rows carry no badge, and this says why (with a retry when trying again can help).
    private func cacheNotice(_ failure: DebridError) -> some View {
        let provider = model.debridProvider.title
        let text: String = "Non riesco a controllare la cache di \(provider). " +
            DebridErrorText.message(for: failure, provider: model.debridProvider)
        let retryAction: (() -> Void)? = failure.isRetryable ? { () -> Void in model.retryCacheCheck() } : nil
        return DebridCacheNotice(message: text, retry: retryAction)
    }

    @ViewBuilder
    private var emptyState: some View {
        let handles = env.addons.enabledAddons
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Color.aetherSecondary)
            Text("Nessuna sorgente trovata").font(.headline)
            Text(handles.isEmpty ? "Non c'è nessun addon attivo." : (model.debridProvider == .realdebrid && model.debridConfigured
                ? "Gli addon attivi non hanno restituito sorgenti torrent utilizzabili con Real-Debrid per questo titolo."
                : "Gli addon attivi non hanno restituito sorgenti per questo titolo. Prova un altro addon o riprova più tardi."))
                .font(.footnote).foregroundStyle(Color.aetherSecondary).multilineTextAlignment(.center)
            Button("Riprova") { model.start(env: env) { _ in } }.buttonStyle(SecondaryActionButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityIdentifier("stream.empty")
    }

    /// «Copia il link» for any source, whatever it is (direct link, web page, torrent as a magnet, YouTube, live channel).
    @ViewBuilder
    private func copyLinkButton(_ item: RankedStream) -> some View {
        if let link = item.stream.shareableLink {
            Button {
                UIPasteboard.general.string = link
                if case .torrent = item.stream.source { model.infoMessage = "Magnet copiato" } else { model.infoMessage = "Link copiato" }
            } label: {
                Label("Copia il link", systemImage: "link")
            }
            if DebridStreamLogic.isTorrent(item.stream) {
                Button {
                    Task {
                        if let address = await model.playbackLink(item, env: env) {
                            UIPasteboard.general.string = address.absoluteString
                            model.infoMessage = "Link di riproduzione copiato. Contiene il tuo accesso al servizio e scade: non condividerlo."
                        }
                    }
                } label: {
                    Label("Copia il link di riproduzione (via debrid)", systemImage: "link.badge.plus")
                }
            }
        }
    }

    /// «Apri in un lettore esterno»: VLC, Infuse, nPlayer, Outplayer (solo quelli installati), per le fonti con un indirizzo diretto
    /// e per i torrent (il link lo fa il servizio debrid configurato).
    @ViewBuilder
    private func externalPlayerMenu(_ item: RankedStream) -> some View {
        if item.stream.directMediaURL != nil || DebridStreamLogic.isTorrent(item.stream) {
            let installed = ExternalPlayer.allCases.filter { (player: ExternalPlayer) -> Bool in
                guard let probe = player.probeURL else { return false }
                return UIApplication.shared.canOpenURL(probe)
            }
            let live = env.settings.value.playback
            Menu {
                if !live.liveContainerBundleID.isEmpty {
                    Button {
                        Task {
                            guard let media = await model.playbackLink(item, env: env) else { return }
                            if let address = LiveContainerLauncher.url(scheme: live.liveContainerScheme, bundleID: live.liveContainerBundleID,
                                                                       media: media, player: live.liveContainerPlayer) {
                                openURL(address)
                            } else {
                                model.blockedMessage = "Controlla le impostazioni di LiveContainer (id dell'app e schema)."
                            }
                        }
                    } label: {
                        Text("LiveContainer · \(live.liveContainerPlayer.title)")
                    }
                }
                if installed.isEmpty && live.liveContainerBundleID.isEmpty {
                    Text("Nessun lettore esterno installato (VLC, Infuse, nPlayer, Outplayer)")
                } else {
                    ForEach(installed, id: \.self) { player in
                        Button {
                            Task {
                                if let address = await model.externalPlayerURL(item, player: player, env: env) { openURL(address) }
                                if item.stream.needsRequestHeaders {
                                    model.infoMessage = "Questa fonte richiede intestazioni particolari: il lettore esterno potrebbe riceverne un 403."
                                }
                            }
                        } label: {
                            Text(player.title)
                        }
                    }
                }
            } label: {
                Label("Apri in un lettore esterno", systemImage: "arrow.up.forward.app")
            }
        }
    }

    private func openExternally(_ item: RankedStream) {
        switch item.stream.source {
        case .youtube(let id):
            if let url = URL(string: "https://www.youtube.com/watch?v=\(id)") { openURL(url) }
        case .external(let string):
            if let url = URL.lenient(string), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" { openURL(url) }
        case .torrent:
            model.blockedMessage = DebridUserText.torrentNeedsTorBox
        default:
            // Nothing to open: say why instead of ignoring the tap.
            if case .unsupported(let reason) = item.info.support { model.blockedMessage = reason.message }
        }
    }
}

struct StreamRow: View {
    let item: RankedStream
    let isBest: Bool
    var debrid: DebridRowAppearance? = nil
    let action: () -> Void
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var env: AppEnvironment

    private var display: StreamDisplaySettings { settings.value.content.streamDisplay }

    /// The logo of the addon that produced this source, when the viewer asked for it and the addon has one.
    private var addonLogo: URL? {
        guard display.showAddonLogo, let name = item.stream.addonName else { return nil }
        return env.addons.addons.first(where: { $0.displayName == name })?.manifest.logo.flatMap { URL(string: $0) }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    if isBest {
                        Label("Consigliata", systemImage: "sparkles")
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                            .foregroundStyle(settings.accentColor)
                    }
                    Spacer()
                    if let addon = item.stream.addonName {
                        HStack(spacing: 4) {
                            if let logo = addonLogo {
                                AsyncImage(url: logo) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    Color.clear
                                }
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .accessibilityHidden(true)
                            }
                            Text(addon).font(.caption2).foregroundStyle(Color.aetherSecondary)
                        }
                    }
                }
                if display.template.isEmpty {
                    Text(item.stream.name ?? "Sorgente")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let details = item.stream.details, !details.isEmpty {
                        Text(details).font(.caption).foregroundStyle(Color.aetherSecondary).lineLimit(3)
                    }
                } else {
                    Text(StreamFormatter.line(template: display.template, info: item.info, stream: item.stream))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                FlowBadges(info: item.info, display: display, stream: item.stream)
                if let debrid = debrid {
                    DebridBadgeRow(appearance: debrid)
                }
                if case .unsupported(let reason) = item.info.support {
                    Label(reason.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if let debrid = debrid, !debrid.torBoxConfigured {
                    Label(DebridUserText.configureHint, systemImage: "key")
                        .font(.caption).foregroundStyle(Color.aetherSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(item.info.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(Color.aetherSecondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hintText)
    }

    private var hintText: String {
        guard item.info.support.isPlayable else { return "Non riproducibile" }
        if let debrid = debrid, debrid.torBoxConfigured {
            switch debrid.badge {
            case .some(DebridCacheBadge.notCached): return "Richiede un download su TorBox, con conferma"
            case .some(DebridCacheBadge.cached): return "Riproduci tramite TorBox: il contenuto è in cache"
            default: return "Controlla TorBox e riproduci questa sorgente"
            }
        }
        return "Riproduci questa sorgente"
    }
}

/// "Torrent" plus the TorBox cache badge. The badge says only what the cache check answered.
struct DebridBadgeRow: View {
    let appearance: DebridRowAppearance

    var body: some View {
        WrappingHStack(spacing: 6) {
            Text("Torrent")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.09), in: Capsule())
            if let badge = appearance.badge {
                // Built like the "Torrent" pill beside it: ONE Text (icon and words inside it) with padding and a capsule, so it
                // is sized by its content the same way. A device showed the earlier `Label` version as a tall capsule holding
                // only the check mark; the cause was not reproduced in a unit test, this removes the `Label` altogether.
                (Text(Image(systemName: badge.systemImage)).foregroundStyle(color(for: badge))
                    + Text(" " + badge.label).foregroundStyle(.primary))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color(for: badge).opacity(0.16), in: Capsule())
                    .accessibilityLabel(badge.accessibilityText)
            }
        }
    }

    private func color(for badge: DebridCacheBadge) -> Color {
        switch badge {
        case .checking: return Color.gray
        case .cached: return Color.green
        case .notCached: return Color.orange
        }
    }
}

/// Why the cache check could not be made, with a retry when trying again can help. The torrent rows show no badge meanwhile.
struct DebridCacheNotice: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stream.debrid.cacheError")
            if let retry = retry {
                Button(action: retry) {
                    Text("Riprova")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stream.debrid.cacheRetry")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherGlassCard(cornerRadius: 14)
        .padding(.horizontal, Theme.pageMargin)
    }
}

/// Progress of the resolution under the row that was tapped: the step, and for a real download percent, speed and time left.
struct DebridProgressRow: View {
    let state: DebridRowResolution
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = state.determinateFraction {
                ProgressView(value: fraction) {
                    Text(state.message).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(state.message).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let detail = state.detail {
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Color.aetherSecondary)
            }
            Button(role: .cancel, action: cancel) {
                Text("Annulla")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Annulla l'attesa di TorBox")
            .accessibilityHint("Smette di attendere. Quello che è già stato aggiunto al tuo account TorBox resta lì.")
            .accessibilityIdentifier("stream.debrid.cancel")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream.debrid.progress")
    }
}

/// A clear Italian message under the row, with a retry when trying again can help.
struct DebridFailureRow: View {
    let failure: DebridRowFailure
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(failure.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if failure.isRetryable {
                Button(action: retry) {
                    Text("Riprova")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("stream.debrid.retry")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stream.debrid.error")
    }
}

/// The video files of a torrent when the right one cannot be found automatically (an episode in a season pack).
struct DebridFileChoiceSheet: View {
    let choice: DebridFileChoice
    let onSelect: (DebridFileCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choice.candidates, id: \.id) { file in
                        Button { onSelect(file) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.subheadline.weight(.medium)).lineLimit(3)
                                if let size = file.size, size > 0 {
                                    Text(Format.bytes(size)).font(.caption).foregroundStyle(Color.aetherSecondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("stream.debrid.file.\(file.id)")
                    }
                } header: {
                    Text("File video nel torrent")
                } footer: {
                    Text("Non riesco a capire da solo quale file corrisponde a questo episodio: scegli quello giusto.")
                }
            }
            .navigationTitle("Scegli il file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("stream.debrid.fileChoice")
    }
}

/// Wrapping row of small badges (quality, codec, HDR, audio, languages, size).
struct FlowBadges: View {
    let info: StreamInfo
    var display = StreamDisplaySettings()
    var stream: AddonStream?

    var body: some View {
        let badges = StreamFormatter.badges(for: info, settings: display)
        let imported = stream.map { CustomBadgePack.badges(for: $0, rules: display.customBadges) } ?? []
        if !badges.isEmpty || !imported.isEmpty {
            WrappingHStack(spacing: 6) {
                ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                    if badge.kind == .format {
                        // The file format keeps its own look so it reads apart from quality, codec and language.
                        Text(badge.text)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.35), lineWidth: 1))
                            .accessibilityLabel("Formato \(badge.text)")
                            .accessibilityIdentifier("stream.format")
                    } else {
                        pill(badge)
                    }
                }
                ForEach(imported) { rule in
                    ImportedBadgeView(rule: rule)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(_ badge: StreamBadge) -> some View {
        let text = Text(badge.text).font(.system(size: 11, weight: .semibold, design: .rounded))
        switch display.badgeStyle {
        case .filled:
            text.padding(.horizontal, 7).padding(.vertical, 3).background(tint(badge.kind).opacity(0.16), in: Capsule())
        case .outline:
            text.padding(.horizontal, 7).padding(.vertical, 3).overlay(Capsule().strokeBorder(tint(badge.kind).opacity(0.6), lineWidth: 1))
        case .plain:
            text.foregroundStyle(tint(badge.kind))
        }
    }

    private func tint(_ kind: StreamBadgeKind) -> Color {
        switch kind {
        case .quality: return .blue
        case .hdr: return .orange
        case .audio: return .purple
        case .codec: return .teal
        case .language: return .green
        case .size, .format: return .gray
        }
    }
}

/// Minimal flow layout (iOS 16+ `Layout`).
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


/// A badge imported from a link: its own picture when it has one (with the name as fallback), else a coloured pill.
struct ImportedBadgeView: View {
    let rule: CustomBadgeRule

    var body: some View {
        if let raw = rule.imageURL, let url = URL(string: raw) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    pill
                }
            }
            .frame(height: 20)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(rule.label)
        } else {
            pill
        }
    }

    private var pill: some View {
        let accent = rule.colorHex.map { Color(hex: $0) } ?? Color.primary
        return Text(rule.label)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(accent)
            .background((rule.fillHex.map { Color(hex: $0) } ?? Color.gray).opacity(rule.fillAlpha), in: Capsule())
            .overlay(Capsule().strokeBorder(rule.borderHex.map { Color(hex: $0) } ?? Color.clear, lineWidth: 1))
    }
}

// MARK: - Scaricare più episodi di un pack

/// Legge i file di un torrent con una stagione intera e scarica gli episodi scelti, uno dopo l'altro, dal servizio debrid.
@MainActor
final class PackDownloadModel: ObservableObject {
    struct Episode: Identifiable, Hashable {
        let season: Int
        let episode: Int
        var id: String { return "\(season)x\(episode)" }
        var label: String { return String(format: "S%02dE%02d", season, episode) }
    }

    @Published private(set) var episodes: [Episode] = []
    @Published var selected: Set<String> = []
    @Published private(set) var loading = true
    @Published private(set) var message: String?
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var finished: String?

    func load(item: RankedStream, meta: MetaItem, video: Video?, env: AppEnvironment) async {
        guard env.debrid.isConfigured else {
            message = "Configura TorBox o Real-Debrid in Impostazioni ▸ Servizi."
            loading = false
            return
        }
        let stremioID = DebridStreamLogic.stremioID(meta: meta, video: video)
        guard let request = DebridRequest(stream: item.stream, stremioID: stremioID, mode: .cachedOnly) else {
            message = "Questa sorgente non è un torrent valido."
            loading = false
            return
        }
        do {
            let result = try await env.debrid.resolve(request, onProgress: nil)
            var found: [Episode] = []
            for file in result.packFiles {
                guard let season = file.season, let first = file.firstEpisode else { continue }
                for number in first...max(first, file.lastEpisode ?? first) { found.append(Episode(season: season, episode: number)) }
            }
            let unique = Array(Set(found)).sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            episodes = unique
            selected = Set(unique.map { $0.id })
            if unique.count < 2 { message = "Questo torrent non sembra contenere più episodi." }
        } catch let error as DebridError {
            if case .notCached = error {
                message = "Il torrent non è già pronto sul tuo servizio. Avvialo una volta dalla riproduzione normale (viene aggiunto al tuo account) e poi riprova."
            } else {
                message = error.message
            }
        } catch {
            message = DebridErrorText.describe(error, provider: env.debrid.selectedProvider)
        }
        loading = false
    }

    func download(item: RankedStream, meta: MetaItem, env: AppEnvironment) async {
        let chosen = episodes.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, progress == nil else { return }
        progress = (0, chosen.count)
        finished = nil
        var started = 0
        var failed = 0
        let allowLocal = env.settings.value.privacy.allowLocalNetwork
        for (index, entry) in chosen.enumerated() {
            let known = meta.videos.first { $0.season == entry.season && $0.episode == entry.episode }
            let video = known ?? Video(id: "\(meta.id):\(entry.season):\(entry.episode)", title: "Episodio \(entry.episode)",
                                       season: entry.season, episode: entry.episode)
            if let request = DebridRequest(stream: item.stream, stremioID: video.id, mode: .cachedOnly) {
                do {
                    let resolution = try await env.debrid.resolve(request, onProgress: nil)
                    let resolved = resolution.playableStream(from: item.stream)
                    let refusal = await env.downloads.enqueue(meta: meta, video: video, stream: resolved,
                                                              allowLocalNetwork: allowLocal, ephemeralURL: resolution.url)
                    if refusal == nil { started += 1 } else { failed += 1 }
                } catch {
                    failed += 1
                }
            } else {
                failed += 1
            }
            progress = (index + 1, chosen.count)
        }
        progress = nil
        finished = "Download avviati: \(started)" + (failed > 0 ? " · non riusciti: \(failed)" : "") + ". Li trovi in Libreria ▸ Download."
    }
}

struct PackDownloadSheet: View {
    let item: RankedStream
    let meta: MetaItem
    let video: Video?
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PackDownloadModel()

    var body: some View {
        NavigationStack {
            List {
                if model.loading {
                    HStack(spacing: 10) { ProgressView(); Text("Leggo i file del torrent…").foregroundStyle(Color.aetherSecondary) }
                }
                if let message = model.message {
                    Text(message).font(.footnote).foregroundStyle(Color.aetherSecondary)
                }
                if !model.episodes.isEmpty {
                    Section {
                        HStack {
                            Button("Seleziona tutti") { model.selected = Set(model.episodes.map { $0.id }) }
                            Spacer()
                            Button("Nessuno") { model.selected = [] }
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(seasons, id: \.self) { season in
                        Section(header: Text(season == 0 ? "Speciali" : "Stagione \(season)")) {
                            ForEach(model.episodes.filter { $0.season == season }) { entry in
                                Toggle(isOn: Binding(
                                    get: { model.selected.contains(entry.id) },
                                    set: { on in if on { model.selected.insert(entry.id) } else { model.selected.remove(entry.id) } })) {
                                    HStack {
                                        Text(entry.label).font(.system(.body, design: .monospaced))
                                        if let title = meta.videos.first(where: { $0.season == entry.season && $0.episode == entry.episode })?.title {
                                            Text(title).foregroundStyle(Color.aetherSecondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if let progress = model.progress {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Preparo i download: \(progress.done) di \(progress.total)").font(.footnote)
                            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        }
                    }
                }
                if let finished = model.finished {
                    Section { Label(finished, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote) }
                }
            }
            .navigationTitle("Episodi del pack")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() }.disabled(model.progress != nil) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Scarica \(model.selected.count)") { Task { await model.download(item: item, meta: meta, env: env) } }
                        .disabled(model.selected.isEmpty || model.progress != nil || model.loading)
                }
            }
            .task { await model.load(item: item, meta: meta, video: video, env: env) }
        }
        .presentationDetents([.medium, .large])
    }

    private var seasons: [Int] {
        return Array(Set(model.episodes.map { $0.season })).sorted()
    }
}
