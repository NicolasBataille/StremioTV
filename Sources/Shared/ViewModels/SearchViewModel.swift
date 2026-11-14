import Foundation
import Observation

/// Recherche multi-add-ons : interroge tous les catalogues qui déclarent
/// l'extra `search`, fusionne et dédoublonne les résultats par identifiant.
@Observable
@MainActor
final class SearchViewModel {
    private(set) var results: [MetaPreview] = []
    private(set) var isSearching = false
    private(set) var lastQuery = ""
    /// Texte saisi dans la barre de recherche (conservé entre deux affichages).
    var query = ""

    private let client = AddonClient()

    /// Dernière requête dont la recherche est allée à son terme : évite de
    /// relancer la même recherche quand l'écran réapparaît (changement d'onglet).
    @ObservationIgnored private var completedQuery: String?

    func search(query: String, addons: [InstalledAddon]) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == completedQuery { return }
        completedQuery = nil
        lastQuery = trimmed
        guard trimmed.count >= 2 else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        var merged: [MetaPreview] = []
        var seen = Set<String>()

        for addon in addons {
            let manifest: Manifest?
            if let cached = addon.manifest {
                manifest = cached
            } else {
                manifest = try? await client.manifest(base: addon.base)
            }
            guard let manifest else { continue }
            for catalog in searchableCatalogs(in: manifest) {
                guard let found = try? await client.catalog(
                    base: addon.base, type: catalog.type, id: catalog.id, search: trimmed
                ) else { continue }

                // La requête a pu changer entre-temps : on ignore les résultats périmés.
                if lastQuery != trimmed { return }

                for meta in found where seen.insert(meta.id).inserted {
                    merged.append(meta)
                }
            }
        }
        results = merged
        if !Task.isCancelled { completedQuery = trimmed }
    }

    func clear() {
        results = []
        lastQuery = ""
        completedQuery = nil
    }

    private func searchableCatalogs(in manifest: Manifest) -> [CatalogDescriptor] {
        (manifest.catalogs ?? []).filter { catalog in
            catalog.extra?.contains { $0.name == "search" } ?? false
        }
    }
}
