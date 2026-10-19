import Foundation
import Security
import AetherCore

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "errore \(status)"
            return "Portachiavi: \(message)"
        }
    }
}

/// Generic-password Keychain storage, device-bound (`ThisDeviceOnly`) and available after first unlock so background
/// downloads and Now Playing can still read what they need.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    init(service: String = "app.aether.secrets") {
        self.service = service
    }

    private func baseQuery(account: String? = nil) -> [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let account = account { query[kSecAttrAccount] = account }
        return query
    }

    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: key)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (name, attribute) in attributes { add[name] = attribute }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func get(_ key: String) throws -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    func allKeys(prefix: String) throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw KeychainError.status(status) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// Removes every secret created by the app (used by "Delete local data").
    func removeAll() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
