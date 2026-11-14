import SwiftUI

/// Recherche multi-add-ons. Résultats en grille adaptative.
struct SearchScreen: View {
    @Environment(AddonRepository.self) private var repo
    /// Partagé via `MainShell` : la saisie et les résultats sont conservés
    /// quand on change d'onglet/section puis qu'on revient.
    @Environment(SearchViewModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                if model.isSearching && model.results.isEmpty {
                    ProgressView().padding(.top, 80)
                } else if !model.lastQuery.isEmpty && model.results.isEmpty {
                    ContentUnavailableView.search(text: model.lastQuery)
                        .padding(.top, 60)
                } else if model.results.isEmpty {
                    ContentUnavailableView {
                        Label("Rechercher", systemImage: "magnifyingglass")
                    } description: {
                        Text("Films, séries… dans tous tes add-ons.")
                    }
                    .padding(.top, 60)
                } else {
                    PosterGrid(metas: model.results)
                        .padding(.vertical)
                }
            }
            .navigationTitle("Recherche")
            // Barre toujours visible sous le titre (iPhone : sinon masquée tant
            // qu'on ne tire pas la liste vers le bas ; iPad : sinon reléguée
            // dans le coin supérieur droit de la barre de navigation).
            .searchable(
                text: $model.query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Rechercher un film, une série…"
            )
            .task(id: model.query) {
                // `.task(id:)` annule automatiquement la recherche précédente à
                // chaque frappe ; le court délai debounce les saisies rapides.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await model.search(query: model.query, addons: repo.addons)
            }
        }
    }
}
