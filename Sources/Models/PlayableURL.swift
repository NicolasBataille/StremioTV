import Foundation

/// Petit wrapper `Identifiable` pour présenter le lecteur via
/// `.fullScreenCover(item:)` (URL n'est pas Identifiable).
struct PlayableURL: Identifiable {
    let id = UUID()
    let url: URL
}
