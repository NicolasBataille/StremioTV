import SwiftUI

/// Liste des flux d'un item. Lance la lecture (reprise + sous-titres) et
/// enregistre la progression sur le compte à l'arrêt.
struct StreamsListView: View {
    let metaId: String
    let type: String
    let videoId: String        // épisode (= metaId pour un film)
    let title: String
    let name: String
    let poster: String?
    let resumeOffsetMs: UInt64
    var episodeIds: [String] = []

    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    @State private var model = DetailViewModel()
    @State private var playback: PlaybackRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: title)
            List {
                if model.isLoadingStreams {
                    HStack { ProgressView(); Text("Recherche de flux…") }
                }
                if let note = model.note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                if !model.subtitles.isEmpty {
                    Label("\(model.subtitles.count) sous-titres disponibles",
                          systemImage: "captions.bubble")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.streams) { stream in
                    streamRow(stream)
                }
            }
        }
        .task {
            let bases = repo.addons.map(\.base)
            await model.loadStreams(type: type, id: videoId, bases: bases)
            await model.loadSubtitles(type: type, id: videoId, addons: repo.addons)
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(
                request: request,
                resolveNext: { currentVideoId in
                    await resolveNextEpisode(after: currentVideoId, episodeIds: request.episodeIds, providerBase: request.providerBase)
                },
                onProgress: { playedVideoId, offset, duration in
                    Task {
                        await library.recordProgress(
                            metaId: metaId, type: type, name: name, poster: poster,
                            videoId: playedVideoId, timeOffsetMs: offset, durationMs: duration
                        )
                    }
                },
                onClose: { playback = nil }
            )
            .ignoresSafeArea()
        }
    }

    /// Résout l'épisode suivant en réutilisant **le même provider** (repli sur
    /// tous les add-ons sinon), avec ses sous-titres.
    private func resolveNextEpisode(after currentVideoId: String, episodeIds: [String], providerBase: String?) async -> PlaybackRequest? {
        guard let index = episodeIds.firstIndex(of: currentVideoId), index + 1 < episodeIds.count else { return nil }
        let nextId = episodeIds[index + 1]
        let client = AddonClient()

        var streams: [StreamItem] = []
        if let base = providerBase, let found = try? await client.streams(base: base, type: type, id: nextId) {
            streams = found.map { var s = $0; s.sourceBase = base; return s }
        }
        if !streams.contains(where: { $0.isDirectlyPlayable }) {
            for base in repo.addons.map(\.base) {
                if let found = try? await client.streams(base: base, type: type, id: nextId) {
                    streams += found.map { var s = $0; s.sourceBase = base; return s }
                }
            }
        }
        guard let chosen = streams.first(where: { $0.isDirectlyPlayable }), let url = chosen.playableURL else { return nil }

        await model.loadSubtitles(type: type, id: nextId, addons: repo.addons)
        return PlaybackRequest(
            url: url, metaId: metaId, type: type, name: name, poster: poster,
            videoId: nextId, resumeOffsetMs: 0, subtitles: model.subtitles,
            episodeIds: episodeIds, providerBase: chosen.sourceBase
        )
    }

    private func streamRow(_ stream: StreamItem) -> some View {
        Button {
            if let url = stream.playableURL {
                playback = PlaybackRequest(
                    url: url, metaId: metaId, type: type, name: name, poster: poster,
                    videoId: videoId, resumeOffsetMs: resumeOffsetMs, subtitles: model.subtitles,
                    episodeIds: episodeIds, providerBase: stream.sourceBase
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(stream.headline).font(.headline)
                if let subtitle = stream.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !stream.isDirectlyPlayable {
                    Label(
                        stream.isTorrent ? "Torrent — nécessite debrid/streaming-server" : "Format non lisible nativement",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(!stream.isDirectlyPlayable)
    }
}
