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
enum RemuxFailureText {
    static func explain(_ error: Error) -> String {
        if let remux = error as? RemuxError { return remux.message }
        if let cast = error as? CastError, let text = cast.errorDescription { return text }
        if let local = error as? LocalRemuxError { return local.message }
        return RelayService.probeMessage(for: error)
    }
}
