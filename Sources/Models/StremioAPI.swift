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
struct APIAddon: Decodable, Sendable {
    let transportUrl: String
    let manifest: Manifest?
    let flags: AddonFlags?
}

struct AddonFlags: Decodable, Sendable {
    let official: Bool?
    let protected: Bool?
}
