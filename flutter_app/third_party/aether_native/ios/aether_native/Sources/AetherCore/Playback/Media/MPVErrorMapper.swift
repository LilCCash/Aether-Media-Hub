import Foundation

/// Turns an mpv end-of-file error (a negative `mpv_error` code plus the last log lines) into a `PlaybackFailure`.
/// The codes are the stable values of `enum mpv_error` in mpv's client.h.
public enum MPVErrorMapper {
    public static let loadingFailed: Int32 = -13
    public static let audioOutputInitFailed: Int32 = -14
    public static let videoOutputInitFailed: Int32 = -15
    public static let nothingToPlay: Int32 = -16
    public static let unknownFormat: Int32 = -17
    public static let unsupported: Int32 = -18

    public static func map(code: Int32, message: String, recentLog: [String]) -> PlaybackFailure {
        let log = recentLog.joined(separator: "\n").lowercased()
        let detail = message.isEmpty ? "mpv \(code)" : message

        // The log carries the real reason of a "loading failed": look at it first.
        if log.contains("error 403") || log.contains("403 forbidden") || log.contains("error 401") || log.contains("401 unauthorized") {
            return PlaybackFailure(kind: .forbidden, detail: detail)
        }
        if log.contains("error 404") || log.contains("404 not found") || log.contains("error 410") {
            return PlaybackFailure(kind: .notFound, detail: detail)
        }
        if log.contains("timed out") || log.contains("timeout") {
            return PlaybackFailure(kind: .timeout, detail: detail)
        }
        if log.contains("certificate") || log.contains("tls") && log.contains("fail") {
            return PlaybackFailure(kind: .tlsFailure, detail: detail)
        }
        if log.contains("network is unreachable") || log.contains("not connected to the internet") || log.contains("offline") {
            return PlaybackFailure(kind: .offline, detail: detail)
        }
        if log.contains("failed to resolve") || log.contains("connection refused") || log.contains("could not resolve") {
            return PlaybackFailure(kind: .unreachable, detail: detail)
        }

        switch code {
        case unknownFormat, nothingToPlay, unsupported:
            return PlaybackFailure(kind: .formatUnsupported, detail: detail)
        case videoOutputInitFailed:
            return PlaybackFailure(kind: .unknown, detail: "Impossibile inizializzare l'uscita video del motore MPV (\(detail)).")
        case audioOutputInitFailed:
            return PlaybackFailure(kind: .unknown, detail: "Impossibile inizializzare l'uscita audio (\(detail)).")
        case loadingFailed:
            return PlaybackFailure(kind: .unreachable, detail: detail)
        default:
            return PlaybackFailure(kind: .unknown, detail: detail)
        }
    }
}
