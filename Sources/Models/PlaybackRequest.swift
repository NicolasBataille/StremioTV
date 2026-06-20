import Foundation

/// Tout ce dont le lecteur a besoin pour lire un flux, reprendre à la bonne
/// position, charger les sous-titres externes et enregistrer la progression.
struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let metaId: String          // id de la fiche (ex: tt0111161)
    let type: String            // movie / series
    let name: String
    let poster: String?
    let videoId: String         // épisode courant (= metaId pour un film)
    let resumeOffsetMs: UInt64   // position de reprise
    let subtitles: [SubtitleItem]
}
