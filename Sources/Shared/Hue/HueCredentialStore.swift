import Foundation

/// Identifiants Hue dans le Keychain (un seul élément JSON).
///
/// `username` (clé d'application) et `clientKey` (clé PSK du flux DTLS) sont des secrets :
/// ils ne vont jamais dans les UserDefaults.
struct HueCredentialStore {
    private let keychain: KeychainStore
    private let account = "credentials"

    init(keychain: KeychainStore = KeychainStore(service: "com.nicolasbataille.stremiotv.hue")) {
        self.keychain = keychain
    }

    /// Identifiants enregistrés, ou nil (aucun, ou élément illisible).
    func load() -> HueCredentials? {
        guard let json = keychain.get(account),
              let data = json.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(HueCredentials.self, from: data),
              !credentials.username.isEmpty,
              !credentials.clientKey.isEmpty
        else { return nil }
        return credentials
    }

    /// Remplace les identifiants enregistrés.
    func save(_ credentials: HueCredentials) {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8)
        else { return }
        keychain.set(json, for: account)
    }

    /// Supprime les identifiants (dissociation du pont).
    func clear() {
        keychain.delete(account)
    }
}
