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
    /// The services whose keys came back with the backup (by name).
    var keysRestored: [String] = []
}

/// Why a backup file could not be read, in words for the viewer.
enum BackupFileError: Error, Equatable {
    case tooLarge
    case unreadable(String)

    var message: String {
        switch self {
        case .tooLarge: return "Il file è troppo grande per essere un backup di Aether."
        case .unreadable(let reason): return "Non riesco ad aprire il file: \(reason)"
        }
    }
}

/// Reads the file the viewer picked. A file chosen in the Files app (or in a folder of another app, or in iCloud Drive) is outside
/// the app's sandbox: access has to be asked for, the read goes through a file coordinator (which also waits for an iCloud file to be
/// downloaded), and the reason of a failure is kept so it can be shown.
enum BackupFileReader {
    /// A backup is a few hundred KB; nothing that is not a backup should be pulled into memory whole.
    static let maximumBytes = 64 << 20

    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var outcome: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            outcome = Result { try load(readable) }
        }
        if let outcome = outcome { return try unwrap(outcome) }
        if coordinationError != nil {
            // The coordinator refused (some containers do not support it): try the plain read once.
            return try unwrap(Result { try load(url) })
        }
        return try unwrap(Result { try load(url) })
    }

    private static func load(_ url: URL) throws -> Data {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maximumBytes { throw BackupFileError.tooLarge }
        return try Data(contentsOf: url)
    }

    private static func unwrap(_ result: Result<Data, Error>) throws -> Data {
        switch result {
        case .success(let data):
            if data.count > maximumBytes { throw BackupFileError.tooLarge }
            return data
        case .failure(let error):
            if let known = error as? BackupFileError { throw known }
            throw BackupFileError.unreadable((error as NSError).localizedDescription)
        }
    }
}

/// What a picked backup holds, said before anything is restored.
struct BackupPreview: Equatable {
    var entries: Int
    var progressRecords: Int
    var addons: Int
    var addonsWithURL: Int
    var hasSettings: Bool
    var serviceKeys: Int
    var appVersion: String
    var createdAt: Date

    init(_ backup: AetherBackup) {
        entries = backup.library.entries.values.filter { !$0.isRemoved }.count
        progressRecords = backup.library.progress.count
        addons = backup.addons.count
        addonsWithURL = backup.addons.filter { $0.url != nil }.count
        hasSettings = backup.settings != nil
        serviceKeys = backup.serviceKeys?.count ?? 0
        appVersion = backup.appVersion
        createdAt = backup.createdAt
    }

    var summary: String {
        var parts = ["\(entries) titoli salvati", "\(progressRecords) punti di visione", "\(addons) addon"]
        if addons > 0 && addonsWithURL < addons { parts[2] += " (\(addons - addonsWithURL) senza indirizzo: da reinstallare)" }
        parts.append(hasSettings ? "impostazioni incluse" : "senza impostazioni")
        if serviceKeys > 0 { parts.append("chiavi dei servizi incluse") }
        return parts.joined(separator: " · ")
    }
}

/// Local backup / restore / export. Nothing leaves the device unless the user shares the file.
@MainActor
enum BackupService {
    static func makeBackup(env: AppEnvironment, includeAddonURLs: Bool, includeSettings: Bool = true, includeServiceKeys: Bool = false) async throws -> URL {
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
                                  addons: addonEntries, includesAddonURLs: includeAddonURLs,
                                  serviceKeys: includeServiceKeys ? serviceKeys(env: env) : nil)
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
        var keysRestored: [String] = []
        if let keys = backup.serviceKeys {
            let services: [(String, ServiceKind)] = [("torbox", .torbox), ("tmdb", .tmdb), ("tvdb", .tvdb), ("fanart", .fanart)]
            for (name, kind) in services {
                guard let secret = keys[name], !secret.isEmpty else { continue }
                do {
                    try env.credentials.save(secret, for: kind, pin: kind == .tvdb ? keys["tvdbPin"] : nil)
                    keysRestored.append(kind.title)
                } catch {
                    continue
                }
            }
        }
        return RestoreSummary(entries: backup.library.entries.count, progressRecords: backup.library.progress.count,
                              addonsAdded: added, addonsWithoutURL: withoutURL, settingsApplied: settingsApplied,
                              keysRestored: keysRestored)
    }

    /// The keys the viewer chose to carry in a backup (plain text in the file: the screen says so).
    private static func serviceKeys(env: AppEnvironment) -> [String: String]? {
        var keys: [String: String] = [:]
        let services: [(String, ServiceKind)] = [("torbox", .torbox), ("tmdb", .tmdb), ("tvdb", .tvdb), ("fanart", .fanart)]
        for (name, kind) in services {
            if let secret = env.credentials.secret(for: kind) { keys[name] = secret }
        }
        if let pin = env.credentials.pin(for: .tvdb) { keys["tvdbPin"] = pin }
        return keys.isEmpty ? nil : keys
    }
}
