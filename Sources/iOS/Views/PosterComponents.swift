import SwiftUI

/// Carte poster tactile (iOS). Titre toujours visible sous l'affiche, barre de
/// progression optionnelle (Continuer à regarder), légende optionnelle (SxEy).
struct PosterCardIOS: View {
    let meta: MetaPreview
    var progress: Double? = nil
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            poster
            Text(meta.name ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var poster: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                AsyncImage(url: URL(string: meta.poster ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        ProgressView()
                    default:
                        Image(systemName: "film")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottom) { progressBar }
            .shadow(color: .black.opacity(0.35), radius: 5, y: 3)
    }

    @ViewBuilder private var progressBar: some View {
        if let progress, progress > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.5))
                    Rectangle().fill(Color.brand).frame(width: geo.size.width * min(1, progress))
                }
            }
            .frame(height: 4)
            .clipShape(Capsule())
            .padding(6)
        }
    }
}

/// Grille adaptative de posters (Recherche, Bibliothèque, Catalogue complet).
/// `onReachEnd` permet la pagination (chargement progressif).
struct PosterGrid: View {
    let metas: [MetaPreview]
    var progressFor: (MetaPreview) -> Double? = { _ in nil }
    var onReachEnd: () -> Void = {}

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 20)]
            : [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 14)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: sizeClass == .regular ? 26 : 18) {
            ForEach(metas) { meta in
                NavigationLink {
                    DetailScreen(preview: meta)
                } label: {
                    PosterCardIOS(meta: meta, progress: progressFor(meta))
                }
                .buttonStyle(.plain)
                .onAppear {
                    if meta.id == metas.last?.id { onReachEnd() }
                }
            }
        }
        .padding(.horizontal)
    }
}

/// Tailles de posters selon la classe de taille horizontale :
/// compacte (iPhone, iPad en Split View étroit) vs régulière (iPad plein écran).
enum PosterMetrics {
    static func railWidth(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 150 : 118
    }
}
