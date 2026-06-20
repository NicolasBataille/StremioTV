import SwiftUI
import TVVLCKit

/// Lecteur vidéo universel basé sur VLC (libvlc) : lit HLS, MP4, **MKV**, AVI…
/// Reprise à la position sauvegardée, choix audio (doublage) / sous-titres
/// (embarqués + externes OpenSubtitles), et remontée de progression.
struct PlayerView: UIViewControllerRepresentable {
    let request: PlaybackRequest
    var resolveNext: (_ currentVideoId: String) async -> PlaybackRequest? = { _ in nil }
    var onProgress: (_ videoId: String, _ timeOffsetMs: UInt64, _ durationMs: UInt64) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}

    init(request: PlaybackRequest,
         resolveNext: @escaping (String) async -> PlaybackRequest? = { _ in nil },
         onProgress: @escaping (String, UInt64, UInt64) -> Void = { _, _, _ in },
         onClose: @escaping () -> Void = {}) {
        self.request = request
        self.resolveNext = resolveNext
        self.onProgress = onProgress
        self.onClose = onClose
    }

    /// Lecture simple (chemins de test) sans contexte de progression.
    init(url: URL, onClose: @escaping () -> Void = {}) {
        self.init(
            request: PlaybackRequest(url: url, metaId: "", type: "movie",
                                     name: url.lastPathComponent, poster: nil,
                                     videoId: "", resumeOffsetMs: 0, subtitles: []),
            onClose: onClose
        )
    }

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        VLCPlayerViewController(request: request, resolveNext: resolveNext, onProgress: onProgress, onClose: onClose)
    }

    func updateUIViewController(_ controller: VLCPlayerViewController, context: Context) {}
}

