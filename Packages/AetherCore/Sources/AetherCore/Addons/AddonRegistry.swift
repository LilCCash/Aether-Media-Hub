import Foundation

/// A persisted addon. The transport URL (which may embed API keys) is *not* stored here: it lives in the
/// `SecretStore` (Keychain) under `secretKey`. Only the host is kept for display.
public struct InstalledAddon: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var manifest: AddonManifest
    public var host: String
    public var fingerprint: String
    public var isEnabled: Bool
    public var installedAt: Date
    public var updatedAt: Date
    public var lastRefreshAt: Date?
    public var lastError: String?
    /// Catalog keys (`type/id`) hidden from Home / Discover by the user.
    public var hiddenCatalogs: [String]
    public var nameOverride: String?
    public var isLocalNetwork: Bool
    public var isOfficial: Bool
    /// The secret URL is missing (e.g. restored from a backup, Keychain cleared): the addon must be re-added.
    public var needsReinstall: Bool

    public init(id: UUID = UUID(), manifest: AddonManifest, host: String, fingerprint: String,
                isEnabled: Bool = true, installedAt: Date = Date(), updatedAt: Date = Date(),
                lastRefreshAt: Date? = nil, lastError: String? = nil, hiddenCatalogs: [String] = [],
                nameOverride: String? = nil, isLocalNetwork: Bool = false, isOfficial: Bool = false,
                needsReinstall: Bool = false) {
        self.id = id
        self.manifest = manifest
        self.host = host
        self.fingerprint = fingerprint
        self.isEnabled = isEnabled
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.lastRefreshAt = lastRefreshAt
        self.lastError = lastError
        self.hiddenCatalogs = hiddenCatalogs
        self.nameOverride = nameOverride
        self.isLocalNetwork = isLocalNetwork
        self.isOfficial = isOfficial
        self.needsReinstall = needsReinstall
    }

    public var displayName: String {
        if let override = nameOverride, !override.isEmpty { return override }
        return manifest.name
    }

    public var secretKey: String { return AddonRegistry.secretPrefix + id.uuidString }

    public func isCatalogVisible(_ catalog: ManifestCatalog) -> Bool {
        return !hiddenCatalogs.contains(catalog.key)
    }
}

/// Everything the request layer needs to talk to one addon.
public struct AddonHandle: Sendable, Identifiable {
    public var addon: InstalledAddon
    public var transportURL: URL
    public var id: UUID { return addon.id }

    public init(addon: InstalledAddon, transportURL: URL) {
        self.addon = addon
        self.transportURL = transportURL
    }
}

public enum AddonInstallWarning: Equatable, Sendable {
    case unknownAddon
    case p2p
    case adult
    case localNetwork
    case sameIdDifferentURL(existingName: String)
}

public struct AddonInstallPreview: Sendable {
    public var transportURL: URL
    public var manifest: AddonManifest
    public var warnings: [AddonInstallWarning]
    /// Non-nil when an addon with the same transport URL is already installed (installing updates it).
    public var existing: InstalledAddon?
    public var isOfficial: Bool
}

public struct AddonRegistryState: Codable, Sendable {
    public var schemaVersion: Int
    public var addons: [InstalledAddon]

    public init(schemaVersion: Int = 1, addons: [InstalledAddon] = []) {
        self.schemaVersion = schemaVersion
        self.addons = addons
    }
}

public enum KnownAddons {
    /// Stremio's public metadata addon. Offered as a recommendation; never installed silently.
    public static let cinemetaManifestURL = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!
    public static let cinemetaID = "com.linvo.cinemeta"
    public static let cinemetaHost = "v3-cinemeta.strem.io"

    public static func isOfficial(manifest: AddonManifest, url: URL) -> Bool {
        return manifest.id == cinemetaID && url.host?.lowercased() == cinemetaHost && url.scheme?.lowercased() == "https"
    }
}

