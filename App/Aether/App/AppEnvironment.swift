import SwiftUI
import AetherCore

/// Composition root: builds the engine (AetherCore) and wires user settings into its behaviour.
@MainActor
final class AppEnvironment: ObservableObject {
    let isUITesting: Bool
    private let uiHooks: UITestHooks
    let paths: AppPaths
    let settings: SettingsStore
    let network: NetworkMonitor
    let diagnostics: DiagnosticLog
    let secrets: SecretStore
    let responseCache: ResponseCache
    let http: URLSessionHTTPClient
    let imageHTTP: URLSessionHTTPClient
    let addonClient: AddonClient
    let registry: AddonRegistry
    let service: AddonService
    let searchService: SearchService
    let libraryStore: LibraryStore
    let images: ImageLoader
    let addons: AddonStore
    let library: LibraryModel
    let router: AppRouter
    let downloads: DownloadManager
    let casting: CastCoordinator
    /// Keys of the optional services (TorBox, TMDB, TheTVDB), kept in the Keychain.
    let credentials: ServiceCredentials
    /// Adds TMDB / TheTVDB data to addon metas when the user has stored a key for them (best effort, never overwrites).
    let metadata: MetadataEnricher
    /// TorBox: connection status, cache check and resolution of torrent streams into playable links (user-supplied key).
    let debrid: DebridService

    /// `arguments` exist so unit tests can build an isolated environment (see `UITestHooks`).
    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let hooks = UITestHooks(arguments: arguments)
        let testing = hooks.isActive
        uiHooks = hooks
        isUITesting = testing
        paths = testing ? AppPaths.uiTest(session: hooks.session, reset: hooks.reset) : AppPaths.standard()
        if testing { hooks.prepareDefaults() }
        let settings = SettingsStore()
        self.settings = settings
        network = NetworkMonitor()
        diagnostics = DiagnosticLog(enabled: settings.value.privacy.keepDiagnosticLog)
        if testing {
            let store = KeychainSecretStore(service: "app.aether.uitest.\(hooks.session)")
            if hooks.reset { store.removeAll() }
            secrets = store
        } else {
            secrets = KeychainSecretStore()
        }

        let snapshot = settings.snapshot
        let allowLoopback = testing
        let policyProvider: @Sendable () -> NetworkPolicy = {
            snapshot.get().networkPolicy(allowLoopback: allowLoopback)
        }
        http = URLSessionHTTPClient(policyProvider: policyProvider)
        imageHTTP = URLSessionHTTPClient(policyProvider: policyProvider)
        responseCache = ResponseCache(directory: paths.responseCacheDirectory)
        addonClient = AddonClient(
            http: http, cache: responseCache,
            cacheEnabled: { snapshot.get().storage.cacheMetadata },
            maxAgeOverride: { kind in
                kind == .catalog ? snapshot.get().content.catalogRefreshMinutes * 60 : nil
            })
        registry = AddonRegistry(store: JSONFileStore<AddonRegistryState>(url: paths.addonsFile),
                                 secrets: secrets, client: addonClient, policyProvider: policyProvider)
        service = AddonService(registry: registry, client: addonClient)
        searchService = SearchService(service: service)
        libraryStore = LibraryStore(store: JSONFileStore<LibraryState>(url: paths.libraryFile),
                                    policy: settings.value.libraryPolicy)
        images = ImageLoader(http: imageHTTP, directory: paths.imageCacheDirectory,
                             diskLimitMB: settings.value.storage.imageCacheLimitMB)
        addons = AddonStore(registry: registry)
        library = LibraryModel(store: libraryStore)
        router = AppRouter()
        downloads = DownloadManager(paths: paths, snapshot: snapshot)
        casting = CastCoordinator(settings: settings)
        let serviceKeys = ServiceCredentials(secrets: secrets)
        credentials = serviceKeys
        // The UI tests point both services at their fixture server; a normal launch always uses the production APIs.
        let tmdbBase = hooks.metadataBaseURL.flatMap { URL(string: $0 + "/tmdb/3") } ?? TMDBClient.productionBaseURL
        let tvdbBase = hooks.metadataBaseURL.flatMap { URL(string: $0 + "/tvdb/v4") } ?? TVDBClient.productionBaseURL
        metadata = MetadataEnricher(
            tmdb: TMDBClient(http: http, credentials: serviceKeys.provider(for: .tmdb), baseURL: tmdbBase),
            tvdb: TVDBClient(http: http, apiKey: serviceKeys.provider(for: .tvdb), pin: serviceKeys.pinProvider(for: .tvdb), baseURL: tvdbBase),
            cache: responseCache)
        // The UI tests point TorBox at their fixture server (a loopback address); a normal launch always uses api.torbox.app.
        let torboxBase = hooks.torboxServerURL.flatMap { DebridService.fixtureAPIBase(from: $0) } ?? TorBoxClient.productionBaseURL
        debrid = DebridService(credentials: serviceKeys, http: http, baseURL: torboxBase, log: diagnostics)

