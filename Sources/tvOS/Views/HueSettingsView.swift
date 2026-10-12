import SwiftUI

/// Réglages « Lumières Hue (Ambilight) » (Apple TV, focus / télécommande) :
/// état de la synchronisation, appairage du pont, choix de la zone de
/// divertissement et réglages des couleurs. Pas de Slider/Stepper sur tvOS :
/// boutons −/+ et boutons de choix, comme la section « Lecture » des réglages.
struct HueSettingsView: View {
    @Environment(HueSyncService.self) private var hue

    @State private var manualHost = ""
    @State private var pairingStartedAt: Date?
    @State private var isTesting = false
    @State private var isConfirmingUnpair = false
    @State private var selectedAreaID = HuePreferences().selectedAreaID

    // Valeurs affichées, initialisées depuis les préférences et réécrites à chaque changement.
    @State private var isEnabled = HuePreferences().isEnabled
    @State private var brightnessPercent = Int((HuePreferences().brightness * 100).rounded())
    @State private var saturationPercent = Int((HuePreferences().saturationBoost * 100).rounded())
    @State private var latencyMs = HuePreferences().latencyMs
    @State private var responsiveness = HuePreferences().responsiveness
    @State private var captureMethod = HuePreferences().captureMethod

    /// Durée maximale d'attente de l'appui sur le bouton du pont (cf. `HueBridgeClient.pair`).
    private let pairingTimeout: TimeInterval = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "Lumières Hue")
            List {
                statusSection
                bridgeSection
                if hue.isPaired {
                    areaSection
                    tuningSection
                    testSection
                    unpairSection
                }
                noteSection
            }
        }
        .confirmationDialog("Dissocier le pont Hue ?", isPresented: $isConfirmingUnpair, titleVisibility: .visible) {
            Button("Dissocier", role: .destructive) {
                hue.unpair()
                selectedAreaID = nil
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Il faudra de nouveau appuyer sur le bouton du pont pour l'associer.")
        }
        .onAppear(perform: loadPreferences)
        .task {
            if hue.isPaired {
                if hue.areas.isEmpty { await hue.refreshAreas() }
            } else if hue.discoveredBridges.isEmpty && !hue.isDiscovering {
                await hue.discover()
            }
        }
        .onChange(of: hue.areas) { _, _ in syncSelectedArea() }
        .onChange(of: hue.isPaired) { _, _ in syncSelectedArea() }
        .onChange(of: hue.isPairing) { _, pairing in
            if !pairing { pairingStartedAt = nil }
        }
    }

    // MARK: - État

    private var statusSection: some View {
        Section("État") {
            Label(hue.status.settingsSummary(isEnabled: isEnabled, hasSelectedArea: selectedAreaID != nil),
                  systemImage: hue.status.settingsSymbol(isEnabled: isEnabled, hasSelectedArea: selectedAreaID != nil))
            if let diagnostics = hue.diagnostics {
                Text(diagnostics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let error = hue.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Pont

    @ViewBuilder private var bridgeSection: some View {
        Section("Pont Hue") {
            if let credentials = hue.credentials {
                Label(credentials.host, systemImage: "network")
                Text("Identifiant : \(credentials.bridgeID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hue.isPairing {
                pairingProgress
            } else {
                Button {
                    Task { await hue.discover() }
                } label: {
                    HStack {
                        Label("Rechercher le pont", systemImage: "magnifyingglass")
                        if hue.isDiscovering {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(hue.isDiscovering)
                ForEach(hue.discoveredBridges) { bridge in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bridge.host)
                            Text(bridge.id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("Associer") { startPairing(host: bridge.host) }
                    }
                }
                if !hue.isDiscovering && hue.discoveredBridges.isEmpty {
                    Text("Aucun pont trouvé pour l'instant. Vérifie que l'Apple TV et le pont sont sur le même réseau, ou saisis son adresse IP ci-dessous.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if !hue.isPaired && !hue.isPairing {
            Section("Adresse IP manuelle") {
                TextField("192.168.1.20", text: $manualHost)
                    .autocorrectionDisabled()
                Button("Associer") { startPairing(host: trimmedManualHost) }
                    .disabled(trimmedManualHost.isEmpty)
            }
        }
    }

    /// Attente de l'appui sur le bouton du pont, avec compte à rebours.
    private var pairingProgress: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 20) {
                ProgressView()
                Text("Appuie sur le gros bouton rond du pont Hue, puis patiente")
            }
            if let start = pairingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let remaining = max(0, Int((pairingTimeout - context.date.timeIntervalSince(start)).rounded(.up)))
                    Text("Encore \(remaining) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button(role: .cancel) {
                hue.cancelPairing()
                pairingStartedAt = nil
            } label: {
                Label("Annuler", systemImage: "xmark")
            }
        }
    }

    private var trimmedManualHost: String {
        manualHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startPairing(host: String) {
        guard !host.isEmpty, !hue.isPairing else { return }
        pairingStartedAt = Date()
        Task {
            await hue.pair(host: host)
            pairingStartedAt = nil
            syncSelectedArea()
        }
    }

    // MARK: - Zone de divertissement

    @ViewBuilder private var areaSection: some View {
        Section("Zone de divertissement") {
            ForEach(hue.areas) { area in
                Button {
                    hue.selectArea(area)
                    selectedAreaID = area.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(area.name)
                            Text("\(HueAreaTypeLabel.label(for: area.configurationType)) · \(area.channels.count) canaux")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if area.isStreaming {
                            Text("en cours d'utilisation")
                                .font(.caption2)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(.orange.opacity(0.3), in: Capsule())
                        }
                        if area.id == selectedAreaID {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if hue.areas.isEmpty {
                Text("Aucune zone de divertissement. Crée-la dans l'app Hue (Réglages › Zones de divertissement), en plaçant tes lampes autour de la TV.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    await hue.refreshAreas()
                    syncSelectedArea()
                }
            } label: {
                Label("Rafraîchir", systemImage: "arrow.clockwise")
            }
        }
    }

    private func syncSelectedArea() {
        selectedAreaID = hue.selectedArea?.id ?? hue.preferences.selectedAreaID
    }

    // MARK: - Réglages

    private var tuningSection: some View {
        Section("Réglages") {
            Toggle(isOn: $isEnabled) {
                Label("Activer pendant la lecture", systemImage: "lightbulb.led.wide")
            }
            .onChange(of: isEnabled) { _, newValue in
                hue.setPlaybackSyncEnabled(newValue)
            }
            adjustRow("Luminosité", systemImage: "sun.max", value: "\(brightnessPercent) %",
                      decrease: { adjustBrightness(-10) }, increase: { adjustBrightness(+10) })
            adjustRow("Saturation", systemImage: "drop.halffull", value: "\(saturationPercent) %",
                      decrease: { adjustSaturation(-10) }, increase: { adjustSaturation(+10) })
            choiceRow("Réactivité", systemImage: "speedometer",
                      options: HueResponsiveness.allCases, selected: responsiveness,
                      label: { $0.label }) { option in
                responsiveness = option
                hue.preferences.responsiveness = option
            }
            adjustRow("Retard des lumières", systemImage: "timer", value: "\(latencyMs) ms",
                      decrease: { adjustLatency(-25) }, increase: { adjustLatency(+25) })
            choiceRow("Méthode de capture", systemImage: "camera.viewfinder",
                      options: HueCaptureMethod.allCases, selected: captureMethod,
                      label: { $0.label }) { option in
                captureMethod = option
                hue.preferences.captureMethod = option
            }
        }
    }

    /// Ligne « libellé … − valeur + » (même rendu que la taille des sous-titres).
    private func adjustRow(_ title: String, systemImage: String, value: String,
                           decrease: @escaping () -> Void,
                           increase: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Button(action: decrease) { Image(systemName: "minus") }
                .buttonStyle(.borderedProminent).tint(Color(white: 0.3))
            Text(value).monospacedDigit().frame(width: 150)
            Button(action: increase) { Image(systemName: "plus") }
                .buttonStyle(.borderedProminent).tint(Color(white: 0.3))
        }
    }

    /// Ligne de choix exclusif : un bouton par option, l'option active est cochée.
    private func choiceRow<Option: Identifiable & Equatable>(
        _ title: String,
        systemImage: String,
        options: [Option],
        selected: Option,
        label: @escaping (Option) -> String,
        onSelect: @escaping (Option) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
            HStack(spacing: 20) {
                ForEach(options) { option in
                    Button {
                        onSelect(option)
                    } label: {
                        HStack(spacing: 8) {
                            if option == selected { Image(systemName: "checkmark") }
                            Text(label(option))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(option == selected ? Color.accentColor : Color(white: 0.3))
                }
            }
        }
    }

    private func adjustBrightness(_ delta: Int) {
        brightnessPercent = max(10, min(100, brightnessPercent + delta))
        hue.preferences.brightness = Double(brightnessPercent) / 100
    }

    private func adjustSaturation(_ delta: Int) {
        saturationPercent = max(100, min(160, saturationPercent + delta))
        hue.preferences.saturationBoost = Double(saturationPercent) / 100
    }

    private func adjustLatency(_ delta: Int) {
        latencyMs = max(0, min(600, latencyMs + delta))
        hue.preferences.latencyMs = latencyMs
    }

    private func loadPreferences() {
        let preferences = hue.preferences
        isEnabled = preferences.isEnabled
        brightnessPercent = Int((preferences.brightness * 100).rounded())
        saturationPercent = Int((preferences.saturationBoost * 100).rounded())
        latencyMs = preferences.latencyMs
        responsiveness = preferences.responsiveness
        captureMethod = preferences.captureMethod
        syncSelectedArea()
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            Button {
                isTesting = true
                Task {
                    await hue.testLights()
                    isTesting = false
                }
            } label: {
                HStack {
                    Label("Tester les lumières", systemImage: "lightbulb.2")
                    if isTesting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(selectedAreaID == nil || hue.areas.isEmpty || isTesting)
        } footer: {
            Text("Fait défiler rouge, vert, bleu puis blanc sur chaque lampe de la zone (environ 6 s).")
        }
    }

    // MARK: - Dissociation

    /// En fin d'écran : à l'ouverture, tvOS donne le focus au premier élément
    /// focalisable, qui ne doit pas être une action destructive.
    private var unpairSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingUnpair = true
            } label: {
                Label("Dissocier le pont", systemImage: "trash")
            }
        }
    }

    // MARK: - Note

    private var noteSection: some View {
        Section {
            Text("Fonctionne uniquement pendant la lecture dans StremioTV (pas Netflix ni les autres apps). Si l'app Hue Sync de ta télé diffuse déjà sur la même zone, arrête-la avant de lancer une vidéo.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Libellés partagés avec SettingsView

extension HueSyncService.Status {
    /// Phrase d'état complète (écran « Lumières Hue »).
    var settingsSummary: String {
        switch self {
        case .notConfigured: return "Aucun pont Hue associé"
        case .ready: return "Prêt : les lumières suivront la prochaine vidéo"
        case .connecting: return "Connexion au pont…"
        case .streaming(let captureName): return "Synchronisation en cours (\(captureName))"
        case .error(let message): return message
        }
    }

    /// Badge court (liste des réglages).
    var settingsBadge: String {
        switch self {
        case .notConfigured: return "non configuré"
        case .ready: return "prêt"
        case .connecting: return "connexion…"
        case .streaming: return "actif"
        case .error: return "erreur"
        }
    }

    var settingsSymbol: String {
        switch self {
        case .notConfigured: return "lightbulb.slash"
        case .ready: return "lightbulb"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .streaming: return "lightbulb.max"
        case .error: return "exclamationmark.triangle"
        }
    }

    var settingsBadgeColor: Color {
        switch self {
        case .streaming: return .green
        case .error: return .orange
        case .ready, .connecting: return .blue
        case .notConfigured: return .gray
        }
    }

    // `.ready` signifie seulement « pont associé » : `makeSession` ne démarre rien si la
    // synchronisation est désactivée ou si aucune zone n'est choisie. Les variantes
    // ci-dessous le précisent (mêmes conditions que `makeSession`).

    /// Associé mais la prochaine lecture ne pilotera pas les lumières.
    private func isIdleButInactive(isEnabled: Bool, hasSelectedArea: Bool) -> Bool {
        self == .ready && (!isEnabled || !hasSelectedArea)
    }

    func settingsSummary(isEnabled: Bool, hasSelectedArea: Bool) -> String {
        guard self == .ready else { return settingsSummary }
        if !isEnabled { return "Désactivé : les lumières ne suivront pas la lecture" }
        if !hasSelectedArea { return "Aucune zone de divertissement choisie" }
        return settingsSummary
    }

    func settingsBadge(isEnabled: Bool, hasSelectedArea: Bool) -> String {
        guard self == .ready else { return settingsBadge }
        if !isEnabled { return "désactivé" }
        if !hasSelectedArea { return "aucune zone" }
        return settingsBadge
    }

    func settingsSymbol(isEnabled: Bool, hasSelectedArea: Bool) -> String {
        isIdleButInactive(isEnabled: isEnabled, hasSelectedArea: hasSelectedArea) ? "lightbulb.slash" : settingsSymbol
    }

    func settingsBadgeColor(isEnabled: Bool, hasSelectedArea: Bool) -> Color {
        guard self == .ready else { return settingsBadgeColor }
        if !isEnabled { return .gray }
        if !hasSelectedArea { return .orange }
        return settingsBadgeColor
    }
}

/// Libellé lisible du type d'une zone de divertissement (`configuration_type` CLIP v2).
enum HueAreaTypeLabel {
    static func label(for configurationType: String) -> String {
        switch configurationType {
        case "screen": return "Écran TV"
        case "monitor": return "Moniteur"
        case "music": return "Musique"
        case "3dspace": return "Espace 3D"
        default: return "Autre"
        }
    }
}
