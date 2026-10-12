import Foundation

// Contrat commun des « prises d'image » (frame taps) de l'Ambilight.
// Fichier « pur » Foundation : compilable et testable hors plateformes Apple.

/// Petite image échantillonnée de la vidéo en cours (typiquement 64×36).
struct SampledFrame {
    let width: Int
    let height: Int
    /// Pixels RGBA 8 bits, ligne par ligne depuis le coin **haut-gauche**,
    /// sRGB encodé gamma. `rgba.count == width * height * 4` (l'alpha est ignoré).
    let rgba: [UInt8]
    /// Horodatage monotone en secondes (`ProcessInfo.processInfo.systemUptime`).
    let timestamp: TimeInterval
}

/// Source d'images échantillonnées de la lecture en cours.
/// Implémentations : `ViewSnapshotTap` (capture de la vue vidéo) et
/// `VLCSnapshotTap` (instantanés libVLC).
protocol FrameTap: AnyObject {
    /// Nom court affiché dans les diagnostics (« Vue », « Snapshot VLC »…).
    var name: String { get }
    /// Appelé pour chaque image échantillonnée, sur une file quelconque.
    var onFrame: ((SampledFrame) -> Void)? { get set }
    /// Démarre l'échantillonnage (à appeler depuis le thread principal).
    func start()
    /// Arrête l'échantillonnage (idempotent, depuis le thread principal).
    func stop()
}
