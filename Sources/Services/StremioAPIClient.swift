import Foundation

/// Client de l'API web Stremio (compte utilisateur + collection d'add-ons).
/// Contrat vérifié sur Stremio/stremio-core : tous les appels sont des POST
/// JSON vers `https://api.strem.io/api/<method>`, réponse `{result}` ou `{error}`.
struct StremioAPIClient {
    private let endpoint = URL(string: "https://api.strem.io/api/")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func login(email: String, password: String) async throws -> AuthResponse {
        try await post(
            "login",
            body: ["type": "Login", "email": email, "password": password, "facebook": false],
            as: AuthResponse.self
        )
    }

    /// Re-valide un authKey stocké (au lancement) sans redemander le mot de passe.
    func loginWithToken(_ token: String) async throws -> AuthResponse {
        try await post(
            "loginWithToken",
            body: ["type": "LoginWithToken", "token": token],
            as: AuthResponse.self
        )
    }

    func addonCollection(authKey: String) async throws -> [APIAddon] {
        let response = try await post(
            "addonCollectionGet",
            body: ["type": "AddonCollectionGet", "authKey": authKey, "update": true],
            as: CollectionResponse.self
        )
        return response.addons
    }

    func logout(authKey: String) async {
        _ = try? await postData("logout", body: ["type": "Logout", "authKey": authKey])
    }

    // MARK: - Bibliothèque (datastore — pas de tag "type" dans le body)

    func libraryGet(authKey: String) async throws -> [LibraryItem] {
        struct Body: Encodable { let authKey: String; let collection: String; let ids: [String]; let all: Bool }
        return try await postEncodable(
            "datastoreGet",
            body: Body(authKey: authKey, collection: "libraryItem", ids: [], all: true),
            as: [LibraryItem].self
        )
    }

    func libraryPut(authKey: String, items: [LibraryItem]) async {
        struct Body: Encodable { let authKey: String; let collection: String; let changes: [LibraryItem] }
        _ = try? await postEncodableRaw(
            "datastorePut",
            body: Body(authKey: authKey, collection: "libraryItem", changes: items)
        )
    }

    // MARK: - Internals

    private func post<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        let data = try await postData(path, body: body)
        let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
        if let error = envelope.error { throw error }
        guard let result = envelope.result else { throw AddonError.decoding("réponse API vide") }
        return result
    }

    private func postData(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint) else { throw AddonError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AddonError.http(-1) }
        // L'API Stremio renvoie 200 même pour les erreurs métier (portées par le body).
        guard (200..<500).contains(http.statusCode) else { throw AddonError.http(http.statusCode) }
        return data
    }

    private func postEncodable<B: Encodable, T: Decodable>(_ path: String, body: B, as type: T.Type) async throws -> T {
        let data = try await postEncodableRaw(path, body: body)
        let envelope = try JSONDecoder().decode(APIEnvelope<T>.self, from: data)
        if let error = envelope.error { throw error }
        guard let result = envelope.result else { throw AddonError.decoding("réponse API vide") }
        return result
    }

    @discardableResult
    private func postEncodableRaw<B: Encodable>(_ path: String, body: B) async throws -> Data {
        guard let url = URL(string: path, relativeTo: endpoint) else { throw AddonError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AddonError.http(-1) }
        guard (200..<500).contains(http.statusCode) else { throw AddonError.http(http.statusCode) }
        return data
    }
}
