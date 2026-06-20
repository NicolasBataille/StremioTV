import Foundation

/// Réponse d'un catalogue : `GET {base}/catalog/{type}/{id}.json`.
struct CatalogResponse: Codable, Sendable {
    let metas: [MetaPreview]?
}

/// Réponse de méta-données : `GET {base}/meta/{type}/{id}.json`.
struct MetaResponse: Codable, Sendable {
    let meta: MetaDetail?
}

/// Aperçu d'un item dans un catalogue (poster + titre).
struct MetaPreview: Codable, Sendable, Identifiable {
    let id: String
    let type: String?
    let name: String?
    let poster: String?
    let posterShape: String?
    let background: String?
    let description: String?
}

/// Méta-données détaillées d'un film ou d'une série.
struct MetaDetail: Codable, Sendable, Identifiable {
    let id: String
    let type: String?
    let name: String?
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
    let videos: [MetaVideo]?

    /// Construit un détail minimal à partir d'un aperçu, en attendant
    /// (ou à défaut de) la réponse `/meta`.
    init(from preview: MetaPreview) {
        self.init(
            id: preview.id, type: preview.type, name: preview.name,
            poster: preview.poster, background: preview.background, logo: nil,
            description: preview.description, releaseInfo: nil, imdbRating: nil,
            genres: nil, videos: nil
        )
    }

    init(id: String, type: String?, name: String?, poster: String?,
         background: String?, logo: String?, description: String?,
         releaseInfo: String?, imdbRating: String?, genres: [String]?,
         videos: [MetaVideo]?) {
        self.id = id; self.type = type; self.name = name; self.poster = poster
        self.background = background; self.logo = logo; self.description = description
        self.releaseInfo = releaseInfo; self.imdbRating = imdbRating
        self.genres = genres; self.videos = videos
    }
}

/// Un épisode (pour les séries) ou la vidéo principale (pour les films).
struct MetaVideo: Codable, Sendable, Identifiable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let released: String?
    let thumbnail: String?

    var displayTitle: String {
        if let season, let episode {
            let suffix = title.map { " · \($0)" } ?? ""
            return "S\(season)E\(episode)\(suffix)"
        }
        return title ?? id
    }
}
