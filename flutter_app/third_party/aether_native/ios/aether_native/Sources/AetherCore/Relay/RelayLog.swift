import Foundation

public enum RelayUpstreamFailure: Equatable, Sendable {
    case rejected(status: Int)
    case unreachable(code: Int)
    case noRanges
    case badRange
    case notMedia
    case blocked
}

public enum RelayListenerState: Equatable, Sendable {
    case started(port: UInt16)
    case stopped
    case failed
    case restarted(port: UInt16)
}

public enum RelayLimitKind: Equatable, Sendable {
    case connections, perPeer, headTimeout, writeStall, malformedRequest
}

/// Everything the relay may write to the diagnostic log, as a closed set. There is no free-text field, so a token, a URL or a header can
/// not be interpolated into a log line by accident.
public enum RelayLogEvent: Equatable, Sendable {
    case sessionCreated(RelaySessionID, RelayOwner)
    case sessionRevoked(RelaySessionID, RelayEndReason)
    /// Debug level only. `method` is one of GET, HEAD, OPTIONS.
    case served(RelaySessionID, method: String, status: Int, ranged: Bool, bytes: Int64)
    case upstreamFailure(RelaySessionID, RelayUpstreamFailure)
    case listener(RelayListenerState)
    case limitHit(RelayLimitKind)

    public var level: LogLevel {
        switch self {
        case .served: return .debug
        case .sessionCreated, .sessionRevoked, .listener: return .info
        case .upstreamFailure, .limitHit: return .warning
        }
    }

    private static func name(of owner: RelayOwner) -> String {
        switch owner {
        case .cast(let target): return target == .googleCast ? "Google Cast" : (target == .dlna ? "DLNA" : "AirPlay")
        case .airPlay: return "AirPlay"
        }
    }

    public var message: String {
        switch self {
        case .sessionCreated(let id, let owner):
            return "Ponte: sessione \(id.label) creata per \(RelayLogEvent.name(of: owner))"
        case .sessionRevoked(let id, let reason):
            return "Ponte: sessione \(id.label) chiusa (\(reason.rawValue))"
        case .served(let id, let method, let status, let ranged, let bytes):
            let verb = ["GET", "HEAD", "OPTIONS"].contains(method) ? method : "?"
            return "Ponte: sessione \(id.label) \(verb) \(status)\(ranged ? " a intervallo" : ""), \(bytes) byte"
        case .upstreamFailure(let id, let failure):
            let text: String
            switch failure {
            case .rejected(let status): text = "rifiutata dalla sorgente (\(status))"
            case .unreachable(let code): text = "sorgente non raggiungibile (\(code))"
            case .noRanges: text = "la sorgente non permette letture a pezzi"
            case .badRange: text = "risposta a pezzi non valida"
            case .notMedia: text = "la sorgente non ha risposto con un video"
            case .blocked: text = "indirizzo della sorgente non consentito"
            }
            return "Ponte: sessione \(id.label), \(text)"
        case .listener(let state):
            switch state {
            case .started(let port): return "Ponte: in ascolto sulla porta \(port)"
            case .stopped: return "Ponte: spento"
            case .failed: return "Ponte: non riesce ad avviarsi"
            case .restarted(let port): return "Ponte: riavviato sulla porta \(port)"
            }
        case .limitHit(let kind):
            switch kind {
            case .connections: return "Ponte: troppe connessioni, una è stata rifiutata"
            case .perPeer: return "Ponte: troppe connessioni dallo stesso dispositivo"
            case .headTimeout: return "Ponte: richiesta troppo lenta, chiusa"
            case .writeStall: return "Ponte: il ricevitore ha smesso di leggere, chiusa"
            case .malformedRequest: return "Ponte: richiesta non valida, chiusa"
            }
        }
    }

    /// One of every kind, for the test that checks no message can leak anything.
    public static var samples: [RelayLogEvent] {
        let id = RelaySessionID(label: "a1b2c3")
        return [
            .sessionCreated(id, .cast(.googleCast)), .sessionCreated(id, .cast(.dlna)), .sessionCreated(id, .airPlay),
            .sessionRevoked(id, .userStopped), .sessionRevoked(id, .neverUsed), .sessionRevoked(id, .upstreamRejected),
            .served(id, method: "GET", status: 206, ranged: true, bytes: 1_048_576),
            .served(id, method: "weird\r\nmethod", status: 404, ranged: false, bytes: 0),
            .upstreamFailure(id, .rejected(status: 403)), .upstreamFailure(id, .unreachable(code: -1009)),
            .upstreamFailure(id, .noRanges), .upstreamFailure(id, .badRange), .upstreamFailure(id, .notMedia), .upstreamFailure(id, .blocked),
            .listener(.started(port: 51234)), .listener(.stopped), .listener(.failed), .listener(.restarted(port: 51234)),
            .limitHit(.connections), .limitHit(.perPeer), .limitHit(.headTimeout), .limitHit(.writeStall), .limitHit(.malformedRequest)
        ]
    }
}
