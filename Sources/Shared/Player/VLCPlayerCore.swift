import UIKit
import SwiftUI
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

/// Cœur de lecture VLC **partagé** (tvOS + iOS).
///
/// Encapsule tout ce qui est indépendant de la plateforme : le player libVLC,
/// la reprise à la position sauvegardée, les pistes audio (doublage) et
/// sous-titres (embarqués + externes), l'application des préférences persistées
/// et la remontée throttlée de progression.
///
/// Les sous-classes fournissent uniquement l'**habillage des contrôles** :
/// - tvOS : télécommande (`pressesBegan`) + overlay statique ;
/// - iOS : gestes tactiles + barre de lecture (scrubber, boutons).
///
/// L'import VLCKit est conditionnel : `TVVLCKit` sur tvOS, `MobileVLCKit` sur
/// iOS. Les deux exposent une API `VLCMediaPlayer` identique.
class VLCPlayerCoreController: UIViewController, VLCMediaPlayerDelegate {
    private(set) var currentRequest: PlaybackRequest
    private let resolveNext: (String) async -> PlaybackRequest?
    private let onProgress: (String, UInt64, UInt64) -> Void
    let onClose: () -> Void
    private let prefs = PlaybackPreferences()

    // Options libVLC d'init :
    // - taille des sous-titres depuis les réglages (défaut ~65 %) ;
    // - `--no-mouse-events` : sinon la vout iOS installe son propre
    //   UITapGestureRecognizer sur la superview du drawable (notre vue racine)
    //   dès la première image rendue, qui gagne l'arbitrage des gestes et
    //   avale tous les taps — impossible de réafficher les contrôles.
    let player = VLCMediaPlayer(options: [
        "--sub-text-scale=\(PlaybackPreferences().subtitleScale)",
        "--no-mouse-events",
    ])
    let videoView = UIView()
    let spinner = UIActivityIndicatorView(style: .large)
    let trackController = TrackController()

    private var didResume = false
    private(set) var hasRenderedFirstFrame = false
    private var didApplyPrefs = false
    private var lastReportedMs: UInt64 = 0
    /// Lumières Hue (Ambilight) de la lecture en cours ; nil si désactivées ou non configurées.
    private var ambilight: AmbilightSession?

    init(request: PlaybackRequest,
         resolveNext: @escaping (String) async -> PlaybackRequest?,
         onProgress: @escaping (String, UInt64, UInt64) -> Void,
         onClose: @escaping () -> Void) {
        self.currentRequest = request
        self.resolveNext = resolveNext
        self.onProgress = onProgress
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supporté") }

    // MARK: - Cycle de vie

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideo()
        setupControls()
        loadAndPlay(currentRequest)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        reportProgress()
        stopAmbilight()
        player.stop()
    }

    private func setupVideo() {
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.backgroundColor = .black
        view.addSubview(videoView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        player.drawable = videoView
        player.delegate = self
    }

    // MARK: - Hooks à surcharger par la plateforme

    /// Construit l'overlay de contrôles (télécommande sur tvOS, tactile sur iOS).
    func setupControls() {}

    /// Appelé à chaque tick de temps : la sous-classe met à jour scrubber/labels.
    func onTimeUpdate(currentMs: UInt64, durationMs: UInt64, position: Float) {}

    /// Appelé une fois la première image rendue (spinner masqué).
    func onRenderedFirstFrame() {}

    /// Appelé quand l'état lecture/pause change (mise à jour de l'icône ⏯).
    func onPlaybackStateChanged(isPlaying: Bool) {}

    /// Appelé au chargement d'une nouvelle requête (titre, bouton « suivant »…).
    func onLoadNewRequest(_ request: PlaybackRequest) {}

    /// Présente le panneau de sélection des pistes (habillage propre à la plateforme).
    func presentTracks(_ controller: TrackController) {}

    // MARK: - Intentions (déclenchées par les contrôles de la sous-classe)

    /// Charge et lit une requête (épisode courant ou suivant).
    func loadAndPlay(_ request: PlaybackRequest) {
        stopAmbilight()
        currentRequest = request
        didResume = false
        hasRenderedFirstFrame = false
        didApplyPrefs = false
        lastReportedMs = 0
        onLoadNewRequest(request)
        let media = VLCMedia(url: request.url)
        media.addOption(":network-caching=1500")
        player.media = media
        player.play()
        spinner.startAnimating()
    }

    func togglePlayPause() {
        if player.isPlaying {
            player.pause()
            reportProgress()
        } else {
            player.play()
        }
        onPlaybackStateChanged(isPlaying: player.isPlaying)
    }

    func skipBackward(_ seconds: Int32 = 15) { player.jumpBackward(seconds) }
    func skipForward(_ seconds: Int32 = 15) { player.jumpForward(seconds) }

    /// Positionne la lecture à un ratio 0…1 (scrubber tactile).
    func seek(toPosition position: Float) {
        player.position = max(0, min(1, position))
    }

    var isPlaying: Bool { player.isPlaying }

    /// Y a-t-il un épisode après l'épisode courant dans la liste fournie ?
    var hasNextEpisode: Bool {
        guard let index = currentRequest.episodeIds.firstIndex(of: currentRequest.videoId) else { return false }
        return index + 1 < currentRequest.episodeIds.count
    }

    /// Passe à l'épisode suivant en réutilisant le même provider.
    func goNext() {
        reportProgress()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let next = await self.resolveNext(self.currentRequest.videoId) {
                self.loadAndPlay(next)
            }
        }
    }

