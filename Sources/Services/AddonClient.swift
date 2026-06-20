import Foundation

enum AddonError: LocalizedError {
    case badURL
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "URL d'add-on invalide."
        case .http(let code): return "Erreur réseau (HTTP \(code))."
        case .decoding(let detail): return "Réponse illisible : \(detail)"
        }
    }
}

/// Client HTTP du protocole d'add-ons Stremio.
/// Toutes les requêtes sont des `GET` JSON, sans authentification au niveau
/// du protocole (l'auth éventuelle est encodée dans l'URL de base de l'add-on).
struct AddonClient {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Nettoie une URL saisie par l'utilisateur : retire `/manifest.json`
    /// final et les `/` superflus pour obtenir l'URL de base de l'add-on.
    static func normalizeBase(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/manifest.json") {
            value.removeLast("/manifest.json".count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    func manifest(base: String) async throws -> Manifest {
        try await get("\(base)/manifest.json", as: Manifest.self)
    }

    /// Récupère une page de catalogue. `skip` pagine, `search` filtre.
    /// Les "extra" Stremio sont encodés dans un segment de chemin :
    /// `/catalog/{type}/{id}/skip=100&search=foo.json`.
    func catalog(
        base: String, type: String, id: String,
        skip: Int? = nil, search: String? = nil
    ) async throws -> [MetaPreview] {
        var extras: [String] = []
        if let skip, skip > 0 { extras.append("skip=\(skip)") }
        if let search, !search.isEmpty { extras.append("search=\(escape(search))") }

        var path = "\(base)/catalog/\(escape(type))/\(escape(id))"
        if !extras.isEmpty { path += "/" + extras.joined(separator: "&") }
        path += ".json"

        return try await get(path, as: CatalogResponse.self).metas ?? []
    }

    func meta(base: String, type: String, id: String) async throws -> MetaDetail? {
        let response = try await get(
            "\(base)/meta/\(escape(type))/\(escape(id)).json",
            as: MetaResponse.self
        )
        return response.meta
    }

    func streams(base: String, type: String, id: String) async throws -> [StreamItem] {
        let response = try await get(
            "\(base)/stream/\(escape(type))/\(escape(id)).json",
            as: StreamResponse.self
        )
        return response.streams ?? []
    }

    func subtitles(base: String, type: String, id: String) async throws -> [SubtitleItem] {
        let response = try await get(
            "\(base)/subtitles/\(escape(type))/\(escape(id)).json",
            as: SubtitleResponse.self
        )
        return response.subtitles ?? []
    }

    // MARK: - Internals

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let url = URL(string: path) else { throw AddonError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AddonError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw AddonError.http(http.statusCode) }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AddonError.decoding(String(describing: error))
        }
    }

    /// Encode un segment de chemin en préservant `:` que Stremio utilise dans
    /// les identifiants de série (`tt1234567:1:1`).
    private func escape(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(charactersIn: ":")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
