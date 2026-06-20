import Foundation

/// Enveloppe de réponse de l'API Stremio (`https://api.strem.io/api/...`).
/// Soit `{ "result": ... }`, soit `{ "error": { code, message } }`.
struct APIEnvelope<T: Decodable>: Decodable {
    let result: T?
    let error: APIErrorBody?
}

struct APIErrorBody: Decodable, LocalizedError {
    let code: Int
    let message: String
    let wrongEmail: Bool?
    let wrongPassword: Bool?

    var errorDescription: String? { message }
}

/// Résultat d'une authentification (`login`, `loginWithToken`).
struct AuthResponse: Decodable, Sendable {
    let authKey: String
    let user: APIUser?
}

struct APIUser: Decodable, Sendable {
    let id: String?
    let email: String?

    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case email
    }
}

/// Réponse de `addonCollectionGet` : la liste des add-ons installés du compte.
struct CollectionResponse: Decodable, Sendable {
    let addons: [APIAddon]
    let lastModified: String?
}

/// Un add-on tel que renvoyé par le compte (inclut son manifest complet).
/// Décodage tolérant : un manifest illisible devient `nil` (il sera re-récupéré
/// en direct) au lieu de faire échouer toute la collection.
struct APIAddon: Decodable, Sendable {
    let transportUrl: String
    let manifest: Manifest?
    let flags: AddonFlags?

    init(transportUrl: String, manifest: Manifest?, flags: AddonFlags?) {
        self.transportUrl = transportUrl
        self.manifest = manifest
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey { case transportUrl, manifest, flags }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transportUrl = try container.decode(String.self, forKey: .transportUrl)
        manifest = try? container.decode(Manifest.self, forKey: .manifest)
        flags = try? container.decode(AddonFlags.self, forKey: .flags)
    }
}

struct AddonFlags: Decodable, Sendable {
    let official: Bool?
    let protected: Bool?
}
