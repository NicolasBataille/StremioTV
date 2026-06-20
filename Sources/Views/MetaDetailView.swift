import SwiftUI

/// Fiche détaillée d'un film/série : backdrop cinématographique, poster, infos,
/// bibliothèque, reprise de lecture et accès aux sources (par épisode en série).
struct MetaDetailView: View {
    let preview: MetaPreview

    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    @State private var model = DetailViewModel()
    @State private var selectedSeason: Int?

    private var type: String { preview.type ?? "movie" }
    private var detail: MetaDetail { model.meta ?? MetaDetail(from: preview) }
    private var savedItem: LibraryItem? { library.item(for: preview.id) }
    private var posterURL: String? { detail.poster ?? preview.poster }
    private var displayName: String { detail.name ?? preview.name ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                heroHeader
                if type == "series" { episodeList }
            }
            .padding(60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            ZStack {
                BackdropImage(urlString: detail.background ?? posterURL)
                BackdropScrim()
            }
            .ignoresSafeArea()
        }
        .task { await model.loadMeta(preview: preview, bases: repo.addons.map(\.base)) }
    }

    // MARK: - En-tête (poster + infos)

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 44) {
            posterThumbnail
            VStack(alignment: .leading, spacing: 20) {
                Text(displayName).font(.system(size: 56, weight: .bold))
                metaLine
                if let description = detail.description, !description.isEmpty {
                    Text(description)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                actionButtons
            }
            Spacer(minLength: 0)
        }
    }

    private var posterThumbnail: some View {
        AsyncImage(url: URL(string: posterURL ?? "")) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 14).fill(.gray.opacity(0.25))
        }
        .frame(width: 260, height: 390)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 20)
    }

    private var metaLine: some View {
        HStack(spacing: 24) {
            if let release = detail.releaseInfo { Text(release) }
            if let rating = detail.imdbRating, !rating.isEmpty {
                Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
            }
            if let genres = detail.genres?.prefix(3).joined(separator: " · ") { Text(genres) }
        }
        .font(.headline)
        .foregroundStyle(.white.opacity(0.75))
    }

    // MARK: - Actions

    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 24) {
            if type == "series" {
                if let resume = seriesResumeTarget {
                    NavigationLink {
                        streamsView(videoId: resume.id, title: resume.displayTitle,
                                    resumeMs: savedItem?.state.timeOffset ?? 0)
                    } label: {
                        Label("Reprendre \(resume.displayTitle)", systemImage: "play.fill").font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                NavigationLink {
                    streamsView(videoId: preview.id, title: displayName, resumeMs: movieResumeMs)
                } label: {
                    Label(movieResumeMs > 0 ? "Reprendre" : "Voir les sources",
                          systemImage: "play.fill").font(.title3)
                }
                .buttonStyle(.borderedProminent)
            }
            libraryButton
        }
        .padding(.top, 8)
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
            Label(saved ? "Dans la bibliothèque" : "Ajouter",
                  systemImage: saved ? "checkmark.circle.fill" : "plus.circle")
        }
        // .borderedProminent garantit un label contrasté (blanc) ; un gris neutre
        // le distingue du bouton de lecture principal (accent).
        .buttonStyle(.borderedProminent)
        .tint(Color(white: 0.3))
    }

    // MARK: - Épisodes

    @ViewBuilder private var episodeList: some View {
        if model.isLoadingMeta {
            ProgressView()
        } else if let videos = detail.videos, !videos.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Épisodes").font(.title2.bold())
                if seasons.count > 1 { seasonPicker }
                ForEach(displayedEpisodes) { video in
                    NavigationLink {
                        streamsView(videoId: video.id, title: video.displayTitle,
                                    resumeMs: episodeResumeMs(video))
                    } label: {
                        episodeRow(video)
                    }
                    .buttonStyle(.card)
                }
            }
        } else {
            Text("Aucun épisode listé.").foregroundStyle(.secondary)
        }
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(seasons, id: \.self) { season in
                    Button {
                        selectedSeason = season
                    } label: {
                        Text(season == 0 ? "Spéciaux" : "Saison \(season)")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(season == effectiveSeason ? .brand : Color(white: 0.25))
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Saisons disponibles, triées (saison 0 = « Spéciaux » incluse).
    private var seasons: [Int] {
        Set((detail.videos ?? []).compactMap(\.season)).sorted()
    }

    /// Saison affichée : choix utilisateur, sinon celle de l'épisode en cours
    /// (y compris les spéciaux), sinon la 1re saison « normale » (≥ 1).
    private var effectiveSeason: Int {
        if let selectedSeason { return selectedSeason }
        if let videoId = savedItem?.state.videoId,
           let current = detail.videos?.first(where: { $0.id == videoId }),
           let season = current.season {
            return season
        }
        return seasons.first(where: { $0 > 0 }) ?? seasons.first ?? 1
    }

    private var displayedEpisodes: [MetaVideo] {
        guard !seasons.isEmpty else { return detail.videos ?? [] }
        return (detail.videos ?? []).filter { $0.season == effectiveSeason }
    }

    private func episodeRow(_ video: MetaVideo) -> some View {
        HStack(spacing: 20) {
            AsyncImage(url: URL(string: video.thumbnail ?? "")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.gray.opacity(0.25))
                    .overlay(Image(systemName: "play.circle").foregroundStyle(.secondary))
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(video.displayTitle).font(.headline).lineLimit(1)
                if let released = video.released?.prefix(10) {
                    Text(String(released)).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = episodeProgress(video) {
                    ProgressView(value: progress).tint(.brand).frame(width: 260)
                }
            }
            Spacer()
            if isCurrentEpisode(video) {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.brand)
            }
        }
        .padding(.vertical, 6)
    }

    private func streamsView(videoId: String, title: String, resumeMs: UInt64) -> some View {
        StreamsListView(
            metaId: preview.id, type: type, videoId: videoId, title: title,
            name: displayName, poster: posterURL, resumeOffsetMs: resumeMs,
            episodeIds: detail.videos?.map(\.id) ?? []
        )
    }

    // MARK: - Reprise

    private var movieResumeMs: UInt64 {
        guard type != "series", let state = savedItem?.state, state.timeOffset > 0 else { return 0 }
        return state.timeOffset
    }

    private var seriesResumeTarget: MetaVideo? {
        guard type == "series", let videoId = savedItem?.state.videoId,
              (savedItem?.state.timeOffset ?? 0) > 0 else { return nil }
        return detail.videos?.first { $0.id == videoId }
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
}
