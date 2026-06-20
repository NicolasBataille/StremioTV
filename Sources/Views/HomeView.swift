import SwiftUI

/// Écran d'accueil : une rangée horizontale par catalogue d'add-on.
struct HomeView: View {
    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    @State private var model = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 50) {
                    if let featured = model.sections.first?.metas.first {
                        HeroBanner(preview: featured, bases: repo.addons.map(\.base))
                    }
                    if !library.continueWatching.isEmpty {
                        ContinueWatchingRow(items: library.continueWatching)
                    }
                    content
                }
                .padding(.bottom, 40)
            }
            .task(id: repo.addons.map(\.id)) {
                await model.load(addons: repo.addons)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.sections.isEmpty {
            ProgressView("Chargement des catalogues…")
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        } else if let error = model.errorMessage, model.sections.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 60))
                Text("Impossible de charger les catalogues").font(.title3)
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
        } else {
            ForEach(model.sections) { section in
                CatalogRowView(section: section)
            }
        }
    }
}