    func openTrackMenu() {
        buildTracks()
        presentTracks(trackController)
    }

    func closePlayer() {
        reportProgress()
        stopAmbilight()
        player.stop()
        onClose()
    }

    // MARK: - Menu pistes (audio / sous-titres)

    /// Construit la liste des pistes (audio + sous-titres intégrés + externes)
    /// et câble les actions VLC, avant d'ouvrir le panneau.
    func buildTracks() {
        let trackLanguage = trackLanguages()

        let audioNames = (player.audioTrackNames as? [String]) ?? []
        let audioIndexes = (player.audioTrackIndexes as? [NSNumber]) ?? []
        trackController.audioOptions = zip(audioNames, audioIndexes).enumerated().map { offset, pair in
            let id = pair.1.int32Value
            let label = trackLanguage[id].map(LanguageNames.display) ?? trackLabel(pair.0, index: offset)
            return AudioOption(id: id, label: label)
        }
        trackController.currentAudioId = player.currentAudioTrackIndex

        var subtitles: [SubtitleOption] = [SubtitleOption(id: "off", language: "OFF", source: "", kind: .off)]
        let subNames = (player.videoSubTitlesNames as? [String]) ?? []
        let subIndexes = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        for (offset, pair) in zip(subNames, subIndexes).enumerated() where pair.1.int32Value >= 0 {
            let id = pair.1.int32Value
            let language = trackLanguage[id].map(LanguageNames.display)
            subtitles.append(SubtitleOption(
                id: "emb\(id)",
                language: language ?? "Intégrés",
                source: language == nil ? "Piste \(offset + 1)" : "Intégré",
                kind: .embedded(id)
            ))
        }
        for (index, subtitle) in currentRequest.subtitles.enumerated() {
            guard let url = URL(string: subtitle.url) else { continue }
            subtitles.append(SubtitleOption(
                id: "ext\(index)",
                language: subtitle.displayLanguage,
                source: "OpenSubtitles",
                kind: .external(url)
            ))
        }
        trackController.subtitleOptions = subtitles
        trackController.currentSubtitleId = player.currentVideoSubTitleIndex == -1
            ? "off" : "emb\(player.currentVideoSubTitleIndex)"
        trackController.subtitleDelayMs = Int(player.currentVideoSubTitleDelay / 1000)

        trackController.selectAudio = { [weak self] index in
            guard let self else { return }
            self.player.currentAudioTrackIndex = index
            self.prefs.audioLanguage = self.trackController.audioOptions.first { $0.id == index }?.label
        }
        trackController.selectSubtitle = { [weak self] option in
            guard let self else { return }
            switch option.kind {
            case .off: self.player.currentVideoSubTitleIndex = -1
            case .embedded(let index): self.player.currentVideoSubTitleIndex = index
            case .external(let url): self.player.addPlaybackSlave(url, type: .subtitle, enforce: true)
            }
            self.prefs.subtitleLanguage = option.language
        }
        trackController.setDelay = { [weak self] milliseconds in
            self?.player.currentVideoSubTitleDelay = milliseconds * 1000
        }
    }

