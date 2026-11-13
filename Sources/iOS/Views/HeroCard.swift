import SwiftUI

/// Bannière « héros » en tête d'accueil : grand backdrop de l'item vedette,
/// titre et métadonnées, ouvre la fiche au tap.
struct HeroCard: View {
    let preview: MetaPreview
    let bases: [String]

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var detail: MetaDetail?

    /// Plus haute sur iPad (largeur régulière) pour garder un vrai format « héros ».
    private var maxHeight: CGFloat { sizeClass == .regular ? 420 : 260 }

    private var backdrop: String? { detail?.background ?? preview.background ?? preview.poster }

    var body: some View {
        NavigationLink {
            DetailScreen(preview: preview)
        } label: {
            BackdropImage(urlString: backdrop)
                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: maxHeight)
                .clipped()
                .overlay { BackdropScrim() }
                .overlay(alignment: .bottomLeading) { caption.padding(20) }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
        }
        .buttonStyle(.plain)
        .task(id: preview.id) {
            guard detail?.id != preview.id else { return }
            detail = try? await AddonClient().meta(
                base: bases.first ?? "", type: preview.type ?? "movie", id: preview.id
            )
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail?.name ?? preview.name ?? "")
                .font(sizeClass == .regular ? .largeTitle.bold() : .title.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(radius: 6)
            HStack(spacing: 12) {
                if let year = detail?.releaseInfo { Text(year) }
                if let rating = detail?.imdbRating, !rating.isEmpty {
                    Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
                }
                Label("Voir", systemImage: "play.fill")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.9))
        }
    }
}
