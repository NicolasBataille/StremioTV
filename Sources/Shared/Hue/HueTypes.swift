import Foundation

// Types partagés de l'intégration Philips Hue (API Entertainment v2).
// Fichier « pur » Foundation : compilable et testable hors plateformes Apple.

/// Couleur envoyée au pont : RGB sRGB **encodé gamma**, composantes 0…1.
/// Le pont convertit lui-même vers le gamut de chaque lampe (mode RGB de HueStream).
struct HueRGB: Equatable, Hashable, Codable {
    var r: Double
    var g: Double
    var b: Double

    static let black = HueRGB(r: 0, g: 0, b: 0)

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// Couleur cible d'un canal d'une zone de divertissement.
struct HueChannelColor: Equatable, Hashable {
    let channelID: UInt8
    var color: HueRGB
}

/// Canal d'une zone de divertissement (une lampe, ou un segment d'un ruban gradient).
/// Position Hue : x −1 (gauche) → +1 (droite), y −1 (fond de la pièce / spectateur)
/// → +1 (côté TV), z −1 (sol) → +1 (plafond).
struct HueChannel: Equatable, Hashable, Codable {
    let id: UInt8
    let x: Double
    let y: Double
    let z: Double
}

/// Zone de divertissement (`entertainment_configuration` CLIP v2), créée dans l'app Hue.
struct HueEntertainmentArea: Equatable, Hashable, Codable, Identifiable {
    /// UUID de la configuration (36 caractères), aussi utilisé dans les paquets HueStream.
    let id: String
    let name: String
    /// `screen`, `monitor`, `music`, `3dspace` ou `other`.
    let configurationType: String
    /// `true` si un flux est actif sur cette zone (le nôtre ou celui d'une autre app).
    let isStreaming: Bool
    /// `rid` de l'application qui diffuse actuellement, s'il y en a une.
    let activeStreamerID: String?
    let channels: [HueChannel]
}

/// Pont trouvé sur le réseau local (Bonjour ou `discovery.meethue.com`).
struct HueBridgeCandidate: Equatable, Hashable, Codable, Identifiable {
    /// Identifiant du pont en minuscules (16 caractères hexadécimaux), ou l'hôte si inconnu.
    let id: String
    /// Adresse IP (ou nom d'hôte) joignable en HTTPS.
    let host: String
}

/// Identifiants obtenus à l'appairage (bouton du pont). Persistés dans le Keychain.
struct HueCredentials: Equatable, Codable {
    var bridgeID: String
    var host: String
    /// `hue-application-key` (API v1 : « username »).
    let username: String
    /// Clé PSK DTLS : 32 caractères hexadécimaux (16 octets).
    let clientKey: String
    /// `hue-application-id` (identité PSK DTLS), lue via `GET /auth/v1`.
    var applicationID: String?
    /// Empreinte SHA-256 (hex minuscule) du certificat du pont, épinglée au premier contact.
    var certificateSHA256: String?
}

/// Résultat d'une tentative d'appairage `POST /api`.
enum HuePairingResult: Equatable {
    case success(username: String, clientKey: String)
    /// Erreur 101 : le bouton du pont n'a pas (encore) été pressé.
    case linkButtonNotPressed
    case failure(type: Int, description: String)
}

enum HueError: Error, Equatable, LocalizedError {
    case notConfigured
    case noBridgeFound
    case linkButtonTimeout
    case invalidResponse
    case http(status: Int)
    case bridge(String)
    case noEntertainmentArea
    case areaInUseByAnotherApp
    case handshakeFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Aucun pont Hue n'est associé."
        case .noBridgeFound: return "Aucun pont Hue trouvé sur le réseau."
        case .linkButtonTimeout: return "Le bouton du pont n'a pas été pressé à temps."
        case .invalidResponse: return "Réponse inattendue du pont Hue."
        case .http(let status): return "Le pont Hue a répondu HTTP \(status)."
        case .bridge(let message): return "Pont Hue : \(message)"
        case .noEntertainmentArea: return "Aucune zone de divertissement. Crée-en une dans l'app Hue."
        case .areaInUseByAnotherApp: return "La zone est déjà utilisée par une autre app (Hue Sync…)."
        case .handshakeFailed(let message): return "Connexion DTLS au pont impossible : \(message)"
        case .timeout: return "Le pont Hue ne répond pas."
        }
    }
}

/// Transport des datagrammes HueStream vers le pont (DTLS 1.2 PSK, UDP 2100).
/// Implémentations : `HueDTLSTransport` (Network.framework) et des doublures de test.
protocol HueDatagramTransport: AnyObject {
    /// Établit la session DTLS. `completion` est appelée une seule fois, sur une file quelconque.
    func connect(host: String,
                 pskIdentity: String,
                 pskHex: String,
                 timeout: TimeInterval,
                 completion: @escaping (Result<Void, Error>) -> Void)
    /// Envoie un datagramme (sans attente d'accusé ; appelable depuis n'importe quelle file).
    func send(_ datagram: Data)
    /// Ferme la session (idempotent).
    func close()
}