/// Installed-addon database. Actor: all mutations are serialised; every change is persisted.
public actor AddonRegistry {
    public static let secretPrefix = "addon.transport."

    private let store: JSONFileStore<AddonRegistryState>
    private let secrets: SecretStore
    private let client: AddonClient
    private let policyProvider: @Sendable () -> NetworkPolicy
    private let now: @Sendable () -> Date

    private var addons: [InstalledAddon] = []
    private var urls: [UUID: URL] = [:]
    private var loaded = false

    public init(store: JSONFileStore<AddonRegistryState>, secrets: SecretStore, client: AddonClient,
                policyProvider: @escaping @Sendable () -> NetworkPolicy,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.secrets = secrets
        self.client = client
        self.policyProvider = policyProvider
        self.now = now
    }

    // MARK: Loading

    /// Loads persisted addons and their secret URLs. Safe to call repeatedly.
    @discardableResult
    public func load() -> [InstalledAddon] {
        if loaded { return addons }
        loaded = true
        let state = store.load() ?? AddonRegistryState()
        addons = state.addons
        urls = [:]
        var changed = false
        for index in addons.indices {
            let addon = addons[index]
            if let string = (try? secrets.get(addon.secretKey)) ?? nil, let url = URL(string: string) {
                urls[addon.id] = url
                if addons[index].needsReinstall {
                    addons[index].needsReinstall = false
                    changed = true
                }
            } else if !addons[index].needsReinstall {
                addons[index].needsReinstall = true
                changed = true
            }
        }
        if changed { persist() }
        return addons
    }

    public func all() -> [InstalledAddon] {
        load()
        return addons
    }

    public func addon(id: UUID) -> InstalledAddon? {
        load()
        return addons.first(where: { $0.id == id })
    }

    /// Enabled, usable addons in user order, ready for requests.
    public func handles(includeDisabled: Bool = false) -> [AddonHandle] {
        load()
        return addons.compactMap { addon in
            guard includeDisabled || addon.isEnabled, !addon.needsReinstall, let url = urls[addon.id] else { return nil }
            return AddonHandle(addon: addon, transportURL: url)
        }
    }

    /// The secret URL, for "copy/share addon link" and configuration pages. Never log it.
    public func transportURL(for id: UUID) -> URL? {
        load()
        return urls[id]
    }

    // MARK: Install

    /// Fetches and validates the manifest without changing any state.
    public func preview(input: String) async throws -> AddonInstallPreview {
        load()
        let url = try AddonURL.parseInstallInput(input)
        let policy = policyProvider()
        try await policy.validate(url, purpose: .addonRequest)
        let manifest = try await client.fetchManifest(url)
        if manifest.behaviorHints.configurationRequired {
            throw AddonError.configurationRequired
        }
        let key = AddonURL.canonicalKey(url)
        let fingerprint = Hashing.sha256Hex(key)
        let existing = addons.first(where: { $0.fingerprint == fingerprint })
        let official = KnownAddons.isOfficial(manifest: manifest, url: url)
        var warnings: [AddonInstallWarning] = []
        if !official { warnings.append(.unknownAddon) }
        if manifest.behaviorHints.p2p { warnings.append(.p2p) }
        if manifest.behaviorHints.adult { warnings.append(.adult) }
        if await policy.isLocalNetwork(url) { warnings.append(.localNetwork) }
        if existing == nil, let sameID = addons.first(where: { $0.manifest.id == manifest.id }) {
            warnings.append(.sameIdDifferentURL(existingName: sameID.displayName))
        }
        return AddonInstallPreview(transportURL: url, manifest: manifest, warnings: warnings,
                                   existing: existing, isOfficial: official)
    }

    /// Persists a previewed addon. If the same transport URL exists it is *updated*, preserving the user's
    /// enable flag, hidden catalogs, name override and position.
    @discardableResult
    public func install(_ preview: AddonInstallPreview) async throws -> InstalledAddon {
        load()
        let key = AddonURL.canonicalKey(preview.transportURL)
        let fingerprint = Hashing.sha256Hex(key)
        let local = preview.warnings.contains(.localNetwork)
        let timestamp = now()

        if let index = addons.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var updated = addons[index]
            updated.manifest = preview.manifest
            updated.updatedAt = timestamp
            updated.lastRefreshAt = timestamp
            updated.lastError = nil
            updated.isLocalNetwork = local
            updated.isOfficial = preview.isOfficial
            updated.needsReinstall = false
            do {
                try secrets.set(preview.transportURL.absoluteString, for: updated.secretKey)
            } catch {
                throw AddonError.unsupported("Impossibile salvare l'indirizzo dell'addon nel Portachiavi.")
            }
            urls[updated.id] = preview.transportURL
            addons[index] = updated
            persist()
            return updated
        }

        let addon = InstalledAddon(manifest: preview.manifest,
                                   host: AddonURL.displayHost(preview.transportURL),
                                   fingerprint: fingerprint, isEnabled: true,
                                   installedAt: timestamp, updatedAt: timestamp, lastRefreshAt: timestamp,
                                   isLocalNetwork: local, isOfficial: preview.isOfficial)
        do {
            try secrets.set(preview.transportURL.absoluteString, for: addon.secretKey)
        } catch {
            throw AddonError.unsupported("Impossibile salvare l'indirizzo dell'addon nel Portachiavi.")
        }
        urls[addon.id] = preview.transportURL
        addons.append(addon)
        persist()
        return addon
    }

    /// Convenience: preview + install.
    @discardableResult
    public func install(input: String) async throws -> InstalledAddon {
        let preview = try await self.preview(input: input)
        return try await install(preview)
    }

    // MARK: Mutations

    public func setEnabled(_ enabled: Bool, id: UUID) {
        load()
        guard let index = addons.firstIndex(where: { $0.id == id }) else { return }
        addons[index].isEnabled = enabled
        persist()
    }

    public func setNameOverride(_ name: String?, id: UUID) {
        load()
        guard let index = addons.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        addons[index].nameOverride = (trimmed?.isEmpty ?? true) ? nil : trimmed
        persist()
    }

    public func setCatalogVisible(_ visible: Bool, catalogKey: String, id: UUID) {
        load()
        guard let index = addons.firstIndex(where: { $0.id == id }) else { return }
        var hidden = addons[index].hiddenCatalogs
        hidden.removeAll(where: { $0 == catalogKey })
        if !visible { hidden.append(catalogKey) }
        addons[index].hiddenCatalogs = hidden
        persist()
    }

    /// Mirrors `List.onMove`: moves the elements at `source` so that they end up before `destination`.
    public func move(from source: IndexSet, to destination: Int) {
        load()
        var items = addons
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted().reversed() { items.remove(at: index) }
        let removedBefore = source.filter { $0 < destination }.count
        let target = max(0, min(items.count, destination - removedBefore))
        items.insert(contentsOf: moving, at: target)
        addons = items
        persist()
    }

    public func uninstall(id: UUID) {
        load()
        guard let index = addons.firstIndex(where: { $0.id == id }) else { return }
        let addon = addons.remove(at: index)
        try? secrets.remove(addon.secretKey)
        urls.removeValue(forKey: id)
        persist()
    }

    public func removeAll() {
        load()
        for addon in addons { try? secrets.remove(addon.secretKey) }
        addons = []
        urls = [:]
        persist()
    }

    // MARK: Refresh

    public struct RefreshOutcome: Sendable {
        public var id: UUID
        public var previousVersion: String
        public var newVersion: String?
        public var error: String?
        public var versionChanged: Bool { return newVersion != nil && newVersion != previousVersion }
    }

    /// Re-downloads the manifest. On success the manifest is replaced but every user preference is kept;
    /// on failure the old manifest stays and the error is recorded.
    @discardableResult
    public func refresh(id: UUID) async -> RefreshOutcome? {
        load()
        guard let addon = addons.first(where: { $0.id == id }), let url = urls[id] else { return nil }
        let previousVersion = addon.manifest.version
        do {
            let manifest = try await client.fetchManifest(url)
            // The user may have changed things while we were awaiting.
            guard let index = addons.firstIndex(where: { $0.id == id }) else { return nil }
            addons[index].manifest = manifest
            addons[index].lastRefreshAt = now()
            addons[index].updatedAt = now()
            addons[index].lastError = nil
            persist()
            return RefreshOutcome(id: id, previousVersion: previousVersion, newVersion: manifest.version, error: nil)
        } catch {
            if error is CancellationError { return nil }
            let message = (error as? AddonError)?.message ?? error.localizedDescription
            if let index = addons.firstIndex(where: { $0.id == id }) {
                addons[index].lastError = message
                addons[index].lastRefreshAt = now()
                persist()
            }
            return RefreshOutcome(id: id, previousVersion: previousVersion, newVersion: nil, error: message)
        }
    }

    public func refreshAll() async -> [RefreshOutcome] {
        load()
        let ids = addons.filter { !$0.needsReinstall }.map { $0.id }
        var outcomes: [RefreshOutcome] = []
        for id in ids {
            if Task.isCancelled { break }
            if let outcome = await refresh(id: id) { outcomes.append(outcome) }
        }
        return outcomes
    }

    /// Records the result of a live request so the UI can show connection state without re-fetching manifests.
    public func recordHealth(id: UUID, error: String?) {
        load()
        guard let index = addons.firstIndex(where: { $0.id == id }) else { return }
        if addons[index].lastError == error { return }
        addons[index].lastError = error
        persist()
    }

    // MARK: Backup support

    /// Replaces the registry content (used by restore). Secrets for `entries` are written to the store.
    public func restore(entries: [(addon: InstalledAddon, url: URL?)]) {
        load()
        for addon in addons { try? secrets.remove(addon.secretKey) }
        addons = []
        urls = [:]
        for entry in entries {
            var addon = entry.addon
            if let url = entry.url, (try? secrets.set(url.absoluteString, for: addon.secretKey)) != nil {
                urls[addon.id] = url
                addon.needsReinstall = false
            } else {
                addon.needsReinstall = true
                addon.isEnabled = false
            }
            addons.append(addon)
        }
        persist()
    }

    private func persist() {
        try? store.save(AddonRegistryState(schemaVersion: 1, addons: addons))
    }
}
