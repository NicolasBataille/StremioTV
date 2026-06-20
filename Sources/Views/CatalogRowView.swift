import SwiftUI

/// Une rangée de catalogue : titre, lien « Tout voir » (grille paginée) et
/// défilement horizontal de posters.
struct CatalogRowView: View {
    let section: HomeViewModel.CatalogSection

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(section.title).font(.title3.bold())
                Spacer()
                NavigationLink {
                    CatalogGridView(
                        title: section.title,
                        base: section.base,
                        type: section.type,
                        catalogId: section.catalogId
                    )
                } label: {
                    Text("Tout voir")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 60)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 30) {
                    ForEach(section.metas) { meta in
                        NavigationLink {
                            MetaDetailView(preview: meta)
                        } label: {
                            PosterCard(meta: meta)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
        }
    }
}
