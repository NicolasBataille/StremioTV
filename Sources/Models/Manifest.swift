import Foundation

/// Manifest d'un add-on Stremio (`GET {base}/manifest.json`).
/// Spec : https://github.com/Stremio/stremio-addon-sdk
struct Manifest: Codable, Sendable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let resources: [ManifestResource]?
    let types: [String]?
    let catalogs: [CatalogDescriptor]?

    /// L'add-on expose-t-il la ressource demandée ("catalog", "meta", "stream") ?
    func provides(_ resource: String) -> Bool {
        resources?.contains { $0.name == resource } ?? false
    }
}

/// `resources` peut être une liste de chaînes ("catalog") ou d'objets
/// `{ name, types, idPrefixes }`. On gère les deux formes.
enum ManifestResource: Codable, Sendable {
    case simple(String)
    case detailed(name: String, types: [String]?, idPrefixes: [String]?)

    var name: String {
        switch self {
        case .simple(let value): return value
        case .detailed(let value, _, _): return value
        }
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self = .simple(single)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .detailed(
            name: try container.decode(String.self, forKey: .name),
            types: try? container.decode([String].self, forKey: .types),
            idPrefixes: try? container.decode([String].self, forKey: .idPrefixes)
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .simple(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .detailed(let name, let types, let idPrefixes):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(types, forKey: .types)
            try container.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
        }
    }

    private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
}

/// Descripteur de catalogue annoncé dans le manifest.
struct CatalogDescriptor: Codable, Sendable {
    let type: String
    let id: String
    let name: String?
    let extra: [CatalogExtra]?

    var uniqueKey: String { "\(type)/\(id)" }
    var displayName: String { name ?? id.capitalized }

    /// Certains catalogues ne servent qu'à la recherche (extra `search` requis) :
    /// on ne les charge pas sur l'écran d'accueil.
    var isSearchOnly: Bool {
        extra?.contains { $0.name == "search" && ($0.isRequired ?? false) } ?? false
    }
}

struct CatalogExtra: Codable, Sendable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
}
