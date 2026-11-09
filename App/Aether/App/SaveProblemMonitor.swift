import SwiftUI
import AetherCore

/// What could not be written to the phone (the library, the addons, the downloads), from `PersistenceHealth`. Before 2.0 a failed
/// write was ignored and the change was lost without a word; now the change stays pending, is written again, and this tells the
/// viewer until it succeeds.
@MainActor
final class SaveProblemMonitor: ObservableObject {
    @Published private(set) var problems: [String: String] = [:]

    init(health: PersistenceHealth = .shared) {
        problems = health.current
        health.onChange { snapshot in
            Task { @MainActor [weak self] in self?.problems = snapshot }
        }
    }

    /// One sentence for the banner, nil when everything is saved.
    var message: String? {
        guard !problems.isEmpty else { return nil }
        let what = problems.keys.sorted()
        let names = what.count == 1 ? what[0] : what.dropLast().joined(separator: ", ") + " e " + (what.last ?? "")
        let reasons = Set(problems.values)
        let reason = reasons.count == 1 ? (reasons.first ?? "") : "errori di scrittura"
        return "Non riesco a salvare \(names) (\(reason)). Le modifiche non sono perse: riprovo da solo."
    }
}

/// A small banner at the top of the app while something cannot be saved.
struct SaveProblemBanner: View {
    @ObservedObject var monitor: SaveProblemMonitor

    var body: some View {
        if let message = monitor.message {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("app.saveProblem")
        }
    }
}
