import SwiftUI

/// Catalogue complet en grille, avec chargement progressif (pagination `skip`).
struct CatalogGridView: View {
    let title: String
    let base: String
    let type: String
    let catalogId: String

    @State private var model = CatalogGridViewModel()

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 40)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: title)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(model.metas) { meta in
                        NavigationLink {
                            MetaDetailView(preview: meta)
                        } label: {
                            PosterCard(meta: meta)
                        }
                        .buttonStyle(.card)
                        .onAppear {
                            if meta.id == model.metas.last?.id {
                                Task { await model.loadMore(base: base, type: type, catalogId: catalogId) }
                            }
                        }
                    }
                }
                .padding(60)

                if model.isLoading {
                    ProgressView().padding(40)
                }
            }
        }
        .task {
            await model.loadFirstPage(base: base, type: type, catalogId: catalogId)
        }
    }
}
