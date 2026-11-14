import SwiftUI

/// Écran d'accueil : bannière héros, « Continuer à regarder » et une rangée
/// horizontale par catalogue d'add-on. Rafraîchissement par tirer-pour-recharger.
struct HomeScreen: View {
    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    /// Partagé via `MainShell` pour survivre aux changements d'onglet/section.
    @Environment(HomeViewModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if let featured = model.sections.first?.metas.first {
                        HeroCard(preview: featured, bases: repo.addons.map(\.base))
                    }
                    if !library.continueWatching.isEmpty {
                        ContinueWatchingRail(items: library.continueWatching)
                    }
                    content
                }
                .padding(.vertical)
            }
            .navigationTitle("Accueil")
            .refreshable {
                await library.refresh()
                await model.load(addons: repo.addons, force: true)
            }
            // Ne recharge que si les add-ons ont changé : revenir sur l'onglet
            // n'entraîne plus de nouvelle série de requêtes.
            .task(id: repo.addons.map(\.id)) {
                await model.load(addons: repo.addons)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.sections.isEmpty {
            ProgressView("Chargement des catalogues…")
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if let error = model.errorMessage, model.sections.isEmpty {
            ContentUnavailableView {
                Label("Impossible de charger les catalogues", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            }
            .padding(.top, 60)
        } else {
            ForEach(model.sections) { section in
                CatalogRail(section: section)
            }
        }
    }
}
