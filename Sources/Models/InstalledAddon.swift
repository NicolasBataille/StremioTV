import Foundation

/// Un add-on installé, qu'il provienne du compte Stremio, d'un ajout manuel,
/// ou du repli intégré (Cinemeta). Conserve le manifest quand on l'a déjà
/// (cas des add-ons du compte) pour éviter une requête réseau supplémentaire.
struct InstalledAddon: Identifiable, Sendable, Codable, Equatable {
    enum Source: String, Codable, Sendable {
        case builtin    // repli (Cinemeta) quand non connecté
        case account    // tiré du compte Stremio
        case manual     // ajouté à la main
    }

    let transportUrl: String
    let name: String
    let manifest: Manifest?
    let source: Source

    /// URL de base (sans `/manifest.json`) pour construire les requêtes.
    var base: String { AddonClient.normalizeBase(transportUrl) }
    var id: String { base }

    static func == (lhs: InstalledAddon, rhs: InstalledAddon) -> Bool {
        lhs.base == rhs.base
    }
}
