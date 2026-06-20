import SwiftUI

/// Navigation principale par onglets (tvOS) : Accueil, Recherche, Réglages.
struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Accueil", systemImage: "house.fill") }
            LibraryView()
                .tabItem { Label("Bibliothèque", systemImage: "rectangle.stack.fill") }
            SearchView()
                .tabItem { Label("Recherche", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
        }
    }
}
