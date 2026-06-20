import SwiftUI

/// Rangée « Continuer à regarder » : items en cours avec progression,
/// triés du plus récent au plus ancien.
struct ContinueWatchingRow: View {
    let items: [LibraryItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Continuer à regarder")
                .font(.title3.bold())
                .padding(.horizontal, 60)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 30) {
                    ForEach(items) { item in
                        NavigationLink {
                            MetaDetailView(preview: item.asPreview())
                        } label: {
                            PosterCard(
                                meta: item.asPreview(),
                                progress: item.progress,
                                caption: episodeCaption(item)
                            )
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 12)
            }
        }
    }

    /// Pour une série, affiche « SxEy » à partir de `state.video_id` (ex: tt123:1:5).
    /// Bornes de bon sens pour éviter les ids non standard (animes Kitsu/MAL…).
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
