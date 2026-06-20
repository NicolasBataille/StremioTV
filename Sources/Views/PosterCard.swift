import SwiftUI

/// Carte poster d'un item. Grille épurée façon Apple TV : le titre n'apparaît
/// que lorsque la carte est focalisée ; la barre de progression (Continuer à
/// regarder) reste toujours visible.
struct PosterCard: View {
    let meta: MetaPreview
    var progress: Double? = nil   // 0…1
    var caption: String? = nil    // sous-titre optionnel (ex: "S1E5")

    @Environment(\.isFocused) private var isFocused

    private let width: CGFloat = 240
    private let height: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            poster
            label
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
        .shadow(color: .black.opacity(0.45), radius: isFocused ? 18 : 8, y: isFocused ? 10 : 4)
    }

    /// Titre + sous-titre, visibles seulement quand la carte est focalisée.
    /// L'espace reste réservé pour éviter les sauts de mise en page.
    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meta.name ?? "").font(.caption.weight(.semibold)).lineLimit(1)
            Text(caption ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: width, height: 44, alignment: .topLeading)
        .opacity(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder private var progressBar: some View {
        if let progress, progress > 0 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.5))
                    Rectangle().fill(Color.brand).frame(width: geo.size.width * min(1, progress))
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
