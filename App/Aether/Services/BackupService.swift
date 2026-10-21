import Foundation
import AetherCore

enum RestoreMode {
    case merge
    case replace
}

struct RestoreSummary {
    var entries: Int
    var progressRecords: Int
    var addonsAdded: Int
    var addonsWithoutURL: Int
    var settingsApplied: Bool
}

/// Local backup / restore / export. Nothing leaves the device unless the user shares the file.
@MainActor
enum BackupService {
    static func makeBackup(env: AppEnvironment, includeAddonURLs: Bool, includeSettings: Bool = true) async throws -> URL {
        let library = await env.libraryStore.snapshot()
        var addonEntries: [BackupAddon] = []
        for addon in await env.registry.all() {
            var url: String?
            if includeAddonURLs, let transport = await env.registry.transportURL(for: addon.id) {
                url = transport.absoluteString
            }
            addonEntries.append(BackupAddon(addon: addon, url: url))
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let backup = AetherBackup(appVersion: version, library: library,
                                  settings: includeSettings ? env.settings.value : nil,
                                  addons: addonEntries, includesAddonURLs: includeAddonURLs)
        let data = try BackupCodec.encode(backup)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let name = "Aether-Backup-\(formatter.string(from: Date())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func restore(data: Data, env: AppEnvironment, mode: RestoreMode, applySettings: Bool) async throws -> RestoreSummary {
        let backup = try BackupCodec.decode(data)
        switch mode {
        case .merge: await env.libraryStore.merge(backup.library)
        case .replace: await env.libraryStore.replace(with: backup.library)
        }
        var added = 0
        var withoutURL = 0
        let pairs: [(addon: InstalledAddon, url: URL?)] = backup.addons.map { entry in
            (addon: entry.addon, url: entry.url.flatMap { URL(string: $0) })
        }
        withoutURL = pairs.filter { $0.url == nil }.count
        switch mode {
        case .merge:
            added = await env.registry.mergeRestore(entries: pairs)
        case .replace:
            await env.registry.restore(entries: pairs)
            added = pairs.count - withoutURL
        }
        await env.addons.reload()
        await env.library.refresh()
        var settingsApplied = false
        if applySettings, let settings = backup.settings {
            // The switch that hands the TV the account key is never restored from a file: it must be turned on again on this phone.
            var restored = settings
            restored.advanced.sendDirectLinkToTV = false
            env.settings.value = restored
            settingsApplied = true
        }
        return RestoreSummary(entries: backup.library.entries.count, progressRecords: backup.library.progress.count,
                              addonsAdded: added, addonsWithoutURL: withoutURL, settingsApplied: settingsApplied)
    }
}
