import SwiftUI

/// Bannière « héros » en tête d'accueil : grand backdrop de l'item vedette,
/// titre et métadonnées. La bannière entière est focusable (style carte) et
/// ouvre la fiche détaillée.
struct HeroBanner: View {
    let preview: MetaPreview
    let bases: [String]

    @State private var detail: MetaDetail?

    private var backdrop: String? { detail?.background ?? preview.background ?? preview.poster }

    var body: some View {
        NavigationLink {
            MetaDetailView(preview: preview)
        } label: {
            BackdropImage(urlString: backdrop)
                .frame(maxWidth: .infinity)
                .frame(height: 460)
                .clipped()
                .overlay { BackdropScrim() }
                .overlay(alignment: .bottomLeading) { caption.padding(60) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.card)
        .task {
            detail = try? await AddonClient().meta(
                base: bases.first ?? "", type: preview.type ?? "movie", id: preview.id
            )
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detail?.name ?? preview.name ?? "")
                .font(.system(size: 56, weight: .bold))
                .lineLimit(1)
            metaLine
        }
    }

    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 18) {
            if let year = detail?.releaseInfo { Text(year) }
            if let rating = detail?.imdbRating, !rating.isEmpty {
                Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
            }
            if let genres = detail?.genres?.prefix(2).joined(separator: " · ") {
                Text(genres)
            }
            Label("Voir", systemImage: "play.fill").foregroundStyle(.white)
        }
        .font(.headline)
        .foregroundStyle(.white.opacity(0.85))
    }
}
