import SwiftUI
import AetherCore

/// Main-actor, observable face of `AddonRegistry` for SwiftUI.
@MainActor
final class AddonStore: ObservableObject {
    @Published private(set) var addons: [InstalledAddon] = []
    /// Bumps whenever something that changes what Home/Discover show has changed (addons, cache settings, …).
    @Published private(set) var revision = 0
    @Published private(set) var isRefreshing = false

    private let registry: AddonRegistry

    init(registry: AddonRegistry) {
        self.registry = registry
    }

    var enabledAddons: [InstalledAddon] { addons.filter { $0.isEnabled && !$0.needsReinstall } }

    func bumpRevision() {
        revision += 1
    }

    func reload() async {
        addons = await registry.all()
        revision += 1
    }

    func handles() async -> [AddonHandle] {
        return await registry.handles()
    }

    func preview(_ input: String) async throws -> AddonInstallPreview {
        return try await registry.preview(input: input)
    }

    @discardableResult
    func install(_ preview: AddonInstallPreview) async throws -> InstalledAddon {
        let addon = try await registry.install(preview)
        await reload()
        return addon
    }

    func setEnabled(_ enabled: Bool, id: UUID) async {
        await registry.setEnabled(enabled, id: id)
        await reload()
    }

    func setCatalogVisible(_ visible: Bool, catalogKey: String, id: UUID) async {
        await registry.setCatalogVisible(visible, catalogKey: catalogKey, id: id)
        await reload()
    }

    func rename(_ name: String?, id: UUID) async {
        await registry.setNameOverride(name, id: id)
        await reload()
    }

    func move(from source: IndexSet, to destination: Int) async {
        // Optimistic local update keeps the drag smooth; the registry is the source of truth afterwards.
        var copy = addons
        copy.move(fromOffsets: source, toOffset: destination)
        addons = copy
        await registry.move(from: source, to: destination)
        await reload()
    }

    func uninstall(id: UUID) async {
        await registry.uninstall(id: id)
        await reload()
    }

    func refresh(id: UUID) async -> AddonRegistry.RefreshOutcome? {
        let outcome = await registry.refresh(id: id)
        await reload()
        return outcome
    }

    func refreshAll() async -> [AddonRegistry.RefreshOutcome] {
        isRefreshing = true
        defer { isRefreshing = false }
        let outcomes = await registry.refreshAll()
        await reload()
        return outcomes
    }

    /// Needed to open an addon's `/configure` page; the URL contains the user's secret, never log it.
    func transportURL(for id: UUID) async -> URL? {
        return await registry.transportURL(for: id)
    }
}
