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
}
