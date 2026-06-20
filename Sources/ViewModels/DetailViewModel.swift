import Foundation
import Observation

/// Récupère les méta-données détaillées (épisodes, synopsis) et les flux
/// d'un item, en interrogeant tous les add-ons configurés.
@Observable
@MainActor
final class DetailViewModel {
    private(set) var meta: MetaDetail?
    private(set) var streams: [StreamItem] = []
    private(set) var subtitles: [SubtitleItem] = []
    private(set) var isLoadingMeta = false
    private(set) var isLoadingStreams = false
    private(set) var note: String?

    private let client = AddonClient()

    func loadMeta(preview: MetaPreview, bases: [String]) async {
        isLoadingMeta = true
        defer { isLoadingMeta = false }
        let type = preview.type ?? "movie"

        for base in bases {
            if let detail = try? await client.meta(base: base, type: type, id: preview.id) {
                meta = detail
                return
            }
        }
        meta = MetaDetail(from: preview) // repli sur l'aperçu
    }

    func loadStreams(type: String, id: String, bases: [String]) async {
        isLoadingStreams = true
        defer { isLoadingStreams = false }

        var collected: [StreamItem] = []
        for base in bases {
            if let found = try? await client.streams(base: base, type: type, id: id) {
                collected += found.map { stream in
                    var tagged = stream
                    tagged.sourceBase = base
                    return tagged
                }
            }
        }
        streams = collected
        note = noteFor(collected)
    }

    /// Sous-titres externes depuis les add-ons qui fournissent la ressource.
    func loadSubtitles(type: String, id: String, addons: [InstalledAddon]) async {
        var collected: [SubtitleItem] = []
        for addon in addons where addon.manifest?.provides("subtitles") ?? false {
            if let found = try? await client.subtitles(base: addon.base, type: type, id: id) {
                collected += found
            }
        }
        subtitles = collected
    }

    private func noteFor(_ streams: [StreamItem]) -> String? {
        if streams.isEmpty {
            return "Aucun flux trouvé. Ajoute un add-on de flux (idéalement un service debrid) dans Réglages."
        }
        if streams.allSatisfy({ !$0.isDirectlyPlayable }) {
            return "Ces flux sont des torrents : AVPlayer ne peut pas les lire directement. Utilise un add-on debrid (RealDebrid / AllDebrid…) ou lance le streaming-server Stremio sur ton réseau."
        }
        return nil
    }
}
