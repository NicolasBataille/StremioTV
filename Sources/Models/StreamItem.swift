import Foundation

/// Réponse de flux : `GET {base}/stream/{type}/{id}.json`.
struct StreamResponse: Codable, Sendable {
    let streams: [StreamItem]?
}

/// Un flux proposé par un add-on. Selon l'add-on, il fournit :
/// - `url` : lien HTTP(S) direct → lisible par AVPlayer (cas debrid)
/// - `infoHash` : torrent → nécessite le streaming-server Stremio
/// - `ytId` : vidéo YouTube → non géré nativement par AVPlayer
struct StreamItem: Codable, Sendable, Identifiable {
    let url: String?
    let ytId: String?
    let infoHash: String?
    let fileIdx: Int?
    let name: String?
    let title: String?
    let description: String?
    let behaviorHints: StreamBehaviorHints?

    var id: String {
        [url, infoHash, ytId, name, title].compactMap { $0 }.joined(separator: "·")
    }

    var headline: String { name ?? "Source" }
    var subtitle: String? { title ?? description }

    /// URL directement lisible par AVPlayer (HTTP/HTTPS uniquement).
    var playableURL: URL? {
        guard let url, let parsed = URL(string: url),
              parsed.scheme?.hasPrefix("http") == true else { return nil }
        return parsed
    }

    var isDirectlyPlayable: Bool { playableURL != nil }
    var isTorrent: Bool { url == nil && infoHash != nil }
}

struct StreamBehaviorHints: Codable, Sendable {
    let notWebReady: Bool?
    let bingeGroup: String?
}
