import Foundation
import Observation

/// Catalogue complet paginé (chargement progressif via l'extra `skip`).
@Observable
@MainActor
final class CatalogGridViewModel {
    private(set) var metas: [MetaPreview] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false

    private let client = AddonClient()
    private let pageSize = 100 // Stremio pagine par tranches de 100

    func loadFirstPage(base: String, type: String, catalogId: String) async {
        guard metas.isEmpty else { return }
        await loadMore(base: base, type: type, catalogId: catalogId)
    }

    func loadMore(base: String, type: String, catalogId: String) async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.catalog(
                base: base, type: type, id: catalogId, skip: metas.count
            )
            if page.isEmpty || page.count < pageSize {
                reachedEnd = true
            }
            // Dédoublonnage défensif (certains add-ons renvoient des doublons).
            let existing = Set(metas.map(\.id))
            metas += page.filter { existing.contains($0.id) == false }
        } catch {
            reachedEnd = true
        }
    }
}