final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    private var currentRequest: PlaybackRequest
    private let resolveNext: (String) async -> PlaybackRequest?
    private let onProgress: (String, UInt64, UInt64) -> Void
    private let onClose: () -> Void
    private let prefs = PlaybackPreferences()

    // Options libVLC d'init : réduit la taille des sous-titres (~70 % du défaut
    // VLC qui est trop gros). Les options média `:sub-text-scale` sont ignorées.
    private let player = VLCMediaPlayer(options: ["--sub-text-scale=70"])
    private let videoView = UIView()
    private let controls = UIView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var didResume = false
    private var hasRenderedFirstFrame = false
    private var didApplyPrefs = false
    private var lastReportedMs: UInt64 = 0
    private var controlsHideWorkItem: DispatchWorkItem?
    private let trackController = TrackController()

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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupVideo()
        setupControls()
        startPlayback()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        reportProgress()
        player.stop()
    }

    // MARK: - Setup

    private func setupVideo() {
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.backgroundColor = .black
        view.addSubview(videoView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        player.drawable = videoView
        player.delegate = self
    }

    private func setupControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        controls.layer.cornerRadius = 14
        view.addSubview(controls)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = currentRequest.name

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.text = currentRequest.episodeIds.count > 1
            ? "▲ pistes   ◀▶ ±15 s   ▼ épisode suivant   Menu : quitter"
            : "▲ pistes audio / sous-titres   ◀▶ ±15 s   Menu : quitter"

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progressTintColor = .white
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.3)

        for label in [currentTimeLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 28, weight: .regular)
            label.textColor = .white
            label.text = "00:00"
        }

        let timeStack = UIStackView(arrangedSubviews: [currentTimeLabel, progress, durationLabel])
        timeStack.translatesAutoresizingMaskIntoConstraints = false
        timeStack.axis = .horizontal
        timeStack.spacing = 24
        timeStack.alignment = .center

        controls.addSubview(titleLabel)
        controls.addSubview(timeStack)
        controls.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 80),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -80),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -60),

            titleLabel.topAnchor.constraint(equalTo: controls.topAnchor, constant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -32),

            timeStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            timeStack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 32),
            timeStack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -32),

            hintLabel.topAnchor.constraint(equalTo: timeStack.bottomAnchor, constant: 12),
            hintLabel.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 32),
            hintLabel.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -24),
        ])
    }

    private func startPlayback() {
        loadAndPlay(currentRequest)
    }

    /// Charge et lit une requête (épisode courant ou suivant), en réinitialisant
    /// l'état de reprise et l'application des préférences.
    private func loadAndPlay(_ request: PlaybackRequest) {
        currentRequest = request
        didResume = false
        hasRenderedFirstFrame = false
        didApplyPrefs = false
        lastReportedMs = 0
        titleLabel.text = request.name
        let media = VLCMedia(url: request.url)
        media.addOption(":network-caching=1500")
        player.media = media
        player.play()
        spinner.startAnimating()
        showControls(autoHide: true)
    }

    /// Passe à l'épisode suivant en réutilisant le même provider.
    private func goNext() {
        reportProgress()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let next = await self.resolveNext(self.currentRequest.videoId) {
                self.loadAndPlay(next)
            }
        }
    }

    // MARK: - Télécommande

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = true
        for press in presses {
            switch press.type {
            case .playPause, .select:
                togglePlayPause()
            case .leftArrow:
                player.jumpBackward(15); showControls(autoHide: true)
            case .rightArrow:
                player.jumpForward(15); showControls(autoHide: true)
            case .upArrow:
                showTrackMenu()
            case .downArrow:
                goNext()
            case .menu:
                reportProgress()
                player.stop()
                onClose()
            default:
                handled = false
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private func togglePlayPause() {
        if player.isPlaying { player.pause(); reportProgress() } else { player.play() }
        showControls(autoHide: true)
    }

    // MARK: - Menu pistes (audio / sous-titres)

    private func showTrackMenu() {
        buildTracks()
        let panel = TrackSelectionView(controller: trackController) { [weak self] in
            self?.dismiss(animated: true)
        }
        let host = UIHostingController(rootView: panel)
        host.modalPresentationStyle = .overFullScreen
        host.view.backgroundColor = .clear
        present(host, animated: true)
    }

    /// Construit la liste des pistes (audio + sous-titres intégrés + externes)
    /// et câble les actions VLC, avant d'ouvrir le panneau.
    private func buildTracks() {
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
            // Langue réelle si dispo, sinon regroupé sous « Intégrés ».
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
            // Mémorise la langue choisie (persistée entre épisodes/sessions).
            self.prefs.audioLanguage = self.trackController.audioOptions.first { $0.id == index }?.label
        }
        trackController.selectSubtitle = { [weak self] option in
            guard let self else { return }
            switch option.kind {
            case .off: self.player.currentVideoSubTitleIndex = -1
            case .embedded(let index): self.player.currentVideoSubTitleIndex = index
            case .external(let url): self.player.addPlaybackSlave(url, type: .subtitle, enforce: true)
            }
            self.prefs.subtitleLanguage = option.language   // "OFF" pour l'option désactivée
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

    /// Réapplique la langue audio / sous-titres préférée (persistée) sur la piste
    /// correspondante, une fois la lecture démarrée.
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

    /// Libellé d'une piste : la langue si VLC la fournit, sinon « Piste N ».
    private func trackLabel(_ name: String, index: Int) -> String {
        isGenericName(name) ? "Piste \(index + 1)" : LanguageNames.display(name)
    }

    // MARK: - Overlay

    private func showControls(autoHide: Bool) {
        controlsHideWorkItem?.cancel()
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        guard autoHide else { return }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.controls.alpha = 0 }
        }
        controlsHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    // MARK: - Progression

    private var currentMs: UInt64 { UInt64(max(0, player.time.intValue)) }
    private var durationMs: UInt64 { UInt64(max(0, player.media?.length.intValue ?? 0)) }

    private func reportProgress() {
        let time = currentMs
        guard time > 0 else { return }
        lastReportedMs = time
        onProgress(currentRequest.videoId, time, durationMs)
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .buffering, .opening:
            // Spinner uniquement avant la 1re image (pas de re-buffering visible
            // par-dessus une lecture déjà lancée).
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
        case .error:
            spinner.stopAnimating(); showError()
        case .ended:
            spinner.stopAnimating(); reportProgress(); goNext() // enchaîne l'épisode suivant
        case .stopped:
            spinner.stopAnimating(); reportProgress()
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Dès que le temps avance, l'image est rendue : on masque le spinner
        // définitivement.
        if currentMs > 0, !hasRenderedFirstFrame {
            hasRenderedFirstFrame = true
            spinner.stopAnimating()
        }
        progress.setProgress(player.position, animated: false)
        currentTimeLabel.text = format(ms: currentMs)
        if durationMs > 0 { durationLabel.text = format(ms: durationMs) }

        // Remontée throttlée toutes les ~20 s.
        if currentMs > lastReportedMs + 20_000 {
            reportProgress()
        }
    }

    private func showError() {
        let alert = UIAlertController(
            title: "Lecture impossible",
            message: "Ce flux n'a pas pu être lu. Essaie une autre source.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.onClose() })
        present(alert, animated: true)
    }

    private func format(ms: UInt64) -> String {
        let totalSeconds = Int(ms / 1000)
        let h = totalSeconds / 3600, m = (totalSeconds % 3600) / 60, s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
