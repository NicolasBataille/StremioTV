import UIKit

// Prise d'image « Capture de la vue » de l'Ambilight.
//
// La vue vidéo (`videoView` du lecteur, `drawable` de VLC) contient la vue
// CAEAGLLayer créée par la sortie vidéo iOS/tvOS de VLC. Les contrôles du
// lecteur sont des vues sœurs de `videoView`, pas des enfants : ils ne sont
// donc pas capturés. On réduit la hiérarchie dans un tout petit contexte
// bitmap RGBA sRGB (64×36 par défaut), cadencé par un CADisplayLink sur le
// thread principal (~12 img/s).

/// Capture la vue vidéo (`drawHierarchy(in:afterScreenUpdates: false)`) dans un
/// petit contexte RGBA sRGB, cadencée par `CADisplayLink` (thread principal).
/// La vue VLC (CAEAGLLayer) est une sous-vue de `view`.
///
/// `start()`/`stop()` et `onFrame` s'utilisent depuis le thread principal ;
/// `onFrame` est appelé sur le thread principal.
final class ViewSnapshotTap: FrameTap {
    let name = "Capture de la vue"
    var onFrame: ((SampledFrame) -> Void)?

    private weak var view: UIView?
    private let width: Int
    private let height: Int
    private let framesPerSecond: Int
    /// Contexte bitmap réutilisé (`nil` si sa création a échoué : la prise ne fournit alors rien).
    private let context: CGContext?
    private var displayLink: CADisplayLink?
    /// Instant (horloge du display link) de la dernière capture, pour le cadencement.
    private var lastCaptureTimestamp: CFTimeInterval = 0

    init(view: UIView, width: Int = 64, height: Int = 36, framesPerSecond: Int = 12) {
        self.view = view
        self.width = max(1, width)
        self.height = max(1, height)
        self.framesPerSecond = max(1, framesPerSecond)
        self.context = Self.makeContext(width: self.width, height: self.height)
    }

    deinit {
        displayLink?.invalidate()
    }

    func start() {
        guard displayLink == nil else { return }
        lastCaptureTimestamp = 0
        // Le display link retient fortement sa cible : on passe par un relais
        // à référence faible pour ne pas créer de cycle (la prise reste libérable).
        let link = CADisplayLink(target: DisplayLinkRelay(tap: self),
                                 selector: #selector(DisplayLinkRelay.tick(_:)))
        let fps = Float(framesPerSecond)
        // Simple indication (tvOS 15+) : le système choisit un diviseur de la
        // fréquence de l'écran. Le cadencement exact est fait dans `tick`.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: max(1, fps * 0.66),
                                                        maximum: fps * 1.25,
                                                        preferred: fps)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Capture

    fileprivate func tick(_ link: CADisplayLink) {
        // Cadencement : on vise `framesPerSecond`, même si le display link
        // tourne plus vite (60 Hz, 50 Hz…) que la plage demandée.
        let interval = 1.0 / Double(framesPerSecond)
        let now = link.timestamp
        if lastCaptureTimestamp > 0, now - lastCaptureTimestamp + link.duration / 2 < interval {
            return
        }
        lastCaptureTimestamp = now

        // Le display link est ajouté à la boucle principale : on est sur le main actor.
        let frame = MainActor.assumeIsolated { captureFrame() }
        if let frame { onFrame?(frame) }
    }

    @MainActor
    private func captureFrame() -> SampledFrame? {
        guard let view, view.window != nil, let context else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        let full = CGRect(x: 0, y: 0, width: w, height: h)

        // Fond noir : `drawHierarchy` peut laisser des zones transparentes, et
        // on ne veut jamais réémettre les pixels de la capture précédente.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(full)

        context.saveGState()
        // Le contexte Core Graphics a son origine en bas à gauche (y vers le haut),
        // alors que UIKit dessine avec l'origine en haut à gauche (y vers le bas).
        // On retourne l'axe y comme le fait `UIGraphicsImageRenderer` : la ligne 0
        // du tampon est alors le haut de l'image (contrat `SampledFrame`).
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)
        // Réduction : les bornes de la vue occupent exactement w×h pixels.
        context.scaleBy(x: w / bounds.width, y: h / bounds.height)
        UIGraphicsPushContext(context)
        let drawn = view.drawHierarchy(in: CGRect(origin: .zero, size: bounds.size),
                                       afterScreenUpdates: false)
        UIGraphicsPopContext()
        context.restoreGState()

        guard drawn, let data = context.data else { return nil }
        let count = width * height * 4
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                              count: count))
        return SampledFrame(width: width,
                            height: height,
                            rgba: bytes,
                            timestamp: ProcessInfo.processInfo.systemUptime)
    }

    /// Contexte RGBA 8 bits sRGB, octets dans l'ordre R, G, B, X (alpha ignoré),
    /// `bytesPerRow` = largeur × 4 (pas de remplissage entre les lignes).
    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: info) else { return nil }
        // Compromis coût / qualité : la réduction ~30× doit moyenner un peu les
        // pixels (évite le scintillement d'un échantillonnage au plus proche).
        context.interpolationQuality = .medium
        return context
    }
}

/// Relais à référence faible entre `CADisplayLink` (qui retient sa cible) et la prise.
/// Si la prise a été libérée sans `stop()`, le relais invalide lui-même le display link.
private final class DisplayLinkRelay: NSObject {
    private weak var tap: ViewSnapshotTap?

    init(tap: ViewSnapshotTap) {
        self.tap = tap
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let tap else {
            link.invalidate()
            return
        }
        tap.tick(link)
    }
}
