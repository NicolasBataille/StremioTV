import SwiftUI

/// Recherche multi-add-ons. Affiche les résultats en grille.
struct SearchView: View {
    @Environment(AddonRepository.self) private var repo
    @State private var model = SearchViewModel()
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 40)]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Recherche")
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(model.results) { meta in
                            NavigationLink {
                                MetaDetailView(preview: meta)
                            } label: {
                                PosterCard(meta: meta)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(60)

                    if model.isSearching {
                        ProgressView().padding(40)
                    } else if !model.lastQuery.isEmpty && model.results.isEmpty {
                        Text("Aucun résultat pour « \(model.lastQuery) »")
                            .foregroundStyle(.secondary)
                            .padding(40)
                    }
                }
                .searchable(text: $query, prompt: "Rechercher un film, une série…")
                .onChange(of: query) { _, newValue in
                    Task { await model.search(query: newValue, addons: repo.addons) }
                }
            }
        }
    }
}
