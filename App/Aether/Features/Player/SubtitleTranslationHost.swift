import SwiftUI
import Translation
import AetherCore

/// A hidden view that gives the player a `TranslationSession` (Apple's framework only hands one out to a view). The first time iOS can
/// ask to download the language; the translation then runs on the phone and nothing is sent to anyone.
@available(iOS 18.0, *)
struct SubtitleTranslationHost: View {
    @ObservedObject var model: PlayerViewModel
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: model.translationJob?.id) { _, id in
                guard id != nil, let job = model.translationJob else { return }
                let wanted = TranslationSession.Configuration(source: job.source, target: job.target)
                if configuration == wanted { configuration?.invalidate() } else { configuration = wanted }
            }
            .translationTask(configuration) { session in
                await run(session)
            }
    }

    @MainActor
    private func run(_ session: TranslationSession) async {
        guard let job = model.translationJob else { return }
        let total = job.batches.reduce(0) { $0 + $1.count }
        var results: [Int: String] = [:]
        var done = 0
        for batch in job.batches {
            let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.index)) }
            do {
                for response in try await session.translations(from: requests) {
                    if let identifier = response.clientIdentifier, let index = Int(identifier) { results[index] = response.targetText }
                }
            } catch {
                model.failTranslation(error.localizedDescription)
                return
            }
            done += batch.count
            model.translationProgress(done: done, total: total)
        }
        model.finishTranslation(job, results: results)
    }
}
