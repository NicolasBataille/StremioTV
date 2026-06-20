import SwiftUI

/// Bannière « héros » en tête d'accueil : grand backdrop de l'item vedette,
/// titre, métadonnées, synopsis court et bouton « Voir ».
struct HeroBanner: View {
    let preview: MetaPreview
    let bases: [String]

    @State private var detail: MetaDetail?

    private var backdrop: String? { detail?.background ?? preview.background ?? preview.poster }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BackdropImage(urlString: backdrop)
            BackdropScrim()
            VStack(alignment: .leading, spacing: 12) {
                Text(detail?.name ?? preview.name ?? "")
                    .font(.system(size: 56, weight: .bold))
                    .lineLimit(1)
                metaLine
                if let description = detail?.description, !description.isEmpty {
                    Text(description)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                NavigationLink {
                    MetaDetailView(preview: preview)
                } label: {
                    Label("Voir", systemImage: "play.fill").font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(60)
        }
        .frame(height: 520)
        .clipped()
        .task {
            detail = try? await AddonClient().meta(
                base: bases.first ?? "", type: preview.type ?? "movie", id: preview.id
            )
        }
    }

    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 18) {
            if let year = detail?.releaseInfo { Text(year) }
            if let rating = detail?.imdbRating {
                Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
            }
            if let genres = detail?.genres?.prefix(2).joined(separator: " · ") {
                Text(genres)
            }
        }
        .font(.headline)
        .foregroundStyle(.white.opacity(0.8))
    }
}
