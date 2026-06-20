import Foundation
import Observation

/// Une piste audio (doublage) sélectionnable.
struct AudioOption: Identifiable, Hashable {
    let id: Int32          // index VLC
    let label: String      // langue / nom
}

/// Une variante de sous-titre : intégrée au flux ou externe (OpenSubtitles…).
struct SubtitleOption: Identifiable, Hashable {
    enum Kind: Hashable {
        case off
        case embedded(Int32)   // index VLC
        case external(URL)     // URL de fichier SRT/VTT
    }

    let id: String
    let language: String       // clé de regroupement / affichage
    let source: String         // "Intégré", "OpenSubtitles"…
    let kind: Kind
}

/// État partagé entre le lecteur (UIKit/VLC) et le panneau de sélection (SwiftUI).
/// Le lecteur le remplit avant d'ouvrir le panneau et fournit les actions.
@Observable
@MainActor
final class TrackController {
    var audioOptions: [AudioOption] = []
    var subtitleOptions: [SubtitleOption] = []
    var currentAudioId: Int32 = -1
    var currentSubtitleId: String = "off"
    var subtitleDelayMs: Int = 0

    var selectAudio: (Int32) -> Void = { _ in }
    var selectSubtitle: (SubtitleOption) -> Void = { _ in }
    var setDelay: (Int) -> Void = { _ in }

    /// Langues de sous-titres uniques, dans l'ordre (OFF en premier).
    var subtitleLanguages: [String] {
        var seen = Set<String>()
        return subtitleOptions.compactMap { seen.insert($0.language).inserted ? $0.language : nil }
    }

    func variants(for language: String) -> [SubtitleOption] {
        subtitleOptions.filter { $0.language == language }
    }
}
