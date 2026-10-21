import Foundation

public enum RelayUnavailableReason: Equatable, Sendable {
    case noLAN
    case localNetworkDisabledInSettings
    case listenerFailed

    /// The reason as it completes a sentence ("…, ma {motivo}").
    public var message: String {
        switch self {
        case .noLAN: return "il telefono non ha un indirizzo Wi-Fi utilizzabile (collegati al Wi-Fi del televisore)"
        case .localNetworkDisabledInSettings: return "la rete locale è disattivata in Impostazioni ▸ Account e dati"
        case .listenerFailed: return "non riesco ad avviare il ponte: riprova tra qualche secondo"
        }
    }
}

public enum RelayAvailability: Equatable, Sendable {
    case ready(LANInterface)
    case unavailable(RelayUnavailableReason)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
