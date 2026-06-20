import SwiftUI

/// Aiguille entre l'écran de connexion et l'app principale selon l'état de session.
/// Au lancement, tente de restaurer une session via l'authKey du Keychain.
struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            if let testURL = Self.testPlaybackURL {
                // Chemin de test : lance directement le lecteur sur une URL donnée.
                PlayerView(url: testURL).ignoresSafeArea()
            } else if let screen = Self.testScreen {
                // Chemin de test : affiche un écran isolé (avec données réelles).
                NavigationStack { testScreenView(screen) }
            } else {
                switch session.status {
                case .working:
                    splash
                case .loggedOut:
                    LoginView()
                case .loggedIn, .guest:
                    MainTabView()
                }
            }
        }
        .task {
            if let key = Self.testAuthKey {
                await session.bootstrap(authKey: key)
            } else if ProcessInfo.processInfo.arguments.contains("-uitestGuest") {
                session.continueAsGuest()
            } else {
                await session.restore()
            }
        }
    }

    @ViewBuilder
    private func testScreenView(_ screen: String) -> some View {
        switch screen {
        case "detail":
            MetaDetailView(preview: Self.demoPreview)
        case "detailSeries":
            MetaDetailView(preview: MetaPreview(
                id: "tt14452776", type: "series", name: "The Bear",
                poster: "https://images.metahub.space/poster/medium/tt14452776/img",
                posterShape: nil, background: nil, description: nil))
        case "streams":
            StreamsListView(metaId: "tt0111161", type: "movie", videoId: "tt0111161",
                            title: "The Shawshank Redemption", name: "The Shawshank Redemption",
                            poster: nil, resumeOffsetMs: 0)
        case "library":
            LibraryView()
        case "tracks":
            TrackSelectionView(controller: Self.mockTracks, onClose: {})
        case "settings":
            SettingsView()
        case "grid":
            CatalogGridView(title: "Top · Cinemeta",
                            base: "https://v3-cinemeta.strem.io",
                            type: "movie", catalogId: "top")
        default:
            EmptyView()
        }
    }

    private var splash: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.tv.fill").font(.system(size: 80))
            Text("StremioTV").font(.largeTitle.bold())
            ProgressView()
        }
    }

    // MARK: - Hooks de test (pilotés par arguments de lancement)

    /// `-uitestPlay <url>` : lance le lecteur sur une URL.
    private static var testPlaybackURL: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uitestPlay"), index + 1 < args.count else {
            return nil
        }
        return URL(string: args[index + 1])
    }

    /// `-uitestScreen <detail|detailSeries|streams|library|settings|grid>`.
    private static var testScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uitestScreen"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    /// `-uitestAuthKey <key>` : connecte la session avec un authKey fourni.
    private static var testAuthKey: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uitestAuthKey"), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    @MainActor private static var mockTracks: TrackController {
        let controller = TrackController()
        controller.audioOptions = [
            AudioOption(id: 0, label: "Français"),
            AudioOption(id: 1, label: "English"),
            AudioOption(id: 2, label: "日本語"),
        ]
        controller.currentAudioId = 0
        controller.subtitleOptions = [
            SubtitleOption(id: "off", language: "OFF", source: "", kind: .off),
            SubtitleOption(id: "emb0", language: "English", source: "Intégré", kind: .embedded(0)),
            SubtitleOption(id: "ext0", language: "Français", source: "OpenSubtitles", kind: .external(URL(string: "https://x/fr1.srt")!)),
            SubtitleOption(id: "ext1", language: "Français", source: "OpenSubtitles", kind: .external(URL(string: "https://x/fr2.srt")!)),
            SubtitleOption(id: "ext2", language: "English", source: "OpenSubtitles", kind: .external(URL(string: "https://x/en1.srt")!)),
        ]
        controller.currentSubtitleId = "ext0"
        return controller
    }

    private static let demoPreview = MetaPreview(
        id: "tt0111161", type: "movie", name: "The Shawshank Redemption",
        poster: "https://images.metahub.space/poster/medium/tt0111161/img",
        posterShape: nil, background: nil, description: nil
    )
}