    /// Langue réelle de chaque piste (id → langue) via les métadonnées du média.
    private func trackLanguages() -> [Int32: String] {
        var map: [Int32: String] = [:]
        for info in (player.media?.tracksInformation as? [[String: Any]]) ?? [] {
            guard let id = (info[VLCMediaTracksInformationId] as? NSNumber)?.int32Value,
                  let lang = info[VLCMediaTracksInformationLanguage] as? String,
                  !lang.isEmpty else { continue }
            map[id] = lang
        }
        return map
    }

    /// Réapplique la langue audio / sous-titres préférée (persistée) une fois la
    /// lecture démarrée.
    private func applyPreferredTracks() {
        let langs = trackLanguages()
        if let preferred = prefs.audioLanguage {
            let indexes = (player.audioTrackIndexes as? [NSNumber]) ?? []
            if let match = indexes.first(where: { langs[$0.int32Value].map(LanguageNames.display) == preferred }) {
                player.currentAudioTrackIndex = match.int32Value
            }
        }
        guard let preferred = prefs.subtitleLanguage else { return }
        if preferred == "OFF" {
            player.currentVideoSubTitleIndex = -1
            return
        }
        let indexes = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        if let match = indexes.first(where: { $0.int32Value >= 0 && langs[$0.int32Value].map(LanguageNames.display) == preferred }) {
            player.currentVideoSubTitleIndex = match.int32Value
        } else if let external = currentRequest.subtitles.first(where: { $0.displayLanguage == preferred }),
                  let url = URL(string: external.url) {
            player.addPlaybackSlave(url, type: .subtitle, enforce: true)
        }
    }

    private func isGenericName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.lowercased().hasPrefix("track")
    }

    private func trackLabel(_ name: String, index: Int) -> String {
        isGenericName(name) ? "Piste \(index + 1)" : LanguageNames.display(name)
    }

    // MARK: - Progression

    var currentMs: UInt64 { UInt64(max(0, player.time.intValue)) }
    var durationMs: UInt64 { UInt64(max(0, player.media?.length.intValue ?? 0)) }

    func reportProgress() {
        let time = currentMs
        guard time > 0 else { return }
        lastReportedMs = time
        onProgress(currentRequest.videoId, time, durationMs)
    }

    /// Formatage `h:mm:ss` / `mm:ss` d'une durée en millisecondes.
    func format(ms: UInt64) -> String {
        let totalSeconds = Int(ms / 1000)
        let h = totalSeconds / 3600, m = (totalSeconds % 3600) / 60, s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .buffering, .opening:
            if !hasRenderedFirstFrame { spinner.startAnimating() }
        case .playing:
            if !didResume, currentRequest.resumeOffsetMs > 0 {
                didResume = true
                player.time = VLCTime(int: Int32(min(currentRequest.resumeOffsetMs, UInt64(Int32.max))))
            }
            if !didApplyPrefs {
                didApplyPrefs = true
                applyPreferredTracks()
            }
            ambilight?.resume()
            onPlaybackStateChanged(isPlaying: true)
        case .paused:
            ambilight?.pause()
            onPlaybackStateChanged(isPlaying: false)
        case .error:
            stopAmbilight()
            spinner.stopAnimating(); showError()
        case .ended:
            stopAmbilight()
            spinner.stopAnimating(); reportProgress(); goNext()
        case .stopped:
            stopAmbilight()
            spinner.stopAnimating(); reportProgress()
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if currentMs > 0, !hasRenderedFirstFrame {
            hasRenderedFirstFrame = true
            spinner.stopAnimating()
            onRenderedFirstFrame()
            // Lumières Hue : démarrées à la 1re image rendue (pas de capture du spinner).
            if ambilight == nil {
                ambilight = HueSyncService.shared.makeSession(videoView: videoView, player: player)
                ambilight?.start()
            }
        }
        onTimeUpdate(currentMs: currentMs, durationMs: durationMs, position: player.position)
        if currentMs > lastReportedMs + 20_000 {
            reportProgress()
        }
    }

    /// Arrête les lumières Hue de la lecture (libère la zone). Sans effet sur la vidéo.
    private func stopAmbilight() {
        ambilight?.stop()
        ambilight = nil
    }

    /// Alerte d'échec de lecture (surchargée au besoin). Ferme le lecteur sur OK.
    func showError() {
        let alert = UIAlertController(
            title: "Lecture impossible",
            message: "Ce flux n'a pas pu être lu. Essaie une autre source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.onClose() })
        present(alert, animated: true)
    }
}
