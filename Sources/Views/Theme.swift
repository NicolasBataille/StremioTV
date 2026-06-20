import SwiftUI

extension Color {
    /// Accent « Stremio » (violet).
    static let brand = Color(red: 0.55, green: 0.36, blue: 0.96)
}

/// Dégradé de lisibilité par-dessus une image de fond : sombre en bas et à
/// gauche, transparent vers le haut/droite — pour faire ressortir le texte.
struct BackdropScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.95), .black.opacity(0.25), .clear],
                startPoint: .bottom, endPoint: .top
            )
            LinearGradient(
                colors: [.black.opacity(0.85), .black.opacity(0.1), .clear],
                startPoint: .leading, endPoint: .trailing
            )
        }
    }
}

/// Image de fond plein cadre (backdrop), à défaut un fond noir.
struct BackdropImage: View {
    let urlString: String?

    var body: some View {
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
        } else {
            Color.black
        }
    }
}
