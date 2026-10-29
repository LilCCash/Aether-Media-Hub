import Foundation

/// How the address of a video reaches a receiver.
public enum CastDelivery: String, Equatable, Sendable {
    /// The source's own address, as it is. Nothing secret in it.
    case direct
    /// The phone fetches the video and serves it on a keyless address of its own (the "ponte").
    case relay
    /// The source's own address with the viewer's account key in it. Only after the viewer chose it in Settings.
    case directWithKey
}

/// What is known about a source before anything is sent.
public struct CastSourceTraits: Equatable, Sendable {
    /// A downloaded file: it only exists on this phone.
    public var isLocalFile: Bool
    /// The address carries the viewer's account key (a debrid link).
    public var carriesAccountKey: Bool
    /// The source needs HTTP request headers that only the phone can send.
    public var hasRequestHeaders: Bool

    public init(isLocalFile: Bool = false, carriesAccountKey: Bool = false, hasRequestHeaders: Bool = false) {
        self.isLocalFile = isLocalFile
        self.carriesAccountKey = carriesAccountKey
        self.hasRequestHeaders = hasRequestHeaders
    }
}

public enum CastRefusal: Equatable, Sendable {
    case localFile
    case relayUnavailable(RelayUnavailableReason, carriesKey: Bool, headers: Bool)
    case plainHTTPNeedsRelay

    public var title: String {
        switch self {
        case .localFile: return "Non trasmettibile"
        case .relayUnavailable, .plainHTTPNeedsRelay: return "Serve il ponte sul telefono"
        }
    }

    /// Italian, for the viewer. Never contains an address or a key.
    public var message: String {
        switch self {
        case .localFile:
            return "I file scaricati si trovano solo su questo telefono: il televisore non può leggerli. Usa AirPlay, oppure trasmetti la sorgente online."
        case .relayUnavailable(let reason, let carriesKey, let headers):
            if headers {
                return "Questa sorgente richiede intestazioni HTTP che solo il telefono può inviare. Serve il ponte, ma \(reason.message). L'opzione «Invia il link diretto» non può aiutare in questo caso."
            }
            _ = carriesKey
            return "Questo video contiene la tua chiave TorBox, che Aether non dà al televisore. Per trasmetterlo il telefono deve fare da ponte, ma \(reason.message). In alternativa, in Impostazioni ▸ Avanzate puoi scegliere di inviare il link diretto (sconsigliato)."
        case .plainHTTPNeedsRelay:
            return "La sorgente usa HTTP non cifrato e richiede intestazioni: Aether non può inoltrarla in modo sicuro."
        }
    }
}

public enum CastDeliveryOutcome: Equatable, Sendable {
    case deliver(CastDelivery)
    case refuse(CastRefusal)
}

/// The one place that decides how a source is handed to a Google Cast or DLNA receiver.
///
///  * A source that needs request headers always goes through the relay: a direct address cannot carry headers.
///  * A source whose address carries the account key goes through the relay, unless the viewer chose to send the direct link.
///  * If the relay is needed and not available, the source is refused. It is never sent directly "as a fallback".
public enum CastDeliveryPlanner {
    public static func decide(_ traits: CastSourceTraits, target: CastTarget, sendDirectLinkToTV: Bool,
                              relay: RelayAvailability) -> CastDeliveryOutcome {
        // AirPlay does not go through the cast coordinator: the system player hands the address to the receiver.
        if target == .airPlay { return .deliver(.direct) }
        if traits.isLocalFile { return .refuse(.localFile) }

        if traits.hasRequestHeaders {
            switch relay {
            case .ready: return .deliver(.relay)
            case .unavailable(let reason):
                return .refuse(.relayUnavailable(reason, carriesKey: traits.carriesAccountKey, headers: true))
            }
        }
        if traits.carriesAccountKey {
            if sendDirectLinkToTV { return .deliver(.directWithKey) }
            switch relay {
            case .ready: return .deliver(.relay)
            case .unavailable(let reason):
                return .refuse(.relayUnavailable(reason, carriesKey: true, headers: false))
            }
        }
        return .deliver(.direct)
    }
}
