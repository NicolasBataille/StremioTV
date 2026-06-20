import Foundation

/// Réponse de sous-titres : `GET {base}/subtitles/{type}/{id}.json`
/// (add-ons OpenSubtitles & co.).
struct SubtitleResponse: Codable, Sendable {
    let subtitles: [SubtitleItem]?
}

/// Un sous-titre externe proposé par un add-on (fichier SRT/VTT distant).
struct SubtitleItem: Codable, Sendable, Identifiable {
    let url: String
    let lang: String
    private let subtitleId: String?

    enum CodingKeys: String, CodingKey {
        case url, lang
        case subtitleId = "id"
    }

    var id: String { subtitleId ?? url }

    /// Libellé lisible pour le menu (langue, à défaut l'identifiant).
    var displayLanguage: String { lang.isEmpty ? id : lang }
}
