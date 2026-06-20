import SwiftUI

/// Point d'entrée de l'app tvOS.
/// `SessionStore` (auth + add-ons) et son `AddonRepository` sont injectés
/// dans l'environnement via le pattern Observation (tvOS 17+).
@main
struct StremioTVApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.repository)
                .environment(session.library)
                .tint(.brand)
                .preferredColorScheme(.dark)
        }
    }
}
