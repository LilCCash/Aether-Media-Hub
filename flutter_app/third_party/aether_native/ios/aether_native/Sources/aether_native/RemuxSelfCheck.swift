import AVFoundation
import Foundation

/// Opens the first piece of a converted file with AVFoundation as a plain file and says in the log what it thinks of it. The system
/// player only ever answers «media may be damaged»; this gives its real reason, and tells a broken piece from a broken playlist.
enum RemuxSelfCheck {
    static func run(initSegment: Data, fragment: Data, log: @escaping (String) -> Void) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remux-check.mp4")
        do {
            try (initSegment + fragment).write(to: url)
        } catch {
            log("verifica: file di prova non scritto")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            log("verifica AVFoundation: \(tracks.count) tracce, \(initSegment.count) + \(fragment.count) byte")
            guard let reader = try? AVAssetReader(asset: asset) else {
                log("verifica: lettore non creato")
                return
            }
            var outputs: [(AVAssetTrack, AVAssetReaderTrackOutput)] = []
            for track in tracks {
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                outputs.append((track, output))
            }
            guard reader.startReading() else {
                log("verifica: lettura non avviata: \(describe(reader.error))")
                return
            }
            for (track, output) in outputs {
                var count = 0
                while count < 60, output.copyNextSampleBuffer() != nil { count += 1 }
                log("verifica: traccia \(track.mediaType.rawValue), \(count) campioni letti")
            }
            if reader.status == .failed { log("verifica: lettura fallita: \(describe(reader.error))") }
        } catch {
            log("verifica AVFoundation fallita: \(describe(error))")
        }
    }

    private static func describe(_ error: Error?) -> String {
        guard let e = error as NSError? else { return "errore sconosciuto" }
        var text = "\(e.domain) \(e.code) \(e.localizedDescription)"
        if let reason = e.localizedFailureReason { text += " (\(reason))" }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError { text += " ← \(under.domain) \(under.code)" }
        return text
    }
}
