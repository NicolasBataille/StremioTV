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

    @Environment(AddonRepository.self) private var repo
    @Environment(LibraryStore.self) private var library
    @State private var model = DetailViewModel()
    @State private var playback: PlaybackRequest?

    var body: some View {
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
        .navigationTitle(title)
        .task {
            let bases = repo.addons.map(\.base)
            await model.loadStreams(type: type, id: videoId, bases: bases)
            await model.loadSubtitles(type: type, id: videoId, addons: repo.addons)
        }
        .fullScreenCover(item: $playback) { request in
            PlayerView(
                request: request,
                onProgress: { offset, duration in
                    Task {
                        await library.recordProgress(
                            metaId: metaId, type: type, name: name, poster: poster,
                            videoId: videoId, timeOffsetMs: offset, durationMs: duration
                        )
                    }
                },
                onClose: { playback = nil }
            )
            .ignoresSafeArea()
        }
    }

    private func streamRow(_ stream: StreamItem) -> some View {
        Button {
            if let url = stream.playableURL {
                playback = PlaybackRequest(
                    url: url, metaId: metaId, type: type, name: name, poster: poster,
                    videoId: videoId, resumeOffsetMs: resumeOffsetMs, subtitles: model.subtitles
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
