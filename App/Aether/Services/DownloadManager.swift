import SwiftUI
import UIKit
import AetherCore

/// Background file downloads (URLSession background configuration) with queue, pause/resume, progress,
/// free-space guard and offline playback paths. Only plain http(s) files are accepted (see `DownloadPlanner`).
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    @Published var lastError: String?

    private let paths: AppPaths
    /// Immutable copy readable from the (nonisolated) URLSession delegate callbacks.
    nonisolated let downloadsDirectory: URL
    private let snapshot: SettingsSnapshot
    private let store: DownloadStore
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    /// TorBox CDN URLs contain short-lived credentials; keep them in memory only, never in DownloadStore.
    private var ephemeralURLs: [UUID: URL] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var transientHTTPRetries: [UUID: Int] = [:]
    private var lastPublished: [UUID: Date] = [:]
    nonisolated(unsafe) static var backgroundCompletionHandler: (() -> Void)?

    init(paths: AppPaths, snapshot: SettingsSnapshot) {
        self.paths = paths
        self.downloadsDirectory = paths.downloadsDirectory
        self.snapshot = snapshot
        self.store = DownloadStore(store: JSONFileStore<DownloadStoreState>(url: paths.downloadsFile))
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: "app.aether.downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: Lifecycle

    func restore() async {
        items = await store.all()
        // Re-attach to transfers the system kept running while the app was gone.
        let running = await session.allTasks
        for task in running {
            if let download = task as? URLSessionDownloadTask,
               let description = download.taskDescription, let id = UUID(uuidString: description) {
                tasks[id] = download
            }
        }
        // Items marked as downloading without a live task (crash, force quit): put them back in the queue.
        for item in items where item.state == .downloading && tasks[item.id] == nil {
            await store.update(id: item.id) { $0.state = .queued }
        }
        items = await store.all()
        scheduleQueue()
    }

    func settingsDidChange() {
        scheduleQueue()
    }

    // MARK: Public API

    var totalBytes: Int64 { items.filter { $0.state == .completed }.reduce(0) { $0 + $1.totalBytes } }

    func item(metaID: String, videoID: String?) -> DownloadItem? {
        return items.first(where: { $0.metaID == metaID && $0.videoID == videoID })
    }

    func localURL(for item: DownloadItem) -> URL? {
        guard item.state == .completed, let name = item.localFileName else { return nil }
        let url = paths.downloadsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Queues a download after checking eligibility; returns an error message when refused.
    @discardableResult
    func enqueue(meta: MetaItem, video: Video?, stream: AddonStream, allowLocalNetwork: Bool,
                 ephemeralURL: URL? = nil) async -> String? {
        let info = StreamAnalyzer.analyze(stream, capabilities: PlaybackEngineFactory.capabilities)
        switch DownloadPlanner.evaluate(stream: stream, info: info, allowLocalNetwork: allowLocalNetwork) {
        case .notAllowed(let reason):
            return reason
        case .allowed(let url):
            if await store.existing(metaID: meta.id, videoID: video?.id) != nil {
                return "Questo contenuto è già nei download."
            }
            let free = AppPaths.availableCapacity()
            if free > 0 && free < 300 * 1_048_576 {
                return "Spazio insufficiente: servono almeno 300 MB liberi."
            }
            var subtitle: String?
            if let video = video { subtitle = [video.episodeLabel, video.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
            let item = DownloadItem(metaID: meta.id, videoID: video?.id, type: meta.type, title: meta.name,
                                    subtitle: subtitle, poster: meta.poster,
                                    sourceURL: ephemeralURL == nil
                                        ? DownloadManager.sourceURLString(url, container: info.container)
                                        : "aether-torbox-pending://\(UUID().uuidString)",
                                    headers: stream.behaviorHints.proxyRequestHeaders,
                                    totalBytes: stream.behaviorHints.videoSize ?? info.sizeBytes ?? 0)
            if let ephemeralURL = ephemeralURL { ephemeralURLs[item.id] = ephemeralURL }
            await store.add(item)
            items = await store.all()
            scheduleQueue()
            return nil
        }
    }

    // MARK: File names

    /// Containers a downloaded file may keep. The extension decides which engine opens the file offline, so a
    /// Matroska download must stay `.mkv` (AVPlayer cannot open it, MPV can).
    nonisolated static let keptExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "mkv", "avi", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg"]

    /// The URL to remember for a download. When its path has no recognisable extension (debrid links often do not) the
    /// container derived from the stream's hints is appended as a fragment, which is never sent to the server.
    nonisolated static func sourceURLString(_ url: URL, container: String?) -> String {
        let current = url.pathExtension.lowercased()
        guard !keptExtensions.contains(current), let container = container?.lowercased(), keptExtensions.contains(container) else {
            return url.absoluteString
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = "aether-container=\(container)"
        return components?.string ?? url.absoluteString
    }

    nonisolated static func fileExtension(forURL url: URL?, mime: String) -> String {
        let fromPath = url?.pathExtension.lowercased() ?? ""
        if keptExtensions.contains(fromPath) { return fromPath }
        if let fragment = url?.fragment, fragment.hasPrefix("aether-container=") {
            let hinted = String(fragment.dropFirst("aether-container=".count)).lowercased()
            if keptExtensions.contains(hinted) { return hinted }
        }
        let type = mime.lowercased()
        if type.contains("matroska") { return "mkv" }
        if type.contains("webm") { return "webm" }
        if type.contains("msvideo") || type.contains("avi") { return "avi" }
        if type.contains("mp2t") { return "ts" }
        if type.contains("quicktime") { return "mov" }
        return "mp4"
    }

    func pause(_ id: UUID) {
        guard let task = tasks[id] else {
            Task { await mark(id, state: .paused) }
            return
        }
        task.cancel { [weak self] data in
            Task { @MainActor in
                if let data = data { self?.resumeData[id] = data }
                self?.tasks.removeValue(forKey: id)
                await self?.mark(id, state: .paused)
                self?.scheduleQueue()
            }
        }
    }

    func resume(_ id: UUID) {
        Task {
            await mark(id, state: .queued)
            scheduleQueue()
        }
    }

    func retry(_ id: UUID) {
        resumeData.removeValue(forKey: id)
        Task {
            await store.update(id: id) { $0.state = .queued; $0.errorMessage = nil; $0.bytesWritten = 0 }
            items = await store.all()
            scheduleQueue()
        }
    }

    func remove(_ id: UUID) {
        tasks[id]?.cancel()
        tasks.removeValue(forKey: id)
        ephemeralURLs.removeValue(forKey: id)
        resumeData.removeValue(forKey: id)
        Task {
            if let removed = await store.remove(id: id), let name = removed.localFileName {
                try? FileManager.default.removeItem(at: paths.downloadsDirectory.appendingPathComponent(name))
            }
            items = await store.all()
            scheduleQueue()
        }
    }

    func removeAll() async {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        resumeData = [:]
        await store.removeAll()
        if let files = try? FileManager.default.contentsOfDirectory(at: paths.downloadsDirectory, includingPropertiesForKeys: nil) {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
        items = []
    }

    /// Called by the player when a downloaded title has been watched to the end (setting: delete after watching).
    func deleteIfWatched(metaID: String, videoID: String?) {
        guard snapshot.get().storage.deleteDownloadsAfterWatching,
              let item = item(metaID: metaID, videoID: videoID), item.state == .completed else { return }
        remove(item.id)
    }

    // MARK: Queue

    private func scheduleQueue() {
        Task {
            let limit = snapshot.get().storage.maxConcurrentDownloads
            var active = tasks.count
            for item in await store.all() where item.state == .queued {
                if active >= limit { break }
                if startTask(for: item) { active += 1 }
            }
            items = await store.all()
        }
    }

    private func startTask(for item: DownloadItem) -> Bool {
        guard tasks[item.id] == nil else { return false }
        let url: URL
        if let ephemeral = ephemeralURLs[item.id] {
            url = ephemeral
        } else if item.sourceURL.hasPrefix("aether-torbox-pending://") {
            Task { await fail(item.id, message: "Il link temporaneo TorBox è scaduto. Avvia di nuovo il download dalla sorgente.") }
            return false
        } else if let storedURL = URL(string: item.sourceURL) {
            url = storedURL
        } else {
            Task { await fail(item.id, message: "URL non valido.") }
            return false
        }
        let allowCellular = snapshot.get().storage.downloadOverCellular
        let task: URLSessionDownloadTask
        if let data = resumeData[item.id] {
            task = session.downloadTask(withResumeData: data)
            resumeData.removeValue(forKey: item.id)
        } else {
            var request = URLRequest(url: url)
            request.allowsCellularAccess = allowCellular
            request.allowsConstrainedNetworkAccess = allowCellular
            request.allowsExpensiveNetworkAccess = allowCellular
            request.setValue("Aether/1.0", forHTTPHeaderField: "User-Agent")
            for (name, value) in item.headers { request.setValue(value, forHTTPHeaderField: name) }
            task = session.downloadTask(with: request)
        }
        task.taskDescription = item.id.uuidString
        tasks[item.id] = task
        task.resume()
        Task {
            await store.update(id: item.id) { $0.state = .downloading; $0.errorMessage = nil }
            items = await store.all()
        }
        return true
    }

    private func mark(_ id: UUID, state: DownloadState) async {
        await store.update(id: id) { $0.state = state }
        items = await store.all()
    }

    private func fail(_ id: UUID, message: String) async {
        tasks.removeValue(forKey: id)
        transientHTTPRetries.removeValue(forKey: id)
        await store.update(id: id) { $0.state = .failed; $0.errorMessage = message }
        items = await store.all()
        scheduleQueue()
    }

    fileprivate func progressUpdate(id: UUID, written: Int64, total: Int64) async {
        // Throttle UI/disk updates to twice a second.
        let now = Date()
        if let last = lastPublished[id], now.timeIntervalSince(last) < 0.5 { return }
        lastPublished[id] = now
        await store.update(id: id) {
            $0.bytesWritten = written
            if total > 0 { $0.totalBytes = total }
            $0.state = .downloading
        }
        items = await store.all()
        let free = AppPaths.availableCapacity()
        if total > 0, free > 0, total - written > free - 100 * 1_048_576 {
            tasks[id]?.cancel()
            await fail(id, message: "Spazio insufficiente sul dispositivo.")
        }
    }

    fileprivate func finished(id: UUID, fileName: String, bytes: Int64) async {
        tasks.removeValue(forKey: id)
        ephemeralURLs.removeValue(forKey: id)
        transientHTTPRetries.removeValue(forKey: id)
        await store.update(id: id) {
            $0.state = .completed
            $0.localFileName = fileName
            $0.bytesWritten = bytes
            $0.totalBytes = bytes
            $0.completedAt = Date()
            $0.errorMessage = nil
        }
        items = await store.all()
        scheduleQueue()
    }

    /// CDN/provider 5xx responses are often transient. Retry twice before surfacing the error,
    /// keeping ephemeral provider URLs in memory and never persisting their credentials.
    fileprivate func retryTransientHTTPFailure(id: UUID, status: Int) async {
        guard (500..<600).contains(status) else {
            await fail(id, message: "Il server ha risposto con errore HTTP \(status).")
            return
        }
        let attempts = transientHTTPRetries[id, default: 0]
        guard attempts < 2, let item = await store.item(id: id) else {
            await fail(id, message: "Il server ha risposto con errore HTTP \(status) dopo \(attempts) tentativi.")
            return
        }
        transientHTTPRetries[id] = attempts + 1
        tasks.removeValue(forKey: id)
        await store.update(id: id) {
            $0.state = .queued
            $0.bytesWritten = 0
            $0.errorMessage = "Server temporaneamente non disponibile (HTTP \(status): nuovo tentativo \(attempts + 1)/2…"
        }
        items = await store.all()
        let delay = UInt64(attempts + 1) * 2_000_000_000
        try? await Task.sleep(nanoseconds: delay)
        guard !Task.isCancelled,
              let current = await store.item(id: id), current.state == .queued else { return }
        _ = startTask(for: item)
        items = await store.all()
    }

    fileprivate func failedTransfer(id: UUID, message: String) async {
        await fail(id, message: message)
    }
}

extension DownloadManager: URLSessionDownloadDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = downloadTask.taskDescription, let id = UUID(uuidString: description) else { return }
        Task { @MainActor in await self.progressUpdate(id: id, written: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription, let id = UUID(uuidString: description) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        let mime = (response?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0

        guard (200..<300).contains(status) else {
            Task { @MainActor in
                await self.retryTransientHTTPFailure(id: id, status: status)
            }
            return
        }
        if mime.contains("text/html") || mime.contains("json") || size < 50_000 {
            Task { @MainActor in await self.failedTransfer(id: id, message: "La sorgente non ha restituito un file video (tipo «\(mime.isEmpty ? "sconosciuto" : mime)»).") }
            return
        }
        // The temporary file disappears when this method returns: move it synchronously.
        let ext = DownloadManager.fileExtension(forURL: downloadTask.originalRequest?.url, mime: mime)
        let fileName = "\(id.uuidString).\(ext)"
        let destinationDirectory = self.downloadsDirectory
        let destination = destinationDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in await self.failedTransfer(id: id, message: "Impossibile salvare il file: \(error.localizedDescription)") }
            return
        }
        Task { @MainActor in await self.finished(id: id, fileName: fileName, bytes: size) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let description = task.taskDescription, let id = UUID(uuidString: description) else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }   // pause / remove
        let message: String
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: message = "Nessuna connessione (o dati mobili disattivati per i download)."
        case NSURLErrorTimedOut: message = "Il server non risponde."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection: message = "iOS blocca i download HTTP non cifrati verso Internet."
        default: message = "Download interrotto: \(error.localizedDescription)"
        }
        Task { @MainActor in
            if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data { self.resumeData[id] = data }
            await self.failedTransfer(id: id, message: message)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            DownloadManager.backgroundCompletionHandler?()
            DownloadManager.backgroundCompletionHandler = nil
        }
    }
}
