import SwiftUI
import AetherCore

/// TorBox in the app: the connection status shown in Settings, the cache check and the resolution of torrent streams into
/// playable links. It is a thin layer over the Core `TorBoxClient` / `DebridResolver`.
///
/// The API key never enters this class: the client reads it from the Keychain (`ServiceCredentials.provider`) at every call,
/// so removing the key takes effect at once and nothing here can log or publish it. The status carries the plan name and the
/// expiry date only; the account's e-mail address is not even decoded by the Core models.
@MainActor
final class DebridService: ObservableObject {
    struct AccountSummary: Equatable {
        var planName: String
        /// Subscription end, only when TorBox returned one for a paid plan.
        var expiresAt: Date?
        /// Short Italian remark from the provider's facts (free plan limits, expired subscription, cooldown).
        var notice: String?
    }

    enum ConnectionStatus: Equatable {
        /// No key saved.
        case notConfigured
        /// A key is saved but TorBox has not been asked about it in this session.
        case unverified
        case checking
        case connected(AccountSummary)
        /// The check failed; the text is Italian and never contains the key.
        case failed(String)
    }

    @Published private(set) var status: ConnectionStatus

    private let credentials: ServiceCredentials
    private let resolver: DebridResolver
    private let now: @Sendable () -> Date
    private var verifyGeneration = 0

    private struct PreparedLink {
        let resolution: DebridResolution
        let storedAt: Date
    }

    /// Links resolved by the stream picker, waiting for the player to pick them up (once). In memory only: a link carries a
    /// token, so it is never written to disk, a log or a backup.
    private var prepared: [String: PreparedLink] = [:]
    static let preparedLifetime: TimeInterval = 20 * 60

    init(credentials: ServiceCredentials,
         http: HTTPClient,
         baseURL: URL = TorBoxClient.productionBaseURL,
         retry: TorBoxClient.RetryPolicy = TorBoxClient.RetryPolicy.standard,
         clock: DebridClock = DebridClock.system,
         configuration: DebridResolver.Configuration = DebridResolver.Configuration(),
         log: DiagnosticLog? = nil) {
        let provider = credentials.provider(for: ServiceKind.torbox)
        let keyProvider: TorBoxClient.KeyProvider = { () throws -> String? in
            return provider()
        }
        let client = TorBoxClient(http: http, keyProvider: keyProvider, baseURL: baseURL, retry: retry, clock: clock, log: log)
        self.credentials = credentials
        self.resolver = DebridResolver(client: client, configuration: configuration, clock: clock, log: log)
        self.now = clock.now
        self.status = credentials.isConfigured(ServiceKind.torbox) ? ConnectionStatus.unverified : ConnectionStatus.notConfigured
    }

    /// UI tests start the app against the TorBox fixture server (`-AETHER_UITEST_TORBOX_URL`). The value is the server's address
    /// (`http://127.0.0.1:7778`); `/v1/api` is added unless it is already there. An address the client would not trust
    /// (anything but loopback / private network) gives nil, which means "use the real service".
    nonisolated static func fixtureAPIBase(from server: String) -> URL? {
        var text = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.isEmpty { return nil }
        if !text.hasSuffix("/v1/api") { text += "/v1/api" }
        guard let url = URL(string: text), TorBoxClient.isTrustedBaseURL(url) else { return nil }
        return url
    }

    /// A key is saved. It may still be wrong: only `status` says what TorBox answered.
    var isConfigured: Bool { return credentials.isConfigured(ServiceKind.torbox) }

    // MARK: Connection

    /// Asks TorBox about the saved key (`user/me`) and publishes the answer in `status`. Returns the failure when TorBox (or the
    /// network) said no, nil when the key was accepted or the check was superseded by a newer one.
    @discardableResult
    func verifyConnection() async -> DebridError? {
        guard isConfigured else {
            status = ConnectionStatus.notConfigured
            return nil
        }
        verifyGeneration += 1
        let generation = verifyGeneration
        status = ConnectionStatus.checking
        do {
            let account = try await resolver.validateCredentials()
            guard generation == verifyGeneration, isConfigured else { return nil }
            status = ConnectionStatus.connected(DebridService.summary(of: account))
            return nil
        } catch is CancellationError {
            if generation == verifyGeneration { status = ConnectionStatus.unverified }
            return nil
        } catch {
            guard generation == verifyGeneration else { return nil }
            if isConfigured {
                status = ConnectionStatus.failed(DebridErrorText.connectionMessage(forAny: error))
            } else {
                status = ConnectionStatus.notConfigured
            }
            return error as? DebridError
        }
    }

