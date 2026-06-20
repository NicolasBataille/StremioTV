import Foundation

/// Préférences de lecture persistées : langue audio et sous-titres choisies.
/// Conservées entre les épisodes d'une série et entre les sessions (UserDefaults).
struct PlaybackPreferences {
    private let defaults: UserDefaults
    private let audioKey = "playback.audioLanguage"
    private let subtitleKey = "playback.subtitleLanguage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
