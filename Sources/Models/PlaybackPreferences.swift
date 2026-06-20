import Foundation

/// Préférences de lecture persistées : langue audio et sous-titres choisies.
/// Conservées entre les épisodes d'une série et entre les sessions (UserDefaults).
struct PlaybackPreferences {
    private let defaults: UserDefaults
    private let audioKey = "playback.audioLanguage"
    private let subtitleKey = "playback.subtitleLanguage"
    private let scaleKey = "playback.subtitleScale"

    static let defaultSubtitleScale = 65

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Taille des sous-titres en % (défaut 65). Persistée et appliquée à la
    /// création du lecteur.
    var subtitleScale: Int {
        get {
            let value = defaults.integer(forKey: scaleKey)
            return value == 0 ? Self.defaultSubtitleScale : value
        }
        nonmutating set {
            defaults.set(max(20, min(200, newValue)), forKey: scaleKey)
        }
    }

    var audioLanguage: String? {
        get { defaults.string(forKey: audioKey) }
        nonmutating set { defaults.set(newValue, forKey: audioKey) }
    }

    /// Langue de sous-titres préférée. La valeur `"OFF"` = désactivés volontairement.
    var subtitleLanguage: String? {
        get { defaults.string(forKey: subtitleKey) }
        nonmutating set { defaults.set(newValue, forKey: subtitleKey) }
    }
}
