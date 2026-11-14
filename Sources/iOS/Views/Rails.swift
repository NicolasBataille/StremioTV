import SwiftUI

/// Une rangée de catalogue : titre, lien « Tout voir » (grille paginée) et
/// défilement horizontal de posters.
struct CatalogRail: View {
    let section: HomeViewModel.CatalogSection
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(section.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                NavigationLink {
                    CatalogGridScreen(
                        title: section.title,
                        base: section.base,
                        type: section.type,
                        catalogId: section.catalogId
                    )
                } label: {
                    HStack(spacing: 3) {
                        Text("Tout voir")
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.brand)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: sizeClass == .regular ? 18 : 12) {
                    ForEach(section.metas) { meta in
                        NavigationLink {
                            DetailScreen(preview: meta)
                        } label: {
                            PosterCardIOS(meta: meta)
                                .frame(width: PosterMetrics.railWidth(sizeClass))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Rangée « Continuer à regarder » : items en cours avec progression.
struct ContinueWatchingRail: View {
    let items: [LibraryItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continuer à regarder")
                .font(.headline)
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: sizeClass == .regular ? 18 : 12) {
                    ForEach(items) { item in
                        NavigationLink {
                            DetailScreen(preview: item.asPreview())
                        } label: {
                            PosterCardIOS(
                                meta: item.asPreview(),
                                progress: item.progress,
                                caption: episodeCaption(item)
                            )
                            .frame(width: PosterMetrics.railWidth(sizeClass))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Pour une série, affiche « SxEy » à partir de `state.video_id` (ex: tt123:1:5).
    private func episodeCaption(_ item: LibraryItem) -> String? {
        guard item.type == "series", let videoId = item.state.videoId else { return nil }
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1]),
              (1...99).contains(season), (1...9999).contains(episode) else { return nil }
        return "S\(season)E\(episode)"
    }
}
