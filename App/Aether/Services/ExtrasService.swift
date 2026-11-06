import SwiftUI
import UserNotifications
import AetherCore

/// The optional features of the November 2026 build that live outside a screen: the check for a newer build, the notes of the build
/// and the notifications of new episodes. Every one is switched on or off in Settings ▸ Funzioni extra.
@MainActor
final class ExtrasService: ObservableObject {
    @Published private(set) var available: DevbuildRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var checkMessage: String?
    @Published var showingWhatsNew = false

    private let settings: SettingsStore
    private let trakt: TraktService
    private let diagnostics: DiagnosticLog
    private let defaults: UserDefaults
    private static let lastCheckKey = "aether.extras.lastUpdateCheck"
    private static let alertPrefix = "aether.ep."
    private static let invitePrefix = "aether.invite."
    private static let lastInviteKey = "aether.extras.lastInvites"
    weak var environment: AppEnvironment?
    weak var addonStore: AddonStore?

    init(settings: SettingsStore, trakt: TraktService, diagnostics: DiagnosticLog, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.trakt = trakt
        self.diagnostics = diagnostics
        self.defaults = defaults
    }

    var options: ExtrasSettings { return settings.value.advanced.extras }

    var installedBuild: Int {
        return Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    // MARK: Launch

    /// Called when the app becomes active: a quiet check (at most every six hours), the notes after an update, the notifications.
    func appBecameActive() {
        if options.checkUpdates { Task { await checkForUpdate(force: false) } }
        presentWhatsNewIfNeeded()
        Task { await refreshEpisodeAlerts() }
        Task { await refreshInvites(force: false) }
    }

    // MARK: Updates

    func checkForUpdate(force: Bool) async {
        if !force {
            guard options.checkUpdates else { return }
            if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 6 * 3600 { return }
        }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        var request = URLRequest(url: DevbuildFeed.sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("Aether", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                checkMessage = "Il controllo non è riuscito (risposta del server non valida)."
                return
            }
            defaults.set(Date(), forKey: Self.lastCheckKey)
            guard let latest = DevbuildFeed.latest(from: data) else {
                checkMessage = "Non riesco a leggere l'elenco delle build."
                return
            }
            if DevbuildFeed.isNewer(latest, than: installedBuild) {
                available = latest
                checkMessage = "È disponibile la build \(latest.build) (hai la \(installedBuild))."
            } else {
                available = nil
                checkMessage = "Hai l'ultima build (\(installedBuild))."
            }
        } catch {
            checkMessage = "Controllo non riuscito: \(error.localizedDescription)"
            diagnostics.logDetached(.warning, "updates", "Controllo aggiornamenti: \(error.localizedDescription)")
        }
    }

    // MARK: Notes of the build

    var whatsNewLines: [String] {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return DevbuildFeed.noteLines(text)
    }

    private func presentWhatsNewIfNeeded() {
        let build = installedBuild
        guard options.showWhatsNew, build > options.lastSeenBuild, !whatsNewLines.isEmpty else {
            if build > options.lastSeenBuild { markWhatsNewSeen() }
            return
        }
        showingWhatsNew = true
    }

    func markWhatsNewSeen() {
        settings.value.advanced.extras.lastSeenBuild = installedBuild
    }

    // MARK: New-episode notifications

    /// Plans a notification for each upcoming episode of the viewer's series (Trakt calendar, next 14 days) and schedules it on the
    /// phone: it arrives even if Aether is closed. Switched off: the pending ones are removed.
    func refreshEpisodeAlerts() async {
        let center = UNUserNotificationCenter.current()
        guard options.episodeNotifications, trakt.isActive else {
            await removePending(center)
            return
        }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else {
            checkMessage = "Le notifiche sono spente per Aether nelle impostazioni di iOS."
            return
        }
        guard let titles = try? await trakt.client.titles(for: .calendar, limit: 200) else { return }
        let alerts = EpisodeAlertPlanner.plan(titles, now: Date(), hour: options.episodeNotificationHour)
        await removePending(center)
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alert.fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: trigger))
        }
        diagnostics.logDetached(.info, "notifications", "Notifiche programmate per \(alerts.count) episodi")
    }

    private func removePending(_ center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map { $0.identifier }.filter { $0.hasPrefix(Self.alertPrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }

    // MARK: Invitations

    /// The «what shall we watch?» notifications for the next two weeks, with a title suggested from the favourite genres. At most every 12 hours.
    func refreshInvites(force: Bool) async {
        let center = UNUserNotificationCenter.current()
        let profile = settings.value.content.profile
        guard profile.inviteNotifications else {
            await removePendingInvites(center)
            return
        }
        if !force, let last = defaults.object(forKey: Self.lastInviteKey) as? Date, Date().timeIntervalSince(last) < 12 * 3600 { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        var suggestions: [InviteSuggestion] = []
        let genres = TasteEngine.topGenres(profile, limit: 3)
        if let env = environment, let addons = addonStore, !genres.isEmpty {
            let seen = Set(profile.votes.map { $0.id })
            let found = await TasteSource.fetch(env: env, addons: addons, genres: genres)
            let pool = TasteEngine.deck(found.shuffled(), profile: profile, excluding: seen)
            for item in pool.prefix(6) {
                let title = item.genres.lazy.compactMap { ProfileGenre.from(cinemeta: $0)?.title }.first ?? item.genres.first ?? "cinema"
                suggestions.append(InviteSuggestion(id: item.id, type: item.type, name: item.name, genre: title))
            }
        }
        let alerts = InvitePlanner.plan(now: Date(), name: profile.displayName, perWeek: profile.invitesPerWeek, suggestions: suggestions)
        await removePendingInvites(center)
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            if let type = alert.type, let id = alert.metaID { content.userInfo = ["type": type, "id": id] }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: alert.fire)
            try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        defaults.set(Date(), forKey: Self.lastInviteKey)
        diagnostics.logDetached(.info, "notifications", "Inviti programmati: \(alerts.count)")
    }

    private func removePendingInvites(_ center: UNUserNotificationCenter) async {
        let ids = await center.pendingNotificationRequests().map { $0.identifier }.filter { $0.hasPrefix(Self.invitePrefix) }
        if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
    }
}
