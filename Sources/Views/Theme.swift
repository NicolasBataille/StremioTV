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

/// En-tête d'écran fixe (remplace `navigationTitle`, mal géré sur tvOS où il
/// flotte par-dessus le contenu).
struct ScreenHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 16)
    }
}

/// Conversion d'un code/nom de langue en libellé lisible (FR).
enum LanguageNames {
    private static let map: [String: String] = [
        "fr": "Français", "fre": "Français", "fra": "Français", "french": "Français",
        "en": "English", "eng": "English", "english": "English",
        "es": "Español", "spa": "Español", "spanish": "Español",
        "de": "Deutsch", "ger": "Deutsch", "deu": "Deutsch", "german": "Deutsch",
        "it": "Italiano", "ita": "Italiano", "italian": "Italiano",
        "pt": "Português", "por": "Português", "portuguese": "Português",
        "nl": "Nederlands", "dut": "Nederlands", "nld": "Nederlands",
        "ru": "Русский", "rus": "Русский", "russian": "Русский",
        "ar": "العربية", "ara": "العربية", "arabic": "العربية",
        "ja": "日本語", "jpn": "日本語", "japanese": "日本語",
        "ko": "한국어", "kor": "한국어", "korean": "한국어",
        "zh": "中文", "chi": "中文", "zho": "中文", "chinese": "中文",
    ]

    static func display(_ code: String) -> String {
        let key = code.lowercased().trimmingCharacters(in: .whitespaces)
        return map[key] ?? code.capitalized
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
