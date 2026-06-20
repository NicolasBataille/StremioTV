import Foundation
import Observation

/// Charge, pour chaque add-on, son manifest puis la 1re page de ses catalogues,
/// et expose des sections prêtes à afficher (rangées) sur l'accueil.
/// Le chargement est parallélisé (manifests puis catalogues) pour rester rapide
/// même avec de nombreux add-ons.
@Observable
@MainActor
final class HomeViewModel {
    struct CatalogSection: Identifiable, Sendable {
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

        // 1. Résoudre les manifests en parallèle (ordre conservé).
        let manifests: [Manifest?] = await withTaskGroup(of: (Int, Manifest?).self) { group in
            for (index, addon) in addons.enumerated() {
                group.addTask { (index, await self.resolveManifest(addon)) }
            }
            var result = [Manifest?](repeating: nil, count: addons.count)
            for await (index, manifest) in group { result[index] = manifest }
            return result
        }

        // 2. Construire la liste ordonnée des catalogues à charger.
        var jobs: [(order: Int, base: String, name: String, catalog: CatalogDescriptor)] = []
        for (index, addon) in addons.enumerated() {
            guard let manifest = manifests[index] else { continue }
            for catalog in manifest.catalogs ?? [] where !catalog.isSearchOnly {
                jobs.append((jobs.count, addon.base, manifest.name, catalog))
            }
        }

        // 3. Charger les sections en parallèle et les afficher **au fil de l'eau**
        //    (dans l'ordre), pour que les add-ons rapides s'affichent sans
        //    attendre les lents.
        sections = []
        var byOrder: [Int: CatalogSection] = [:]
        await withTaskGroup(of: (Int, CatalogSection?).self) { group in
            for job in jobs {
                group.addTask {
                    (job.order, await self.loadSection(base: job.base, addonName: job.name, catalog: job.catalog))
                }
            }
            for await (order, section) in group {
                guard let section else { continue }
                byOrder[order] = section
                sections = byOrder.keys.sorted().compactMap { byOrder[$0] }
            }
        }

        errorMessage = sections.isEmpty ? "Aucun catalogue disponible." : nil
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
            return nil
        }
    }
}