    /// Settings opens: a saved key that nobody has checked in this session is checked once.
    func verifyIfNeeded() async {
        guard isConfigured else { return }
        if case ConnectionStatus.unverified = status {
            await verifyConnection()
        }
    }

    nonisolated static func summary(of account: DebridAccount) -> AccountSummary {
        // An expiry on a free plan carries no information for the user, so it is not shown.
        let expiry: Date? = account.isFreePlan ? nil : account.premiumExpiresAt
        return AccountSummary(planName: account.planName, expiresAt: expiry, notice: account.notice)
    }

    /// Removes the key from the Keychain. Nothing is deleted from the user's TorBox account.
    func forget() {
        credentials.remove(ServiceKind.torbox)
        credentialsDidChange()
    }

    /// The key was saved, replaced or removed: what was learned about the old one no longer applies.
    func credentialsDidChange() {
        verifyGeneration += 1
        prepared.removeAll()
        let resolver = self.resolver
        Task { await resolver.clearAvailabilityCache() }
        status = isConfigured ? ConnectionStatus.unverified : ConnectionStatus.notConfigured
    }

    // MARK: Cache check and resolution

    /// `checkcached` for the hashes, in chunks of at most 100. Never throws: a failure leaves the hashes `.unknown` and is
    /// reported in the result.
    func availability(infoHashes: [String]) async -> DebridAvailabilityReport {
        let report = await resolver.availability(infoHashes: infoHashes)
        noteFailure(report.failure)
        return report
    }

    func resolve(_ request: DebridRequest,
                 onProgress: (@Sendable (DebridProgress) -> Void)?) async throws -> DebridResolution {
        do {
            return try await resolver.resolve(request, onProgress: onProgress)
        } catch let error as DebridError {
            noteFailure(error)
            throw error
        }
    }

    /// A refused key is a fact worth keeping in the status, whichever call found it out.
    private func noteFailure(_ error: DebridError?) {
        guard let error = error, error == DebridError.authFailed, isConfigured else { return }
        status = ConnectionStatus.failed(DebridErrorText.connectionMessage(for: error))
    }

    // MARK: Hand-off to the player

    private func preparedKey(for stream: AddonStream, stremioID: String?) -> String {
        return AddonStream.sourceKey(stream.source) + "|" + (stremioID ?? "")
    }

    /// The picker resolved a link and is about to open the player: the player takes it from here instead of asking again.
    func stashResolution(_ resolution: DebridResolution, for stream: AddonStream, stremioID: String?) {
        let current = now()
        let stale = prepared.filter { (entry: (key: String, value: PreparedLink)) -> Bool in
            return current.timeIntervalSince(entry.value.storedAt) >= DebridService.preparedLifetime
        }
        for key in stale.keys { prepared.removeValue(forKey: key) }
        prepared[preparedKey(for: stream, stremioID: stremioID)] = PreparedLink(resolution: resolution, storedAt: current)
    }

    /// Hands the stashed link out once; a second call (a retry after the link went bad) gets nothing and resolves afresh.
    func takePreparedResolution(for stream: AddonStream, stremioID: String?) -> DebridResolution? {
        guard let link = prepared.removeValue(forKey: preparedKey(for: stream, stremioID: stremioID)) else { return nil }
        guard now().timeIntervalSince(link.storedAt) < DebridService.preparedLifetime else { return nil }
        return link.resolution
    }

    var hasPreparedLinks: Bool { return !prepared.isEmpty }

    /// For the player: a direct-link stream for a torrent. Uses the link the picker already resolved, otherwise resolves now in
    /// `cachedOnly` mode, which never starts a download (that needs the user's confirmation in the picker).
    func playableStream(for stream: AddonStream, stremioID: String?,
                        onProgress: (@Sendable (DebridProgress) -> Void)?) async throws -> AddonStream {
        if let ready = takePreparedResolution(for: stream, stremioID: stremioID) {
            return ready.playableStream(from: stream)
        }
        guard let request = DebridRequest(stream: stream, stremioID: stremioID, mode: DebridMode.cachedOnly) else {
            throw DebridError.invalidInfoHash("")
        }
        let resolution = try await resolve(request, onProgress: onProgress)
        return resolution.playableStream(from: stream)
    }
}
