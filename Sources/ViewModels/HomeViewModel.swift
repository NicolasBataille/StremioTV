import Foundation
import Observation

/// Charge, pour chaque add-on, son manifest puis la 1re page de ses catalogues,
/// et expose des sections prêtes à afficher (rangées) sur l'accueil.
@Observable
@MainActor
final class HomeViewModel {
    struct CatalogSection: Identifiable {
        let id: String
        let title: String
        let base: String
        let type: String
        let catalogId: String
        let metas: [MetaPreview]
    }

    private(set) var sections: [CatalogSection] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let client = AddonClient()

    func load(addons: [InstalledAddon]) async {
        isLoading = true
        errorMessage = nil
        var collected: [CatalogSection] = []
        var firstError: String?

        for addon in addons {
            guard let manifest = await resolveManifest(addon) else {
                firstError = firstError ?? "Manifest indisponible (\(addon.name))"
                continue
            }
            for catalog in manifest.catalogs ?? [] where !catalog.isSearchOnly {
                if let section = await loadSection(base: addon.base, addonName: manifest.name, catalog: catalog) {
                    collected.append(section)
                }
            }
        }

        sections = collected
        errorMessage = collected.isEmpty ? firstError : nil
        isLoading = false
    }

    private func resolveManifest(_ addon: InstalledAddon) async -> Manifest? {
        if let manifest = addon.manifest { return manifest }
        return try? await client.manifest(base: addon.base)
    }

    private func loadSection(
        base: String, addonName: String, catalog: CatalogDescriptor
    ) async -> CatalogSection? {
        do {
            let metas = try await client.catalog(base: base, type: catalog.type, id: catalog.id)
            guard !metas.isEmpty else { return nil }
            return CatalogSection(
                id: "\(base)|\(catalog.uniqueKey)",
                title: "\(catalog.displayName) · \(addonName)",
                base: base,
                type: catalog.type,
                catalogId: catalog.id,
                metas: metas
            )
        } catch {
            return nil // un catalogue en échec ne casse pas l'accueil
        }
    }
}
