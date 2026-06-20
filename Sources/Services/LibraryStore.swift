import Foundation
import Observation

/// Bibliothèque de l'utilisateur + progression de visionnage, synchronisée avec
/// le compte Stremio via l'API datastore. Lit l'authKey dans le Keychain.
@Observable
@MainActor
final class LibraryStore {
    private(set) var items: [LibraryItem] = []
    private(set) var isLoading = false

    private let api = StremioAPIClient()
    private let keychain = KeychainStore()
    private var authKey: String? { keychain.get("authKey") }

    // MARK: Vues dérivées

    /// « Continuer à regarder » : tout item avec une position de reprise
    /// (`timeOffset > 0`), plus récent d'abord — conforme à Stremio (on n'exclut
    /// PAS les épisodes marqués « vus », sinon une série en cours disparaît).
    var continueWatching: [LibraryItem] {
        items
            .filter(\.isInContinueWatching)
            .sorted { $0.mtimeDate > $1.mtimeDate }
    }

    /// Bibliothèque sauvegardée (favoris).
    var library: [LibraryItem] {
        items.filter(\.isInLibrary).sorted { $0.mtimeDate > $1.mtimeDate }
    }

    func item(for metaId: String) -> LibraryItem? { items.first { $0.id == metaId } }
    func isSaved(_ metaId: String) -> Bool { item(for: metaId)?.isInLibrary ?? false }

    // MARK: Synchronisation

    func refresh() async {
        guard let key = authKey else { items = []; return }
        isLoading = true
        defer { isLoading = false }
        if let library = try? await api.libraryGet(authKey: key) {
            items = library
        }
    }

    func clear() { items = [] }

    /// Ajoute / retire de la bibliothèque sauvegardée.
    func setSaved(metaId: String, type: String, name: String, poster: String?, saved: Bool) async {
        guard let key = authKey else { return }
        var item = item(for: metaId) ?? LibraryItem(autoCreatedId: metaId, type: type, name: name, poster: poster)
        item.removed = !saved
        item.temp = false
        item.mtime = DateParsing.nowString()
        upsert(item)
        await api.libraryPut(authKey: key, items: [item])
    }

    /// Enregistre la progression de lecture (reprise + marquage vu au-delà de 70 %).
    func recordProgress(
        metaId: String, type: String, name: String, poster: String?,
        videoId: String?, timeOffsetMs: UInt64, durationMs: UInt64
    ) async {
        guard let key = authKey else { return }
        var item = item(for: metaId) ?? LibraryItem(autoCreatedId: metaId, type: type, name: name, poster: poster)

        // Changement d'épisode : on repart de zéro pour celui-ci.
        if let videoId, item.state.videoId != videoId {
            item.state.videoId = videoId
            item.state.timeWatched = 0
            item.state.flaggedWatched = 0
        } else if item.state.videoId == nil {
            item.state.videoId = videoId
        }

        item.state.timeOffset = timeOffsetMs
        if durationMs > 0 { item.state.duration = durationMs }
        item.state.lastWatched = DateParsing.nowString()
        if durationMs > 0, Double(timeOffsetMs) > Double(durationMs) * 0.7 {
            item.state.flaggedWatched = 1
        }
        item.mtime = DateParsing.nowString()

        upsert(item)
        await api.libraryPut(authKey: key, items: [item])
    }

    private func upsert(_ item: LibraryItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }
}
