import Foundation
import Security

/// Stockage sécurisé (Keychain) d'une chaîne — utilisé pour l'authKey Stremio,
/// qui est un jeton de session sensible (ne jamais le mettre en clair).
struct KeychainStore {
    private let service: String

    init(service: String = "com.stremio.tv.client") {
        self.service = service
    }

    func set(_ value: String, for account: String) {
        let base = query(account)
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(insert as CFDictionary, nil)
    }

    func get(_ account: String) -> String? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
