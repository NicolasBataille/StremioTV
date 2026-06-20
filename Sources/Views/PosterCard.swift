import SwiftUI

/// Carte poster d'un item (image + titre), avec barre de progression optionnelle.
struct PosterCard: View {
    let meta: MetaPreview
    var progress: Double? = nil   // 0…1 (Continuer à regarder)
    var caption: String? = nil    // sous-titre optionnel (ex: "S1E5")

    private let width: CGFloat = 240
    private let height: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            poster
            Text(meta.name ?? "")
                .font(.caption)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: .leading)
            }
        }
    }

    private var poster: some View {
        AsyncImage(url: URL(string: meta.poster ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                placeholder
            case .empty:
                placeholder.overlay(ProgressView())
            @unknown default:
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) { progressBar }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    @ViewBuilder private var progressBar: some View {
        if let progress, progress > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.5))
                    Rectangle().fill(.white)
                        .frame(width: geo.size.width * min(1, progress))
                }
            }
            .frame(height: 6)
            .clipShape(Capsule())
            .padding(8)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(.gray.opacity(0.25))
            .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
    }
}
