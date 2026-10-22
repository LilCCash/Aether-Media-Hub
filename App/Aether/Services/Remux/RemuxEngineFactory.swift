import Foundation
import AetherCore

/// Makes the real converter when this build has FFmpeg in it. Tests hand the services a fake instead.
enum RemuxEngineFactory {
    typealias Maker = (RelayRangeFetcher, Int64, RemuxAudioChoice) -> RemuxEngine?

    /// Whether this build can convert Matroska at all.
    static var isAvailable: Bool { return FFmpegAvailability.isLinked }

    static let standard: Maker = { fetcher, totalBytes, audio in
        #if canImport(Libavformat) && canImport(Libavcodec) && canImport(Libavutil)
        return FFmpegRemuxEngine(fetcher: fetcher, totalBytes: totalBytes, audio: audio)
        #else
        return nil
        #endif
    }

    /// What the planner needs to know about the converter and the viewer's wish.
    static func routing(matroskaForAVPlayer: Bool) -> RemuxRouting {
        return RemuxRouting(available: isAvailable, matroskaForAVPlayer: matroskaForAVPlayer)
    }
}

/// Why a file could not be converted, in words for the viewer. Never carries an address.
@MainActor
enum RemuxFailureText {
    static func explain(_ error: Error) -> String {
        if let remux = error as? RemuxError { return remux.message }
        if let cast = error as? CastError, let text = cast.errorDescription { return text }
        if let local = error as? LocalRemuxError { return local.message }
        return RelayService.probeMessage(for: error)
    }

    /// The same, for a file that plays on this phone: nothing is being sent to a television, so a source that cannot be read in
    /// pieces is not "forwarded", it is not converted.
    static func explainLocal(_ error: Error) -> String {
        if error is RemuxError || error is LocalRemuxError || error is CastError { return explain(error) }
        switch RelayError.mapping(error) {
        case .upstreamNoRanges:
            return "Questa sorgente non permette di leggere il video a pezzi, quindi non si può convertire al volo."
        case .upstreamUnreachable:
            return explain(error)
        case .upstreamRejected(let status) where [401, 403, 404, 410].contains(status):
            return explain(error)
        default:
            return "La sorgente ha risposto in modo inatteso e non si può convertire."
        }
    }

    /// What is wrong, without the advice about the player's engine at the end of some explanations (useless where the file goes to a
    /// television, and contradicted by "I use MPV" where the engine has just been changed).
    static func problem(_ explanation: String) -> String {
        let kept = explanation.components(separatedBy: ". ").filter { !$0.contains("motore Automatico") }
        guard !kept.isEmpty else { return explanation }
        let text = kept.joined(separator: ". ")
        return text.hasSuffix(".") ? text : text + "."
    }
}
