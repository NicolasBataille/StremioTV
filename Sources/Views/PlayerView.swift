import SwiftUI
import TVVLCKit

/// Lecteur vidéo universel basé sur VLC (libvlc) : lit HLS, MP4, **MKV**, AVI…
/// Reprise à la position sauvegardée, choix audio (doublage) / sous-titres
/// (embarqués + externes OpenSubtitles), et remontée de progression.
struct PlayerView: UIViewControllerRepresentable {
    let request: PlaybackRequest
    var onProgress: (_ timeOffsetMs: UInt64, _ durationMs: UInt64) -> Void = { _, _ in }
    var onClose: () -> Void = {}

    init(request: PlaybackRequest,
         onProgress: @escaping (UInt64, UInt64) -> Void = { _, _ in },
         onClose: @escaping () -> Void = {}) {
        self.request = request
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
        VLCPlayerViewController(request: request, onProgress: onProgress, onClose: onClose)
    }

    func updateUIViewController(_ controller: VLCPlayerViewController, context: Context) {}
}

final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    private let request: PlaybackRequest
    private let onProgress: (UInt64, UInt64) -> Void
    private let onClose: () -> Void

    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let controls = UIView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let currentTimeLabel = UILabel()
    private let durationLabel = UILabel()
    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var didResume = false
    private var lastReportedMs: UInt64 = 0
    private var controlsHideWorkItem: DispatchWorkItem?

    init(request: PlaybackRequest,
         onProgress: @escaping (UInt64, UInt64) -> Void,
         onClose: @escaping () -> Void) {
        self.request = request
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
        titleLabel.text = request.name

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.text = "▲ pistes audio / sous-titres   ◀▶ ±15 s   Menu : quitter"

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
        let media = VLCMedia(url: request.url)
        media.addOption(":network-caching=1500")
        player.media = media

        // Sous-titres externes (add-ons OpenSubtitles).
        for subtitle in request.subtitles {
            if let url = URL(string: subtitle.url) {
                player.addPlaybackSlave(url, type: .subtitle, enforce: false)
            }
        }

        player.play()
        showControls(autoHide: true)
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
        let menu = UIAlertController(title: "Pistes", message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "Audio (doublage)", style: .default) { _ in self.showAudioMenu() })
        menu.addAction(UIAlertAction(title: "Sous-titres", style: .default) { _ in self.showSubtitleMenu() })
        menu.addAction(UIAlertAction(title: "Fermer", style: .cancel))
        present(menu, animated: true)
    }

    private func showAudioMenu() {
        let sheet = UIAlertController(title: "Audio (doublage)", message: nil, preferredStyle: .actionSheet)
        let names = (player.audioTrackNames as? [String]) ?? []
        let indexes = (player.audioTrackIndexes as? [NSNumber]) ?? []
        for (name, index) in zip(names, indexes) {
            let check = player.currentAudioTrackIndex == index.int32Value ? " ✓" : ""
            sheet.addAction(UIAlertAction(title: name + check, style: .default) { _ in
                self.player.currentAudioTrackIndex = index.int32Value
            })
        }
        sheet.addAction(UIAlertAction(title: "Fermer", style: .cancel))
        present(sheet, animated: true)
    }

    private func showSubtitleMenu() {
        let sheet = UIAlertController(title: "Sous-titres", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Aucun" + (player.currentVideoSubTitleIndex == -1 ? " ✓" : ""),
                                      style: .default) { _ in self.player.currentVideoSubTitleIndex = -1 })
        let names = (player.videoSubTitlesNames as? [String]) ?? []
        let indexes = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        for (name, index) in zip(names, indexes) {
            let check = player.currentVideoSubTitleIndex == index.int32Value ? " ✓" : ""
            sheet.addAction(UIAlertAction(title: name + check, style: .default) { _ in
                self.player.currentVideoSubTitleIndex = index.int32Value
            })
        }
        sheet.addAction(UIAlertAction(title: "Fermer", style: .cancel))
        present(sheet, animated: true)
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
        onProgress(time, durationMs)
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .buffering, .opening:
            spinner.startAnimating()
        case .playing:
            spinner.stopAnimating()
            if !didResume, request.resumeOffsetMs > 0 {
                didResume = true
                player.time = VLCTime(int: Int32(min(request.resumeOffsetMs, UInt64(Int32.max))))
            }
        case .error:
            spinner.stopAnimating(); showError()
        case .ended, .stopped:
            spinner.stopAnimating(); reportProgress()
        default:
            spinner.stopAnimating()
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
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
