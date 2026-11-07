import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AetherCore

/// Sync between devices through a folder the viewer chooses (iCloud Drive, Dropbox, any provider of the Files app): Aether keeps one
/// file in it, merges what another device wrote and writes its own state back. No server, no developer account needed; the file is
/// readable JSON and holds the library, the history and the viewer's own settings, so the screen says to choose a folder only they can reach.
@MainActor
final class FolderSyncService: ObservableObject {
    static let shared = FolderSyncService()
    static let fileName = "Aether-Sync.json"

    @Published private(set) var folderName: String?
    @Published private(set) var status: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?

    private let defaults = UserDefaults.standard
    private let bookmarkKey = "aether.sync.bookmark"
    private let lastKey = "aether.sync.last"
    private var folder: URL?

    private init() {
        lastSync = defaults.object(forKey: lastKey) as? Date
        resolve()
    }

    var isEnabled: Bool { return folderName != nil }

    private func resolve() {
        guard let data = defaults.data(forKey: bookmarkKey) else { folderName = nil; folder = nil; return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            folder = url
            folderName = url.lastPathComponent
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { defaults.set(fresh, forKey: bookmarkKey) }
        } else {
            folder = nil
            folderName = nil
            status = "La cartella scelta non è più raggiungibile: sceglila di nuovo."
        }
    }

    func choose(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: bookmarkKey)
            status = nil
            resolve()
        } catch {
            status = "Non riesco a ricordare la cartella: \(error.localizedDescription)"
        }
    }

    func stop() {
        defaults.removeObject(forKey: bookmarkKey)
        folder = nil
        folderName = nil
        status = "Sincronizzazione disattivata. Il file nella cartella non è stato cancellato."
    }

    /// A quiet sync at most every few minutes (when the app opens or goes to the background).
    func syncIfDue(env: AppEnvironment, minimumInterval: TimeInterval = 180) async {
        guard isEnabled, !isSyncing else { return }
        if let last = lastSync, Date().timeIntervalSince(last) < minimumInterval { return }
        await sync(env: env)
    }

    func sync(env: AppEnvironment) async {
        guard let folder = folder, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(Self.fileName)
        var merged = 0
        do {
            if let data = Self.read(file) {
                let remote = try BackupCodec.decode(data)
                await env.libraryStore.merge(remote.library)
                if let settings = remote.settings {
                    env.settings.value.content = ContentSync.merge(local: env.settings.value.content, remote: settings.content)
                }
                await env.library.refresh()
                merged = remote.library.entries.count
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            let backup = AetherBackup(appVersion: version, library: await env.libraryStore.snapshot(), settings: env.settings.value, addons: [], includesAddonURLs: false)
            try Self.write(try BackupCodec.encode(backup), to: file)
            lastSync = Date()
            defaults.set(lastSync, forKey: lastKey)
            status = merged > 0 ? "Sincronizzato: unito il file della cartella (\(merged) titoli) e riscritto." : "Sincronizzato: file creato nella cartella."
        } catch {
            status = "Sincronizzazione non riuscita: \(error.localizedDescription)"
        }
    }

    private static func read(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { readable in
            result = try? Data(contentsOf: readable)
        }
        return result
    }

    private static func write(_ data: Data, to url: URL) throws {
        var failure: Error?
        var coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { writable in
            do { try data.write(to: writable, options: .atomic) } catch { failure = error }
        }
        if let coordination = coordination { throw coordination }
        if let failure = failure { throw failure }
    }
}

struct SyncSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var sync = FolderSyncService.shared
    @State private var picking = false

    var body: some View {
        Form {
            Section(footer: Text("Aether tiene un solo file («\(FolderSyncService.fileName)») nella cartella che scegli. Un altro telefono o iPad con la stessa cartella lo legge e lo unisce al suo: libreria, cronologia, diario, collezioni, voti dei gusti e universi seguiti. Il file contiene anche le tue impostazioni, comprese le playlist di Live TV: scegli una cartella che solo tu puoi aprire. Non c'è un server e non serve un account sviluppatore.")) {
                if let name = sync.folderName {
                    LabeledContent("Cartella", value: name)
                    if let last = sync.lastSync { LabeledContent("Ultima volta", value: last.formatted(date: .abbreviated, time: .shortened)) }
                    Button { Task { await sync.sync(env: env) } } label: {
                        HStack { Text("Sincronizza adesso"); Spacer(); if sync.isSyncing { ProgressView() } }
                    }
                    .disabled(sync.isSyncing)
                    Button("Cambia cartella") { picking = true }
                    Button("Disattiva", role: .destructive) { sync.stop() }
                } else {
                    Button { picking = true } label: { Label("Scegli la cartella (iCloud Drive o altra)", systemImage: "folder.badge.plus") }
                }
            }
            if let status = sync.status { Section { Text(status).font(.footnote).foregroundStyle(Color.aetherSecondary) } }
        }
        .navigationTitle("Sincronizzazione")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.choose(url); Task { await sync.sync(env: env) } }
        }
    }
}
