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
    private var resumeData: [UUID: Data] = [:]
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
    func enqueue(meta: MetaItem, video: Video?, stream: AddonStream, allowLocalNetwork: Bool) async -> String? {
        let info = StreamAnalyzer.analyze(stream)
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
                                    subtitle: subtitle, poster: meta.poster, sourceURL: url.absoluteString,
                                    headers: stream.behaviorHints.proxyRequestHeaders,
                                    totalBytes: stream.behaviorHints.videoSize ?? info.sizeBytes ?? 0)
            await store.add(item)
            items = await store.all()
            scheduleQueue()
            return nil
        }
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
        guard let url = URL(string: item.sourceURL) else {
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
            Task { @MainActor in await self.failedTransfer(id: id, message: "Il server ha risposto con errore HTTP \(status).") }
            return
        }
        if mime.contains("text/html") || mime.contains("json") || size < 50_000 {
            Task { @MainActor in await self.failedTransfer(id: id, message: "La sorgente non ha restituito un file video (tipo «\(mime.isEmpty ? "sconosciuto" : mime)»).") }
            return
        }
        // The temporary file disappears when this method returns: move it synchronously.
        let originalExtension = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? ""
        let known = ["mp4", "m4v", "mov", "mp3", "m4a", "aac"]
        let ext = known.contains(originalExtension) ? originalExtension : (mime.contains("quicktime") ? "mov" : "mp4")
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
