import Foundation

/// Pompe HueStream : envoie un paquet toutes les 1/rateHz s (50 Hz) sur sa propre file série,
/// y compris des paquets identiques (redondance UDP + keep-alive < 10 s exigé par le pont).
///
/// Chaîne interne :
/// 1. `submit` range les couleurs mesurées dans une ligne à retard (file triée par instant de capture) ;
/// 2. à chaque `step`, les entrées dont l'instant ≤ now − latency deviennent les cibles
///    (les canaux absents d'une entrée gardent leur cible précédente) ;
/// 3. la couleur affichée suit la cible par lissage exponentiel de constante `smoothingTimeConstant` ;
/// 4. le paquet est encodé (`HueStreamPacket`) et envoyé par le transport.
///
/// Thread-safety : l'état est protégé par un verrou ; les envois sont sérialisés par un second verrou
/// (récursif) que `stop()` acquiert pour attendre la fin d'un envoi en cours. Ainsi, après le retour de
/// `stop()`, plus aucun `send` n'a lieu, sans interblocage même si `stop()` est appelé depuis le thread
/// principal pendant un tick, ou depuis le transport lui-même pendant un envoi.
final class HueEntertainmentStreamer {

    /// Nombre maximal d'entrées en attente dans la ligne à retard (au-delà, les plus anciennes
    /// sont appliquées immédiatement aux cibles).
    private static let maxPendingEntries = 512
    /// Pas de temps maximal pris en compte par le lissage (évite un saut après une pause du tick).
    private static let maxStepInterval: TimeInterval = 0.25

    private let areaID: String
    private let channelIDs: [UInt8]
    private let channelSet: Set<UInt8>
    private let transport: HueDatagramTransport
    private let interval: TimeInterval
    private let clock: () -> TimeInterval
    private let pumpQueue = DispatchQueue(label: "com.nicolasbataille.stremiotv.hue.streamer",
                                          qos: .userInteractive)

    // MARK: État protégé par `stateLock`

    private let stateLock = NSLock()
    private var _smoothingTimeConstant: TimeInterval = 0.18
    private var _latency: TimeInterval = 0
    /// Ligne à retard : (instant de capture, couleurs par canal), triée par instant croissant.
    private var pending: [(time: TimeInterval, colors: [UInt8: HueRGB])] = []
    private var targets: [UInt8: HueRGB]
    private var current: [UInt8: HueRGB]
    private var lastStepTime: TimeInterval?
    private var sequence: UInt8 = 0
    private var _packetsSent = 0
    private var timer: DispatchSourceTimer?
    /// Incrémenté à chaque `start()`/`stop()` : un tick d'un ancien minuteur ne fait plus rien.
    private var generation = 0

    // MARK: Sérialisation des envois

    /// Tenu pendant tout `step` (calcul + envoi). Récursif pour qu'un `stop()` appelé depuis
    /// `transport.send` (même thread) n'interbloque pas.
    private let sendLock = NSRecursiveLock()
    /// `true` après `stop()` (jusqu'au prochain `start()`) : `step` n'envoie plus rien.
    /// Lu et écrit sous `sendLock`.
    private var halted = false

    init(areaID: String,
         channelIDs: [UInt8],
         transport: HueDatagramTransport,
         rateHz: Double = 50,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.areaID = areaID
        self.channelIDs = channelIDs
        self.channelSet = Set(channelIDs)
        self.transport = transport
        let rate = (rateHz.isFinite && rateHz > 0) ? rateHz : 50
        self.interval = 1 / rate
        self.clock = clock
        var black: [UInt8: HueRGB] = [:]
        for id in channelIDs { black[id] = .black }
        self.targets = black
        self.current = black
    }

    deinit {
        // Le gestionnaire du minuteur ne retient pas `self` : on l'annule ici par sécurité.
        timer?.cancel()
    }

    // MARK: Réglages

    /// Constante de temps du lissage exponentiel (s). Thread-safe.
    var smoothingTimeConstant: TimeInterval {
        get { withState { _smoothingTimeConstant } }
        set { withState { _smoothingTimeConstant = newValue.isFinite ? newValue : 0 } }
    }

    /// Retard volontaire (s, ≥ 0) appliqué aux cibles avant affichage. Thread-safe.
    var latency: TimeInterval {
        get { withState { _latency } }
        set { withState { _latency = newValue.isFinite ? max(0, newValue) : 0 } }
    }

    /// Nombre de paquets envoyés (thread-safe, diagnostics).
    var packetsSent: Int {
        withState { _packetsSent }
    }

