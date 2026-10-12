import SwiftUI

/// Réglages : compte Stremio, lecture (taille des sous-titres), lumières Hue, add-ons
/// (compte + manuels, suppression par balayage) et ajout manuel.
struct SettingsScreen: View {
    @Environment(AddonRepository.self) private var repo
    @Environment(SessionStore.self) private var session
    @Environment(HueSyncService.self) private var hue
    @State private var newURL = ""
    @State private var subtitleScale = PlaybackPreferences().subtitleScale

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                playbackSection
                hueSection
                addonsSection
                addManualSection
                tipSection
            }
            .navigationTitle("Réglages")
        }
    }

    // MARK: - Compte

    @ViewBuilder private var accountSection: some View {
        Section("Compte") {
            if session.status == .loggedIn {
                if let email = session.user?.email {
                    Label(email, systemImage: "person.crop.circle")
                }
                Button {
                    Task { await session.refreshAddons() }
                } label: {
                    Label("Rafraîchir les add-ons", systemImage: "arrow.clockwise")
                }
                Button(role: .destructive) {
                    Task { await session.logout() }
                } label: {
                    Label("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Label("Mode invité (Cinemeta)", systemImage: "person.crop.circle.badge.questionmark")
                Button {
                    session.requestLogin()
                } label: {
                    Label("Se connecter à Stremio", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
    }

    // MARK: - Lecture

    private var playbackSection: some View {
        Section("Lecture") {
            Stepper(value: $subtitleScale, in: 20...200, step: 5) {
                HStack {
                    Label("Taille des sous-titres", systemImage: "captions.bubble")
                    Spacer()
                    Text("\(subtitleScale) %").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .onChange(of: subtitleScale) { _, newValue in
                PlaybackPreferences().subtitleScale = newValue
            }
        }
    }

    // MARK: - Lumières Hue

    private var hueSection: some View {
        Section("Lumières Hue") {
            NavigationLink {
                HueSettingsScreen()
            } label: {
                HStack {
                    Label("Lumières Hue (Ambilight)", systemImage: "lightbulb.led.wide")
                    Spacer()
                    Text(hue.status.settingsBadge(isEnabled: hue.isPlaybackSyncEnabled,
                                                   hasSelectedArea: hue.hasSelectedArea))
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(hue.status.settingsBadgeColor(isEnabled: hue.isPlaybackSyncEnabled,
                                                                  hasSelectedArea: hue.hasSelectedArea).opacity(0.3), in: Capsule())
                }
            }
        }
    }

    // MARK: - Add-ons

    private var addonsSection: some View {
        Section("Add-ons (\(repo.addons.count))") {
            ForEach(repo.addons) { addon in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(addon.name)
                        Text(addon.base)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    sourceBadge(addon.source)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        repo.remove(addon)
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var addManualSection: some View {
        Section("Ajouter un add-on manuellement") {
            TextField("https://…/manifest.json", text: $newURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Ajouter") {
                repo.addManual(newURL)
                newURL = ""
            }
            .disabled(AddonClient.normalizeBase(newURL).isEmpty)
        }
    }

    private var tipSection: some View {
        Section {
            Text("Connecte ton compte Stremio pour récupérer automatiquement ton add-on RealDebrid. Ses flux sont des URLs HTTPS directes, lues nativement par VLCKit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceBadge(_ source: InstalledAddon.Source) -> some View {
        let label: String
        switch source {
        case .account: label = "compte"
        case .manual: label = "manuel"
        case .builtin: label = "défaut"
        }
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.gray.opacity(0.3), in: Capsule())
    }
}
