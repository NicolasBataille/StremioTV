import SwiftUI

/// Fiche détaillée d'un film/série : synopsis, bibliothèque, reprise de lecture
/// et accès aux sources (directement pour un film, par épisode pour une série).
struct MetaDetailView: View {
    let preview: MetaPreview

    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    @State private var model = DetailViewModel()

    private var type: String { preview.type ?? "movie" }
    private var detail: MetaDetail { model.meta ?? MetaDetail(from: preview) }
    private var savedItem: LibraryItem? { library.item(for: preview.id) }
    private var posterURL: String? { detail.poster ?? preview.poster }
    private var displayName: String { detail.name ?? preview.name ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                Text(displayName).font(.largeTitle.bold())
                metaLine
                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                }
                sources
            }
            .padding(60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(background)
        .task { await model.loadMeta(preview: preview, bases: repo.addons.map(\.base)) }
    }

    private var metaLine: some View {
        HStack(spacing: 24) {
            if let release = detail.releaseInfo { Text(release) }
            if let rating = detail.imdbRating { Label(rating, systemImage: "star.fill") }
            if let genres = detail.genres?.prefix(3).joined(separator: ", ") { Text(genres) }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }

    // MARK: - Sources

    @ViewBuilder private var sources: some View {
        if type == "series" {
            VStack(alignment: .leading, spacing: 24) {
                libraryButton
                episodeList
            }
        } else {
            HStack(spacing: 24) {
                NavigationLink {
                    streamsView(videoId: preview.id, title: displayName, resumeMs: movieResumeMs)
                } label: {
                    Label(movieResumeMs > 0 ? "Reprendre" : "Voir les sources",
                          systemImage: "play.rectangle.fill").font(.title3)
                }
                .buttonStyle(.borderedProminent)
                libraryButton
            }
        }
    }

    private var libraryButton: some View {
        let saved = library.isSaved(preview.id)
        return Button {
            Task {
                await library.setSaved(
                    metaId: preview.id, type: type, name: displayName,
                    poster: posterURL, saved: !saved
                )
            }
        } label: {
            Label(saved ? "Dans la bibliothèque" : "Ajouter à la bibliothèque",
                  systemImage: saved ? "checkmark.circle.fill" : "plus.circle")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var episodeList: some View {
        if model.isLoadingMeta {
            ProgressView()
        } else if let videos = detail.videos, !videos.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Épisodes").font(.title2.bold())
                ForEach(videos) { video in
                    NavigationLink {
                        streamsView(videoId: video.id, title: video.displayTitle,
                                    resumeMs: episodeResumeMs(video))
                    } label: {
                        episodeRow(video)
                    }
                }
            }
        } else {
            Text("Aucun épisode listé.").foregroundStyle(.secondary)
        }
    }

    private func episodeRow(_ video: MetaVideo) -> some View {
        HStack {
            Image(systemName: isCurrentEpisode(video) ? "play.circle.fill" : "play.circle")
            Text(video.displayTitle).lineLimit(1)
            Spacer()
            if let progress = episodeProgress(video) {
                Text("\(Int(progress * 100)) %").foregroundStyle(.tint)
            } else if let released = video.released?.prefix(10) {
                Text(String(released)).foregroundStyle(.secondary)
            }
        }
    }

    private func streamsView(videoId: String, title: String, resumeMs: UInt64) -> some View {
        StreamsListView(
            metaId: preview.id, type: type, videoId: videoId, title: title,
            name: displayName, poster: posterURL, resumeOffsetMs: resumeMs
        )
    }

    // MARK: - Reprise

    private var movieResumeMs: UInt64 {
        guard type != "series", let state = savedItem?.state, state.timeOffset > 0 else { return 0 }
        return state.timeOffset
    }

    private func isCurrentEpisode(_ video: MetaVideo) -> Bool {
        savedItem?.state.videoId == video.id && (savedItem?.state.timeOffset ?? 0) > 0
    }

    private func episodeResumeMs(_ video: MetaVideo) -> UInt64 {
        isCurrentEpisode(video) ? (savedItem?.state.timeOffset ?? 0) : 0
    }

    private func episodeProgress(_ video: MetaVideo) -> Double? {
        guard isCurrentEpisode(video), let state = savedItem?.state, state.duration > 0 else { return nil }
        return min(1, Double(state.timeOffset) / Double(state.duration))
    }

    @ViewBuilder private var background: some View {
        if let background = detail.background, let url = URL(string: background) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.black
            }
            .ignoresSafeArea()
            .overlay(Color.black.opacity(0.65))
            .blur(radius: 6)
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}
