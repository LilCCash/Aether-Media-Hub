import Foundation

/// Real-Debrid implementation of the provider-neutral debrid contract.
/// Tokens are read from Keychain on each request and never included in diagnostics or error text.
public struct RealDebridClient: DebridProvider {
    public static let productionBaseURL = URL(string: "https://api.real-debrid.com/rest/1.0")!
    public typealias TokenProvider = @Sendable () -> String?

    private let http: HTTPClient
    private let tokenProvider: TokenProvider
    private let clock: DebridClock
    private let pollInterval: TimeInterval
    private let maxWait: TimeInterval

    public init(http: HTTPClient, tokenProvider: @escaping TokenProvider,
                clock: DebridClock = .system, pollInterval: TimeInterval = 3, maxWait: TimeInterval = 300) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.clock = clock
        self.pollInterval = max(3, pollInterval)
        self.maxWait = max(3, maxWait)
    }

    public var displayName: String { "Real-Debrid" }

    public func validateCredentials() async throws -> DebridAccount {
        let user = try await requestJSON(path: "/user", method: "GET")
        let premium = (user["type"] as? String)?.lowercased() == "premium"
        let expiry = (user["expiration"] as? String).flatMap { AddonDate.parse($0) }
        return DebridAccount(planName: premium ? "Premium" : ((user["type"] as? String) ?? "Free"),
                             planCode: nil, isFreePlan: !premium, premiumExpiresAt: expiry,
                             cooldownUntil: nil, notice: premium ? nil : "Real-Debrid richiede un account Premium per molte funzioni.")
    }

    public func availability(infoHashes: [String]) async -> DebridAvailabilityReport {
        var statuses: [String: DebridCacheStatus] = [:]
        for raw in infoHashes {
            guard let hash = DebridHash.normalize(raw) else {
                statuses[raw] = .unknown
                continue
            }
            do {
                let data = try await requestJSON(path: "/torrents/instantAvailability/\(hash)", method: "GET")
                // The API returns a hash-keyed object; any non-empty RD variant means a cached copy is available.
                let variants = data[hash] as? [String: Any]
                let rd = variants?["rd"] as? [Any] ?? []
                statuses[raw] = rd.contains { item in
                    guard let files = item as? [String: Any] else { return false }
                    return !files.isEmpty
                } ? .cached : .notCached
            } catch let error as DebridError {
                for missing in infoHashes where statuses[missing] == nil { statuses[missing] = .unknown }
                return DebridAvailabilityReport(statuses: statuses, failure: error)
            } catch {
                for missing in infoHashes where statuses[missing] == nil { statuses[missing] = .unknown }
                return DebridAvailabilityReport(statuses: statuses, failure: .network("Errore di rete verso Real-Debrid."))
            }
        }
        return DebridAvailabilityReport(statuses: statuses)
    }

    public func resolve(_ request: DebridRequest,
                        onProgress: (@Sendable (DebridProgress) -> Void)?) async throws -> DebridResolution {
        guard let hash = DebridHash.normalize(request.infoHash),
              let magnet = DebridMagnet.build(infoHash: request.infoHash, trackers: request.trackers) else {
            throw DebridError.invalidInfoHash(String(request.infoHash.prefix(64)))
        }
        try Task.checkCancellation()
        onProgress?(DebridProgress(phase: .checking))

        // Reuse an item already in the account when possible; never add a duplicate.
        var torrentID: String?
        var wasInAccount = false
        let list = try? await requestJSONArray(path: "/torrents", method: "GET")
        if let existing = list?.first(where: { (($0["hash"] as? String).map { DebridHash.normalize($0) } ?? nil) == hash }),
           let id = existing["id"] as? String {
            torrentID = id
            wasInAccount = true
        }

        if request.mode == .cachedOnly && !wasInAccount {
            let report = await availability(infoHashes: [hash])
            if report.status(for: hash) != .cached {
                if let failure = report.failure { throw failure }
                throw DebridError.notCached
            }
        }

        if torrentID == nil {
            onProgress?(DebridProgress(phase: .adding))
            let added = try await requestJSON(path: "/torrents/addMagnet", method: "POST",
                                              form: ["magnet": magnet])
            guard let id = added["id"] as? String, !id.isEmpty else {
                throw DebridError.invalidResponse("Real-Debrid non ha restituito l'identificativo del torrent.")
            }
            torrentID = id
            // Selecting files is an explicit API step. "all" lets the service prepare the complete torrent.
            _ = try await send(path: "/torrents/selectFiles/\(id)", method: "POST", form: ["files": "all"])
        }

        guard let id = torrentID else { throw DebridError.invalidResponse("Torrent senza identificativo.") }
        let deadline = clock.now().addingTimeInterval(request.mode == .cachedOnly ? 60 : maxWait)
        var info: [String: Any] = [:]
        while clock.now() < deadline {
            try Task.checkCancellation()
            info = try await requestJSON(path: "/torrents/info/\(id)", method: "GET")
            let status = (info["status"] as? String) ?? "unknown"
            onProgress?(DebridProgress(phase: .downloading,
                                       fraction: (info["progress"] as? NSNumber).map { $0.doubleValue / 100 },
                                       state: status))
            if status == "downloaded" { break }
            if status == "waiting_files_selection" {
                _ = try await send(path: "/torrents/selectFiles/\(id)", method: "POST", form: ["files": "all"])
                continue
            }
            if ["error", "virus", "dead", "magnet_error", "magnet_conversion"].contains(status) {
                throw DebridError.itemFailed(state: status)
            }
            if request.mode == .cachedOnly && !wasInAccount {
                // The torrent was reported cached but isn't ready yet; do not wait indefinitely in instant mode.
            }
            try await clock.sleep(pollInterval)
        }
        guard (info["status"] as? String) == "downloaded" else {
            throw DebridError.downloadNotReady(DebridProgress(phase: .downloading,
                fraction: (info["progress"] as? NSNumber).map { $0.doubleValue / 100 },
                state: info["status"] as? String))
        }

        let rawFiles = info["files"] as? [[String: Any]] ?? []
        let files: [TorBoxFile] = rawFiles.compactMap { file in
            guard let id = (file["id"] as? NSNumber)?.intValue,
                  let path = file["path"] as? String else { return nil }
            let bytes = (file["bytes"] as? NSNumber)?.int64Value
            return TorBoxFile(id: id, name: path, shortName: URL(fileURLWithPath: path).lastPathComponent,
                              size: bytes, mimetype: nil)
        }
        onProgress?(DebridProgress(phase: .selectingFile, fraction: 1))
        let query = TorBoxFileMatcher.query(for: request)
        let selected: TorBoxFile
        switch TorBoxFileMatcher.select(from: files, query: query) {
        case .selected(let file, _): selected = file
        case .noConfidentMatch(let candidates): throw DebridError.noMatchingFile(candidates: candidates)
        case .noVideo: throw DebridError.noVideoFile
        case .archivesOnly: throw DebridError.archivedFilesOnly
        case .infectedOnly: throw DebridError.infectedFiles
        }
        guard let fileID = selected.id else { throw DebridError.invalidResponse("File senza identificativo.") }
        let links = info["links"] as? [String] ?? []
        guard let linkIndex = rawFiles.firstIndex(where: { (($0["id"] as? NSNumber)?.intValue) == fileID }),
              links.indices.contains(linkIndex) else {
            throw DebridError.invalidResponse("Real-Debrid non ha restituito il link del file selezionato.")
        }
        onProgress?(DebridProgress(phase: .requestingLink, fraction: 1))
        let unrestricted = try await requestJSON(path: "/unrestrict/link", method: "POST", form: ["link": links[linkIndex]])
        guard let rawURL = unrestricted["download"] as? String, let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw DebridError.invalidResponse("Link di riproduzione Real-Debrid non valido.")
        }
        return DebridResolution(url: url, fileName: selected.displayName, fileSize: selected.size,
                                torrentID: Int(id) ?? 0, fileID: fileID, wasAlreadyInAccount: wasInAccount,
                                resolvedAt: clock.now())
    }

    private func requestJSONArray(path: String, method: String, form: [String: String]? = nil) async throws -> [[String: Any]] {
        let data = try await send(path: path, method: method, form: form)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DebridError.invalidResponse("Formato risposta Real-Debrid inatteso.")
        }
        return value
    }

    private func requestJSON(path: String, method: String, form: [String: String]? = nil) async throws -> [String: Any] {
        let data = try await send(path: path, method: method, form: form)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DebridError.invalidResponse("Formato risposta Real-Debrid inatteso.")
        }
        return value
    }

    private func send(path: String, method: String, form: [String: String]?) async throws -> Data {
        guard let token = tokenProvider()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw DebridError.notConfigured
        }
        var body: Data?
        var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if let form = form {
            let encoded = form.keys.sorted().map { "\(URIComponent.encode($0))=\(URIComponent.encode(form[$0] ?? ""))" }.joined(separator: "&")
            body = Data(encoded.utf8)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        }
        let relativePath = String(path.drop(while: { $0 == "/" }))
        guard let url = URL(string: relativePath, relativeTo: Self.productionBaseURL.appendingPathComponent(""))?.absoluteURL else {
            throw DebridError.invalidResponse("Endpoint Real-Debrid non valido.")
        }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, method: method, headers: headers, body: body,
                                                       timeout: 20, maxBytes: 8 * 1024 * 1024, purpose: .addonRequest))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DebridError.network("Errore di rete verso Real-Debrid.")
        }
        if response.statusCode == 401 || response.statusCode == 403 { throw DebridError.authFailed }
        if response.statusCode == 429 { throw DebridError.rateLimited(retryAfter: nil) }
        if response.statusCode == 503 || response.statusCode >= 500 {
            throw DebridError.serviceUnavailable(statusCode: response.statusCode)
        }
        guard response.isSuccess else {
            if response.statusCode == 404 { throw DebridError.itemNotFound }
            throw DebridError.api(code: "HTTP_\(response.statusCode)", detail: nil)
        }
        return response.data
    }
}