        credentials.onChange = { [weak self] in
            guard let self = self else { return }
            let metadata = self.metadata
            Task { await metadata.reset() }
            self.debrid.credentialsDidChange()
        }
        settings.onChange = { [weak self] new, old in
            self?.settingsDidChange(new: new, old: old)
        }
    }

    /// Async start-up work (disk reads). Safe to call more than once.
    func bootstrap() async {
        await addons.reload()
        await libraryStore.load()
        library.start()
        await library.refresh()
        await downloads.restore()
        await diagnostics.configure(enabled: settings.value.privacy.keepDiagnosticLog,
                                    verbose: settings.value.advanced.verboseLogging)
        await diagnostics.log(.info, "app", "Avvio completato: \(addons.addons.count) addon, rete \(network.interfaceName)")
        casting.start()
        if uiHooks.isActive, let link = uiHooks.openURL, let url = URL(string: link) {
            router.handle(url: url)
        }
    }

    private func settingsDidChange(new: AppSettings, old: AppSettings) {
        if new.libraryPolicy != old.libraryPolicy {
            let policy = new.libraryPolicy
            Task { await libraryStore.setPolicy(policy) }
        }
        if new.privacy.keepDiagnosticLog != old.privacy.keepDiagnosticLog || new.advanced.verboseLogging != old.advanced.verboseLogging {
            Task { await diagnostics.configure(enabled: new.privacy.keepDiagnosticLog, verbose: new.advanced.verboseLogging) }
        }
        if new.storage.imageCacheLimitMB != old.storage.imageCacheLimitMB {
            let limit = new.storage.imageCacheLimitMB
            Task { await images.setDiskLimit(megabytes: limit) }
        }
        if new.content.catalogRefreshMinutes != old.content.catalogRefreshMinutes || new.storage.cacheMetadata != old.storage.cacheMetadata {
            addons.bumpRevision()
        }
        if new.privacy.allowLocalNetwork != old.privacy.allowLocalNetwork {
            addons.bumpRevision()
        }
        casting.settingsDidChange(new.casting)
        downloads.settingsDidChange()
    }

    /// Called when the app leaves the foreground: pending (debounced) writes must reach the disk before iOS may
    /// suspend or terminate the process. A background task buys the few hundred milliseconds the write needs.
    func persistForBackground() {
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "aether.persist") {
            UIApplication.shared.endBackgroundTask(task)
        }
        let store = libraryStore
        Task {
            await store.flush()
            await MainActor.run {
                if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            }
        }
    }

    // MARK: Data management (Settings → Archiviazione / Account e dati)

    func clearMetadataCache() async {
        await responseCache.clear()
        addons.bumpRevision()
    }

    func clearImageCache() async {
        await images.clearDisk()
    }

    struct StorageReport {
        var images: Int64
        var metadata: Int64
        var downloads: Int64
    }

    func storageReport() async -> StorageReport {
        async let imagesBytes = images.diskUsage()
        async let metadataBytes = responseCache.diskUsage()
        let downloadsBytes = AppPaths.directorySize(paths.downloadsDirectory)
        return StorageReport(images: await imagesBytes, metadata: await metadataBytes, downloads: downloadsBytes)
    }

    /// Removes everything the app stores locally: library, addons (and their Keychain URLs), downloads, caches, settings.
    func deleteAllLocalData() async {
        await registry.removeAll()
        await libraryStore.deleteAll()
        await downloads.removeAll()
        await responseCache.clear()
        await images.clearDisk()
        await diagnostics.clear()
        (secrets as? KeychainSecretStore)?.removeAll()
        settings.resetToDefaults()
        await addons.reload()
        await library.refresh()
    }
}


/// Launch arguments honoured only when the app is started by the UI tests (`-AETHER_UITEST`).
///   -AETHER_UITEST_SESSION <id>   storage namespace; reuse the id to test persistence across launches
///   -AETHER_UITEST_RESET          wipe that namespace (and stored settings) before starting
///   -AETHER_UITEST_SETTINGS <json> partial AppSettings JSON applied on top of the defaults
///   -AETHER_UITEST_OPENURL <url>  handled like a deep link once the app has started
///   -AETHER_UITEST_METADATA_BASE <url>  base of the fixture server that stands in for the TMDB (/tmdb/3) and TheTVDB (/tvdb/v4) APIs
///   -AETHER_UITEST_TORBOX_URL <url>  address of the TorBox fixture server (for example http://127.0.0.1:7778); the app adds /v1/api.
///                                    Only loopback and private-network addresses are accepted, so the key can never go elsewhere.
/// In this mode loopback addresses are allowed so the tests can talk to the fixture server.
struct UITestHooks {
    let isActive: Bool
    let session: String
    let reset: Bool
    let settingsJSON: String?
    let openURL: String?
    let metadataBaseURL: String?
    let torboxServerURL: String?

    init(arguments: [String]) {
        isActive = arguments.contains("-AETHER_UITEST")
        reset = arguments.contains("-AETHER_UITEST_RESET")
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        session = value(after: "-AETHER_UITEST_SESSION") ?? UUID().uuidString
        settingsJSON = value(after: "-AETHER_UITEST_SETTINGS")
        openURL = value(after: "-AETHER_UITEST_OPENURL")
        metadataBaseURL = isActive ? value(after: "-AETHER_UITEST_METADATA_BASE") : nil
        torboxServerURL = isActive ? value(after: "-AETHER_UITEST_TORBOX_URL") : nil
    }

    func prepareDefaults() {
        let key = "aether.settings.v1"
        let defaults = UserDefaults.standard
        if reset { defaults.removeObject(forKey: key) }
        if let json = settingsJSON, let data = json.data(using: .utf8),
           let settings = try? JSONDecoder.aether().decode(AppSettings.self, from: data),
           let encoded = try? JSONEncoder.aether().encode(settings) {
            defaults.set(encoded, forKey: key)
        }
    }
}
