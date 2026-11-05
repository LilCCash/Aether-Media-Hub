import ActivityKit
import Foundation
import AetherCore

/// The progress of the downloads on the Lock Screen and in the Dynamic Island. An activity only changes while the app runs: with the app
/// closed, iOS finishes the downloads and the activity moves when the system wakes the app (or on the next opening).
@MainActor
final class DownloadActivityService {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: DownloadActivityAttributes.ContentState?

    func sync(_ items: [DownloadItem], enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled, let summary = DownloadActivityPlanner.summary(items) else {
            finish()
            return
        }
        let state = DownloadActivityAttributes.ContentState(title: summary.title, subtitle: summary.subtitle, fraction: summary.fraction,
                                                            count: summary.count, finished: false)
        lastState = state
        if let current = activity {
            guard Date().timeIntervalSince(lastUpdate) > 2 else { return }
            lastUpdate = Date()
            Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            do {
                activity = try Activity.request(attributes: DownloadActivityAttributes(name: "Download"),
                                                content: ActivityContent(state: state, staleDate: nil), pushType: nil)
                lastUpdate = Date()
            } catch {
                activity = nil
            }
        }
    }

    /// No download is running: the activity says it is done for a moment, then goes away.
    private func finish() {
        guard let current = activity else { return }
        activity = nil
        var state = lastState ?? DownloadActivityAttributes.ContentState(title: "Download", subtitle: nil, fraction: 1, count: 1, finished: true)
        state.finished = true
        state.fraction = 1
        lastState = nil
        Task { await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }
}
