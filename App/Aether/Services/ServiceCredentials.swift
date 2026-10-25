import SwiftUI
import AetherCore

/// The optional third-party services Aether can talk to with the user's own account / key.
enum ServiceKind: String, CaseIterable, Identifiable {
    case torbox, realdebrid, tmdb, tvdb, fanart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .torbox: return "TorBox"
        case .realdebrid: return "Real-Debrid"
        case .tmdb: return "TMDB"
        case .tvdb: return "TheTVDB"
        case .fanart: return "fanart.tv"
        }
    }

    /// Keychain account under which the secret is kept (never logged, never part of a backup or a diagnostic export).
    var keychainKey: String { "service.\(rawValue).secret" }

    /// Keychain account of the optional second secret (TheTVDB subscriber PIN).
    var pinKeychainKey: String { "service.\(rawValue).pin" }
}

/// Keychain-backed keys for the optional services. Only *whether* a key exists is published; the key itself is read on
/// demand by whatever client needs it and is never stored in settings, logs or the UI state.
@MainActor
final class ServiceCredentials: ObservableObject {
    @Published private(set) var configured: Set<ServiceKind> = []
    /// Called after a key was saved, replaced or removed, so that services that remember a failure can try again.
    var onChange: (() -> Void)?
    private let secrets: SecretStore

    init(secrets: SecretStore) {
        self.secrets = secrets
        refresh()
    }

    func refresh() {
        var found = Set<ServiceKind>()
        for kind in ServiceKind.allCases where ((try? secrets.get(kind.keychainKey)) ?? nil)?.isEmpty == false {
            found.insert(kind)
        }
        configured = found
    }

    func isConfigured(_ kind: ServiceKind) -> Bool { configured.contains(kind) }

    func save(_ value: String, for kind: ServiceKind, pin: String? = nil) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServiceCredentialsError.empty }
        try secrets.set(trimmed, for: kind.keychainKey)
        if let pin = pin?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty {
            try secrets.set(pin, for: kind.pinKeychainKey)
        } else {
            try? secrets.remove(kind.pinKeychainKey)
        }
        refresh()
        onChange?()
    }

    func remove(_ kind: ServiceKind) {
        try? secrets.remove(kind.keychainKey)
        try? secrets.remove(kind.pinKeychainKey)
        refresh()
        onChange?()
    }

    /// Reads the secret from the Keychain right now. Hand `provider(for:)` to Core clients instead of copying the value.
    func secret(for kind: ServiceKind) -> String? {
        return ((try? secrets.get(kind.keychainKey)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    func pin(for kind: ServiceKind) -> String? {
        return ((try? secrets.get(kind.pinKeychainKey)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A closure that reads the key from the Keychain every time it is called (so removing the key takes effect at once).
    nonisolated func provider(for kind: ServiceKind) -> @Sendable () -> String? {
        let store = secrets
        return { ((try? store.get(kind.keychainKey)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
    }

    nonisolated func pinProvider(for kind: ServiceKind) -> @Sendable () -> String? {
        let store = secrets
        return { ((try? store.get(kind.pinKeychainKey)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
    }
}

enum ServiceCredentialsError: Error, LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: return "La chiave è vuota."
        }
    }
}
