import Foundation

/// Réactivité des lumières : constante de temps du lissage appliqué aux couleurs.
enum HueResponsiveness: String, CaseIterable, Identifiable {
    case smooth, balanced, fast

    var id: String { rawValue }

    /// Constante de temps du lissage exponentiel, en secondes.
    var timeConstant: TimeInterval {
        switch self {
        case .smooth: return 0.35
        case .balanced: return 0.18
        case .fast: return 0.08
        }
    }

    var label: String {
        switch self {
        case .smooth: return "Douce"
        case .balanced: return "Équilibrée"
        case .fast: return "Rapide"
        }
    }
}

/// Méthode de capture de l'image vidéo pour l'Ambilight.
enum HueCaptureMethod: String, CaseIterable, Identifiable {
    /// Essaie la dernière méthode qui a fonctionné, puis la capture de la vue, puis les snapshots VLC.
    case automatic
    case view
    case vlcSnapshot

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .view: return "Capture de la vue"
        case .vlcSnapshot: return "Snapshot VLC"
        }
    }
}

/// Préférences persistées (UserDefaults, clés préfixées "hue.").
/// Les identifiants du pont, eux, vont dans le Keychain (`HueCredentialStore`).
struct HuePreferences {
    private let defaults: UserDefaults
    private let enabledKey = "hue.enabled"
    private let areaKey = "hue.selectedAreaID"
    private let brightnessKey = "hue.brightness"
    private let saturationKey = "hue.saturationBoost"
    private let latencyKey = "hue.latencyMs"
    private let responsivenessKey = "hue.responsiveness"
    private let captureKey = "hue.captureMethod"
    private let lastCaptureKey = "hue.lastWorkingCapture"

    static let defaultBrightness = 0.8
    static let brightnessRange: ClosedRange<Double> = 0.1...1.0
    static let defaultSaturationBoost = 1.2
    static let saturationBoostRange: ClosedRange<Double> = 1.0...1.6
    static let defaultLatencyMs = 0
    static let latencyRange: ClosedRange<Int> = 0...600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Synchronisation des lumières pendant la lecture (défaut : activée).
    var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Identifiant de la zone de divertissement choisie (`nil` = aucune).
    var selectedAreaID: String? {
        get {
            guard let value = defaults.string(forKey: areaKey), !value.isEmpty else { return nil }
            return value
        }
        nonmutating set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: areaKey)
            } else {
                defaults.removeObject(forKey: areaKey)
            }
        }
    }

    /// Luminosité des lumières, 0,1…1,0 (défaut 0,8).
    var brightness: Double {
        get { readDouble(brightnessKey, default: Self.defaultBrightness, range: Self.brightnessRange) }
        nonmutating set { writeDouble(newValue, brightnessKey, default: Self.defaultBrightness, range: Self.brightnessRange) }
    }

    /// Renforcement de la saturation, 1,0 (inchangée) … 1,6 (défaut 1,2).
    var saturationBoost: Double {
        get { readDouble(saturationKey, default: Self.defaultSaturationBoost, range: Self.saturationBoostRange) }
        nonmutating set {
            writeDouble(newValue, saturationKey, default: Self.defaultSaturationBoost, range: Self.saturationBoostRange)
        }
    }

    /// Retard volontaire des lumières en millisecondes, 0…600 (défaut 0), pour compenser
    /// la latence de l'image (barre de son, mode TV…).
    var latencyMs: Int {
        get {
            guard defaults.object(forKey: latencyKey) != nil else { return Self.defaultLatencyMs }
            return clamp(defaults.integer(forKey: latencyKey), to: Self.latencyRange)
        }
        nonmutating set { defaults.set(clamp(newValue, to: Self.latencyRange), forKey: latencyKey) }
    }

    /// Réactivité du lissage (défaut : équilibrée).
    var responsiveness: HueResponsiveness {
        get { defaults.string(forKey: responsivenessKey).flatMap(HueResponsiveness.init(rawValue:)) ?? .balanced }
        nonmutating set { defaults.set(newValue.rawValue, forKey: responsivenessKey) }
    }

    /// Méthode de capture choisie (défaut : automatique).
    var captureMethod: HueCaptureMethod {
        get { defaults.string(forKey: captureKey).flatMap(HueCaptureMethod.init(rawValue:)) ?? .automatic }
        nonmutating set { defaults.set(newValue.rawValue, forKey: captureKey) }
    }

    /// Dernière méthode de capture qui a fourni des images, mémorisée par la session
    /// (jamais `.automatic` : affecter `.automatic` ou `nil` efface la valeur).
    var lastWorkingCapture: HueCaptureMethod? {
        get {
            guard let method = defaults.string(forKey: lastCaptureKey).flatMap(HueCaptureMethod.init(rawValue:)),
                  method != .automatic
            else { return nil }
            return method
        }
        nonmutating set {
            if let newValue, newValue != .automatic {
                defaults.set(newValue.rawValue, forKey: lastCaptureKey)
            } else {
                defaults.removeObject(forKey: lastCaptureKey)
            }
        }
    }

    // MARK: - Privé

    private func readDouble(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let value = defaults.double(forKey: key)
        return value.isFinite ? clamp(value, to: range) : fallback
    }

    private func writeDouble(_ value: Double, _ key: String, default fallback: Double, range: ClosedRange<Double>) {
        defaults.set(value.isFinite ? clamp(value, to: range) : fallback, forKey: key)
    }

    private func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
