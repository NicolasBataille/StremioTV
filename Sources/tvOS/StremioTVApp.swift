import SwiftUI

/// Point d'entrée de l'app tvOS.
/// `SessionStore` (auth + add-ons) et son `AddonRepository` sont injectés
/// dans l'environnement via le pattern Observation (tvOS 17+).
/// `HueSyncService` (lumières Hue) aussi ; ses sessions sont suspendues quand
/// l'app passe en arrière-plan (la zone de divertissement est libérée).
@main
struct StremioTVApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.repository)
                .environment(session.library)
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
