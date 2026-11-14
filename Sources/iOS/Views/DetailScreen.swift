import SwiftUI

/// Fiche détaillée d'un film/série : backdrop, poster, infos, bibliothèque,
/// reprise de lecture et accès aux sources (par épisode en série).
struct DetailScreen: View {
    let preview: MetaPreview

    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    @State private var model = DetailViewModel()
    @State private var selectedSeason: Int?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var isRegular: Bool { sizeClass == .regular }

    private var type: String { preview.type ?? "movie" }
    private var detail: MetaDetail { model.meta ?? MetaDetail(from: preview) }
    private var savedItem: LibraryItem? { library.item(for: preview.id) }
    private var posterURL: String? { detail.poster ?? preview.poster }
    private var displayName: String { detail.name ?? preview.name ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backdropHeader
                VStack(alignment: .leading, spacing: 20) {
                    header
                    actionButtons
                    if let description = detail.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if type == "series" { episodeSection }
                }
                // iPad : colonne de lecture centrée plutôt que des lignes
                // et boutons étirés sur toute la largeur de l'écran.
                .frame(maxWidth: isRegular ? 820 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, isRegular ? 32 : 16)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .ignoresSafeArea(edges: .top)
        .task {
            await model.loadMeta(preview: preview, bases: repo.addons.map(\.base))
            // Aligne la sélection du picker sur la saison réellement affichée
            // (sinon le menu n'a pas de coche à la 1re ouverture).
            if type == "series", selectedSeason == nil, !seasons.isEmpty {
                selectedSeason = effectiveSeason
            }
        }
    }

    // MARK: - En-tête

    private var backdropHeader: some View {
        BackdropImage(urlString: detail.background ?? posterURL)
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: isRegular ? 380 : 220)
            .clipped()
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.6), .black],
                               startPoint: .top, endPoint: .bottom)
            }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: URL(string: posterURL ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 10).fill(.gray.opacity(0.25))
            }
            .frame(width: isRegular ? 160 : 110, height: isRegular ? 240 : 165)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(radius: 8)
            .offset(y: -50)
            .padding(.bottom, -50)

            VStack(alignment: .leading, spacing: 8) {
                Text(displayName).font(.title2.bold())
                metaLine
            }
            Spacer(minLength: 0)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 12) {
            if let release = detail.releaseInfo { Text(release) }
            if let rating = detail.imdbRating, !rating.isEmpty {
                Label(rating, systemImage: "star.fill").foregroundStyle(.yellow)
            }
            if let genres = detail.genres?.prefix(2).joined(separator: " · ") { Text(genres) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 12) {
            if type == "series" {
                if let resume = seriesResumeTarget {
                    NavigationLink {
                        streamsView(videoId: resume.id, title: resume.displayTitle,
                                    resumeMs: savedItem?.state.timeOffset ?? 0)
                    } label: {
                        Label("Reprendre \(resume.displayTitle)", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                NavigationLink {
                    streamsView(videoId: preview.id, title: displayName, resumeMs: movieResumeMs)
                } label: {
                    Label(movieResumeMs > 0 ? "Reprendre" : "Voir les sources", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            libraryButton
        }
        .controlSize(.large)
    }

    private var libraryButton: some View {
        let saved = library.isSaved(preview.id)
        return Button {
            Task {
                await library.setSaved(metaId: preview.id, type: type, name: displayName,
                                       poster: posterURL, saved: !saved)
            }
        } label: {
            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3)
        }
        .buttonStyle(.bordered)
        .tint(saved ? .brand : .gray)
        .accessibilityLabel(saved ? "Retirer de la bibliothèque" : "Ajouter à la bibliothèque")
    }

    // MARK: - Épisodes

    @ViewBuilder private var episodeSection: some View {
        if model.isLoadingMeta && detail.videos == nil {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let videos = detail.videos, !videos.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Épisodes").font(.title3.bold())
                    Spacer()
                    if seasons.count > 1 { seasonMenu }
                }
                ForEach(displayedEpisodes) { video in
                    NavigationLink {
                        streamsView(videoId: video.id, title: video.displayTitle,
                                    resumeMs: episodeResumeMs(video))
                    } label: {
                        episodeRow(video)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Text("Aucun épisode listé.").foregroundStyle(.secondary)
        }
    }

    private var seasonMenu: some View {
        Menu {
            Picker("Saison", selection: $selectedSeason) {
                ForEach(seasons, id: \.self) { season in
                    Text(seasonLabel(season)).tag(Optional(season))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(seasonLabel(effectiveSeason))
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.brand)
        }
    }

    private func seasonLabel(_ season: Int) -> String {
        season == 0 ? "Spéciaux" : "Saison \(season)"
    }

    private var seasons: [Int] {
        Set((detail.videos ?? []).compactMap(\.season)).sorted()
    }

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
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: video.thumbnail ?? "")) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.gray.opacity(0.25))
                    .overlay(Image(systemName: "play.circle").foregroundStyle(.secondary))
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(video.displayTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                if let released = video.released?.prefix(10) {
                    Text(String(released)).font(.caption).foregroundStyle(.secondary)
                }
                if let progress = episodeProgress(video) {
                    ProgressView(value: progress).tint(.brand)
                }
            }
            Spacer(minLength: 0)
            if isCurrentEpisode(video) {
                Image(systemName: "play.circle.fill").foregroundStyle(Color.brand)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private func streamsView(videoId: String, title: String, resumeMs: UInt64) -> some View {
        StreamsScreen(
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
