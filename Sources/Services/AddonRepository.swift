import Foundation
import Observation

/// Source de vérité des add-ons disponibles.
/// Combine les add-ons du compte Stremio (prioritaires) et les ajouts manuels,
/// avec un repli sur Cinemeta tant qu'aucun compte n'est connecté.
/// Persistance dans `UserDefaults` ; mises à jour immuables.
@Observable
final class AddonRepository {
    private(set) var addons: [InstalledAddon] = []

    private let defaults: UserDefaults
    private let accountKey = "stremio.addons.account"
    private let manualKey = "stremio.addons.manual"

    static let cinemeta = InstalledAddon(
        transportUrl: "https://v3-cinemeta.strem.io/manifest.json",
        name: "Cinemeta", manifest: nil, source: .builtin
    )

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recombine()
    }

    /// Remplace l'ensemble des add-ons issus du compte.
    func setAccountAddons(_ apiAddons: [APIAddon]) {
        let mapped = apiAddons.map { addon in
            InstalledAddon(
                transportUrl: addon.transportUrl,
                name: addon.manifest?.name ?? "Add-on",
                manifest: addon.manifest,
                source: .account
            )
        }
        save(mapped, key: accountKey)
        recombine()
    }

    func clearAccountAddons() {
        defaults.removeObject(forKey: accountKey)
        recombine()
    }

    func addManual(_ rawURL: String) {
        let base = AddonClient.normalizeBase(rawURL)
        guard !base.isEmpty else { return }
        var manual = load(key: manualKey)
        let candidate = InstalledAddon(
            transportUrl: base + "/manifest.json",
            name: "Add-on (manuel)", manifest: nil, source: .manual
        )
        guard !manual.contains(where: { $0.base == candidate.base }) else { return }
        manual.append(candidate)
        save(manual, key: manualKey)
        recombine()
    }

    func remove(_ addon: InstalledAddon) {
        for key in [accountKey, manualKey] {
            let filtered = load(key: key).filter { $0.base != addon.base }
            save(filtered, key: key)
        }
        recombine()
    }

    // MARK: - Combinaison & persistance

    private func recombine() {
        let account = load(key: accountKey)
        let manual = load(key: manualKey)
        var combined = account.isEmpty ? [Self.cinemeta] : account
        for addon in manual where !combined.contains(where: { $0.base == addon.base }) {
            combined.append(addon)
        }
        addons = combined
    }

    private func load(key: String) -> [InstalledAddon] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([InstalledAddon].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save(_ addons: [InstalledAddon], key: String) {
        guard let data = try? JSONEncoder().encode(addons) else { return }
        defaults.set(data, forKey: key)
    }
}