    // MARK: Entrée des couleurs

    /// Nouvelles couleurs cibles mesurées à `capturedAt` (même horloge que `clock`). Thread-safe.
    /// Les canaux absents gardent leur dernière cible.
    func submit(_ colors: [HueChannelColor], capturedAt: TimeInterval) {
        var entry: [UInt8: HueRGB] = [:]
        for color in colors where channelSet.contains(color.channelID) {
            entry[color.channelID] = color.color
        }
        guard !entry.isEmpty else { return }
        let time = capturedAt.isFinite ? capturedAt : clock()

        withState {
            // Insertion triée (les captures arrivent normalement dans l'ordre : ajout en fin).
            if let last = pending.last, last.time > time {
                let index = pending.firstIndex { $0.time > time } ?? pending.count
                pending.insert((time, entry), at: index)
            } else {
                pending.append((time, entry))
            }
            // Ligne à retard bornée : on applique les entrées les plus anciennes en excès.
            while pending.count > Self.maxPendingEntries {
                let oldest = pending.removeFirst()
                targets.merge(oldest.colors) { _, new in new }
            }
        }
    }

    // MARK: Pompe

    /// Démarre la pompe (le transport doit déjà être connecté). Idempotent.
    func start() {
        sendLock.lock()
        halted = false
        sendLock.unlock()

        stateLock.lock()
        defer { stateLock.unlock() }
        guard timer == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        let source = DispatchSource.makeTimerSource(queue: pumpQueue)
        source.schedule(deadline: .now(),
                        repeating: interval,
                        leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            self?.tick(generation: currentGeneration)
        }
        timer = source
        source.resume()
    }

    /// Arrête la pompe ; après le retour, plus aucun `send`. Idempotent, appelable depuis n'importe quel thread
    /// (y compris depuis le thread principal pendant qu'un tick tourne : pas d'interblocage).
    func stop() {
        // 1. Plus de nouveaux ticks.
        stateLock.lock()
        let source = timer
        timer = nil
        generation &+= 1
        stateLock.unlock()
        source?.cancel()

        // 2. Attend la fin d'un éventuel envoi en cours (le tick ne prend jamais de verrou
        //    détenu par l'appelant de `stop()`, et `sendLock` est récursif pour un appel
        //    depuis `transport.send`), puis interdit tout envoi ultérieur.
        sendLock.lock()
        halted = true
        sendLock.unlock()
    }

    private func tick(generation tickGeneration: Int) {
        let isCurrent = withState { generation == tickGeneration && timer != nil }
        guard isCurrent else { return }
        step(now: clock())
    }

    /// Calcule et envoie UN paquet à l'instant `now` (utilisé par la pompe ; exposé pour les tests).
    func step(now: TimeInterval) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard !halted else { return }

        let packet: Data = withState {
            advance(to: now)
            let colors = channelIDs.map { id in
                HueChannelColor(channelID: id, color: current[id] ?? .black)
            }
            let data = HueStreamPacket.encode(areaID: areaID, sequence: sequence, colors: colors)
            sequence &+= 1
            return data
        }

        transport.send(packet)
        withState { _packetsSent += 1 }
    }

    // MARK: Calcul (sous `stateLock`)

    /// Applique la ligne à retard puis le lissage jusqu'à `now`. Appelé verrou `stateLock` tenu.
    private func advance(to now: TimeInterval) {
        // Ligne à retard : toutes les entrées échues deviennent cibles, dans l'ordre
        // (la plus récente l'emporte, les canaux absents gardent leur cible).
        let due = now - _latency
        while let first = pending.first, first.time <= due {
            targets.merge(first.colors) { _, new in new }
            pending.removeFirst()
        }

        // Lissage exponentiel : cur += (cible − cur) × (1 − exp(−dt/τ)).
        var dt = lastStepTime.map { now - $0 } ?? interval
        if !dt.isFinite { dt = 0 }
        dt = min(Self.maxStepInterval, max(0, dt))
        lastStepTime = now

        let tau = _smoothingTimeConstant
        let alpha = tau <= 0 ? 1 : 1 - exp(-dt / tau)
        for id in channelIDs {
            let target = targets[id] ?? .black
            guard alpha < 1 else {
                current[id] = target
                continue
            }
            let cur = current[id] ?? .black
            current[id] = HueRGB(r: cur.r + (target.r - cur.r) * alpha,
                                 g: cur.g + (target.g - cur.g) * alpha,
                                 b: cur.b + (target.b - cur.b) * alpha)
        }
    }

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}
