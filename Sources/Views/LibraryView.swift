import SwiftUI

/// Onglet Bibliothèque : les items sauvegardés (favoris) du compte.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(SessionStore.self) private var session

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 40)]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ScreenHeader(title: "Bibliothèque")
                ScrollView {
                    if session.status != .loggedIn {
                        notLoggedIn
                    } else if library.library.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 40) {
                            ForEach(library.library) { item in
                                NavigationLink {
                                    MetaDetailView(preview: item.asPreview())
                                } label: {
                                    PosterCard(meta: item.asPreview(), progress: item.progress)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(60)
                    }
                }
            }
        }
    }

    private var notLoggedIn: some View {
        message(icon: "person.crop.circle.badge.questionmark",
                title: "Connecte-toi pour voir ta bibliothèque",
                detail: "Tes favoris et ta progression sont synchronisés avec ton compte Stremio.")
    }

    private var emptyState: some View {
        message(icon: "rectangle.stack.badge.plus",
                title: "Ta bibliothèque est vide",
                detail: "Ajoute des films et séries depuis leur fiche pour les retrouver ici.")
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 60))
            Text(title).font(.title3)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 800)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}
