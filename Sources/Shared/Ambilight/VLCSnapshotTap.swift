import Foundation
import CoreGraphics
import ImageIO
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

// Prise d'image « Snapshot VLC » de l'Ambilight (repli de la capture de la vue).
//
// libVLC sait écrire un instantané PNG de l'image décodée à la taille voulue
// (`libvlc_video_take_snapshot`). VLCKit l'expose via `saveVideoSnapshotAt:…`,
// mais cette méthode lève une NSException quand il n'y a pas de sortie vidéo,
// ce que Swift ne sait pas rattraper (et on s'interdit tout fichier ObjC). On
// appelle donc directement la fonction C, sans exception possible :
// - le `libvlc_media_player_t *` vient de la méthode ObjC `libVLCMediaPlayer`
//   de VLCMediaPlayer (publique au runtime, déclarée seulement dans un en-tête
//   interne de VLCKit 3.7.3, renvoie `void *`) ;
// - la fonction est trouvée par `dlsym(RTLD_DEFAULT, …)` (VLCKit est un
//   framework dynamique qui l'exporte).
//
// Les options par défaut de VLCKit sur iOS/tvOS incluent `--no-osd` et
// `--no-snapshot-preview` : l'instantané n'affiche rien à l'écran.
//
// Effet de bord connu (VLC 3 / VLCKit 3.7.3) : chaque instantané réussi
// déclenche `libvlc_MediaPlayerSnapshotTaken`. VLCKit ajoute alors le chemin du
// fichier à son tableau privé `_snapshots` (jamais vidé tant que le lecteur
// vit) et poste `VLCMediaPlayerSnapshotTaken` sur le thread principal
// (configuration d'événements par défaut). À 4 img/s, cela ferait ~14 000
// chemins (~2–3 Mo) par heure de lecture : on vide ce tableau régulièrement
// (voir `purgeSnapshotList`). Les 4 notifications/s restent (le gestionnaire
// VLCKit est une fonction C statique, impossible à détacher sans ObjC) ; leur
// coût est négligeable. Ne pas se fier à `player.snapshots` /
// `player.lastSnapshot` : les fichiers sont déjà supprimés.

/// Instantanés libVLC `libvlc_video_take_snapshot` (PNG temporaire w×h) sur une
/// file série en arrière-plan, une capture à la fois.
final class VLCSnapshotTap: FrameTap {
    /// `int libvlc_video_take_snapshot(libvlc_media_player_t *p_mi, unsigned num,
    ///  const char *psz_filepath, unsigned int i_width, unsigned int i_height)`
    /// — 0 = succès ; bloque jusqu'à ~500 ms en attendant la sortie vidéo.
    private typealias TakeSnapshotFunction = @convention(c) (
        UnsafeMutableRawPointer?, UInt32, UnsafePointer<CChar>?, UInt32, UInt32
    ) -> Int32
    /// `- (void *)libVLCMediaPlayer` appelée via son implémentation (IMP).
    private typealias PlayerPointerGetter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?

    private static let playerPointerSelector = NSSelectorFromString("libVLCMediaPlayer")

    /// Fonction C résolue une fois pour toutes (`nil` si le symbole est absent).
    private static let takeSnapshot: TakeSnapshotFunction? = {
        // `RTLD_DEFAULT` vaut `((void *) -2)` dans <dlfcn.h> (Darwin) : on écrit
        // la valeur explicitement, la macro n'étant pas forcément importée en Swift.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "libvlc_video_take_snapshot") else { return nil }
        return unsafeBitCast(symbol, to: TakeSnapshotFunction.self)
    }()

    /// true si le sélecteur et le symbole sont disponibles à l'exécution.
    static var isSupported: Bool {
        takeSnapshot != nil && VLCMediaPlayer.instancesRespond(to: playerPointerSelector)
    }

    let name = "Snapshot VLC"

    /// Lu depuis la file de capture : protégé par `lock`.
    var onFrame: ((SampledFrame) -> Void)? {
        get { lock.withLock { frameHandler } }
        set { lock.withLock { frameHandler = newValue } }
    }

