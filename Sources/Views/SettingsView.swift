import SwiftUI

/// Réglages : compte Stremio (connexion/déconnexion, rafraîchissement),
/// liste des add-ons (compte + manuels) et ajout manuel.
struct SettingsView: View {
    @Environment(AddonRepository.self) private var repo
    @Environment(SessionStore.self) private var session
    @State private var newURL = ""
    @State private var subtitleScale = PlaybackPreferences().subtitleScale

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Réglages")
                List {
                    accountSection
                    playbackSection
                    addonsSection
                    addManualSection
                    tipSection
                }
            }
        }
    }

    private var playbackSection: some View {
        Section("Lecture") {
            HStack {
                Label("Taille des sous-titres", systemImage: "captions.bubble")
                Spacer()
                Button { adjustSubtitleScale(-5) } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderedProminent).tint(Color(white: 0.3))
                Text("\(subtitleScale) %").monospacedDigit().frame(width: 110)
                Button { adjustSubtitleScale(+5) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderedProminent).tint(Color(white: 0.3))
            }
        }
    }

    private func adjustSubtitleScale(_ delta: Int) {
        subtitleScale = max(20, min(200, subtitleScale + delta))
        PlaybackPreferences().subtitleScale = subtitleScale
    }

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

    private var addonsSection: some View {
        Section("Add-ons (\(repo.addons.count))") {
            ForEach(repo.addons) { addon in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(addon.name)
                        Text(addon.base)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    sourceBadge(addon.source)
                    Button(role: .destructive) {
                        repo.remove(addon)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    private var addManualSection: some View {
        Section("Ajouter un add-on manuellement") {
            TextField("https://…/manifest.json", text: $newURL)
            Button("Ajouter") {
                repo.addManual(newURL)
                newURL = ""
            }
            .disabled(AddonClient.normalizeBase(newURL).isEmpty)
        }
    }

    private var tipSection: some View {
        Section {
            Text("Connecte ton compte Stremio pour récupérer automatiquement ton add-on RealDebrid. Ses flux sont des URLs HTTPS directes, lues nativement par l'Apple TV.")
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.gray.opacity(0.3), in: Capsule())
    }
}
