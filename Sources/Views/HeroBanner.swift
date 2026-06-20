import SwiftUI

/// Bannière « héros » en tête d'accueil : grand backdrop de l'item vedette,
/// titre, synopsis court et bouton « Voir ».
struct HeroBanner: View {
    let preview: MetaPreview
    let bases: [String]

    @State private var detail: MetaDetail?

    private var backdrop: String? { detail?.background ?? preview.background ?? preview.poster }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BackdropImage(urlString: backdrop)
            BackdropScrim()
            VStack(alignment: .leading, spacing: 14) {
                Text(preview.name ?? "")
                    .font(.system(size: 60, weight: .bold))
                    .lineLimit(1)
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
                .padding(.top, 6)
            }
            .padding(60)
        }
        .frame(height: 560)
        .clipped()
        .task {
            detail = try? await AddonClient().meta(
                base: bases.first ?? "", type: preview.type ?? "movie", id: preview.id
            )
        }
    }
}