    /// Référence forte : garde le `libvlc_media_player_t` en vie pendant une capture en cours.
    private let player: VLCMediaPlayer
    private let width: Int
    private let height: Int
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "com.nicolasbataille.stremiotv.ambilight.vlcsnapshot",
                                      qos: .utility)
    /// PNG temporaire propre à cette prise (supprimé après chaque lecture).
    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("stremiotv-ambilight-\(UUID().uuidString).png")

    /// Utilisé uniquement depuis le thread principal (`start`/`stop`).
    private var timer: DispatchSourceTimer?

    // État partagé entre le thread principal et la file de capture.
    private let lock = NSRecursiveLock()
    private var frameHandler: ((SampledFrame) -> Void)?
    private var isRunning = false
    /// Incrémenté à chaque `start`/`stop` : une capture lancée avant un `stop()`
    /// n'est jamais émise après.
    private var generation = 0

    // Utilisés uniquement sur `queue`.
    private var playerPointer: UnsafeMutableRawPointer?
    /// Instantanés réussis depuis la dernière purge de la liste VLCKit.
    private var capturesSincePurge = 0
    private lazy var context: CGContext? = Self.makeContext(width: width, height: height)

    init(player: VLCMediaPlayer, width: Int = 64, height: Int = 36, framesPerSecond: Double = 4) {
        self.player = player
        self.width = max(1, width)
        self.height = max(1, height)
        self.interval = 1.0 / min(max(framesPerSecond, 0.5), 30)
    }

    deinit {
        timer?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func start() {
        guard timer == nil, Self.isSupported else { return }
        lock.withLock {
            isRunning = true
            generation &+= 1
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let period = DispatchTimeInterval.milliseconds(Int(interval * 1000))
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(20))
        // File série + source de minuterie : si une capture dure plus que la
        // période, les déclenchements suivants sont fusionnés (jamais d'empilement).
        timer.setEventHandler { [weak self] in self?.capture() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        lock.withLock {
            isRunning = false
            generation &+= 1
        }
        timer?.cancel()
        timer = nil
        Self.purgeSnapshotList(of: player)
        // Nettoyage après l'éventuelle capture en cours (même file série).
        let url = fileURL
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Capture (sur `queue`)

    private func capture() {
        let runningGeneration: Int? = lock.withLock { isRunning ? generation : nil }
        guard let startGeneration = runningGeneration, let takeSnapshot = Self.takeSnapshot else { return }
        if playerPointer == nil {
            playerPointer = Self.libVLCPlayerPointer(of: player)
        }
        guard let mediaPlayerPointer = playerPointer else { return }

        // Aucun fichier d'une capture précédente ne doit être relu.
        try? FileManager.default.removeItem(at: fileURL)
        let result: Int32 = fileURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return takeSnapshot(mediaPlayerPointer, 0, path, UInt32(width), UInt32(height))
        }
        let capturedAt = ProcessInfo.processInfo.systemUptime
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // VLC 3 renvoie 0 dès qu'une sortie vidéo existe, même si l'instantané a
        // échoué : l'absence de fichier est gérée par le décodage ci-dessous.
        guard result == 0 else { return }
        capturesSincePurge += 1
        if capturesSincePurge >= Self.snapshotListPurgeInterval {
            capturesSincePurge = 0
            let player = self.player
            DispatchQueue.main.async { Self.purgeSnapshotList(of: player) }
        }
        guard let rgba = decodeSnapshot() else { return }

        let frame = SampledFrame(width: width, height: height, rgba: rgba, timestamp: capturedAt)
        // Émission sous le verrou : après le retour de `stop()`, plus aucun `onFrame`.
        lock.withLock {
            guard isRunning, generation == startGeneration else { return }
            frameHandler?(frame)
        }
    }

    /// Lit le PNG via ImageIO et le redessine dans le contexte RGBA w×h.
    /// Le dessin force le décodage : le fichier peut être supprimé ensuite.
    private func decodeSnapshot() -> [UInt8]? {
        guard let context,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                                                          [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(full)
        // Pas de retournement ici : `draw(_:in:)` place le haut de la CGImage en
        // haut du contexte, et la ligne 0 du tampon bitmap est le haut de l'image
        // (contrat `SampledFrame`, origine haut-gauche).
        context.draw(image, in: full)
        guard let data = context.data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                         count: width * height * 4))
    }

    /// `libvlc_media_player_t *` de VLCKit, via la méthode ObjC `libVLCMediaPlayer`.
    private static func libVLCPlayerPointer(of player: VLCMediaPlayer) -> UnsafeMutableRawPointer? {
        let selector = playerPointerSelector
        guard player.responds(to: selector), let implementation = player.method(for: selector) else {
            return nil
        }
        let getter = unsafeBitCast(implementation, to: PlayerPointerGetter.self)
        return getter(player, selector)
    }

    // MARK: - Liste d'instantanés de VLCKit

    /// Chaque instantané réussi déclenche `libvlc_MediaPlayerSnapshotTaken` :
    /// VLCKit 3.x ajoute alors le chemin du fichier à son tableau privé
    /// `_snapshots` (jamais vidé tant que le lecteur vit, ~190 octets par prise,
    /// soit ~2,7 Mo par heure à 4 img/s) depuis le thread principal (configuration
    /// d'événements par défaut). On le vide régulièrement, depuis le thread principal.
    private static let snapshotListPurgeInterval = 240   // ~1 min à 4 img/s
    private static let hasSnapshotList =
        VLCMediaPlayer.accessInstanceVariablesDirectly
        && class_getInstanceVariable(VLCMediaPlayer.self, "_snapshots") != nil

    /// À appeler sur le thread principal (là où VLCKit remplit la liste). Sans
    /// effet si l'ivar n'existe pas (autre version de VLCKit) : KVC lèverait
    /// sinon une exception. VLCKit recrée le tableau au prochain instantané.
    private static func purgeSnapshotList(of player: VLCMediaPlayer) {
        guard hasSnapshotList else { return }
        player.setValue(nil, forKey: "snapshots")
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
        context.interpolationQuality = .medium
        return context
    }
}
