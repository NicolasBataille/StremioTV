import SwiftUI

/// Point d'entrée de l'app **iOS** (iPhone + iPad).
/// `SessionStore` (auth + add-ons), son `AddonRepository` et la `LibraryStore`
/// sont injectés dans l'environnement (pattern Observation, iOS 17+), ainsi que
/// `HueSyncService` (lumières Hue), dont les sessions sont suspendues quand l'app
/// passe en arrière-plan (la zone de divertissement est libérée).
@main
struct StremioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = SessionStore()
    @State private var downloads = DownloadStore.shared
    @State private var network = NetworkMonitor()

    init() {
        // Instancie la session de téléchargement d'arrière-plan dès le lancement
        // pour que le système puisse re-livrer les événements de transfert.
        _ = DownloadStore.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.repository)
                .environment(session.library)
                .environment(downloads)
                .environment(network)
                .environment(HueSyncService.shared)
                .tint(.brand)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: HueSyncService.shared.suspendActiveSession()
                    case .active: HueSyncService.shared.resumeSuspendedSession()
                    default: break
                    }
                }
        }
    }
}
