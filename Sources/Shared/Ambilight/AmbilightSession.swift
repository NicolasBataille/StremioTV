import UIKit
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

/// Session Ambilight d'une lecture : prise d'image → `ColorPipeline` → `HueEntertainmentStreamer`.
///
/// Créée par `HueSyncService.makeSession(videoView:player:)` à la première image rendue,
/// pilotée par `VLCPlayerCoreController` (pause / reprise / arrêt).
///
/// Tout le cycle de vie se passe sur le main actor. Seul le traitement des images tourne
/// ailleurs (`AmbilightFrameProcessor`, file série dédiée) ; l'état remonte au main actor
/// par un bilan toutes les secondes. Aucune erreur Hue ne doit gêner la lecture vidéo :
/// rien ici ne lève, ne bloque le thread principal ni ne touche au lecteur VLC.
@MainActor
final class AmbilightSession {
    private enum Phase {
        case idle
        case starting
        case running
        /// Flux perdu en cours de lecture : nouvelle tentative programmée (`reconnectTask`).
        case reconnecting
        /// Arrêtée par la mise en arrière-plan de l'app : `resume()` la relance.
        case suspended
        case stopped
    }

    /// Durée de lecture (non en pause) sans aucune image exploitable avant de lancer,
    /// en parallèle, la méthode de capture suivante comme sonde.
    private static let captureProbeSeconds = 4
    /// Bilans consécutifs où seule la sonde voit une image (la prise active restant
    /// noire) avant de basculer sur elle : la prise active est cassée, pas l'image noire.
    private static let probeConfirmSeconds = 2
    /// Durée de lecture (non en pause) sans aucune image au-delà de laquelle une prise
    /// déjà validée est considérée comme bloquée : les lumières s'éteignent en fondu
    /// au lieu de rester figées sur la dernière couleur.
    private static let stallSeconds = 3
    /// Délai de la poignée de main DTLS (par identité essayée).
    private static let handshakeTimeout: TimeInterval = 5
    /// Relances automatiques après une perte du flux DTLS (réseau, redémarrage du pont…),
    /// espacées de 1, 2, 4, 8 puis 8 s : de quoi laisser le pont redémarrer.
    private static let maxStreamRecoveries = 5
    /// Durée de flux sans perte au-delà de laquelle le compteur de relances repart de zéro
    /// (quelques coupures Wi-Fi espacées pendant un film ne doivent pas tout arrêter).
    private static let streamRecoveryResetSeconds = 60
    /// Vérification de l'état de la zone auprès du pont toutes les N secondes de flux.
    private static let areaCheckSeconds = 10

    private weak var service: HueSyncService?
    private weak var videoView: UIView?
    private weak var player: VLCMediaPlayer?
    private var credentials: HueCredentials
    private let areaID: String
    private let preferences: HuePreferences

    private var phase: Phase = .idle
    private var isPaused = false
    /// Ressources de la tentative en cours (réseau, pompe, traitement).
    private var run: AmbilightRun?
    private var healthTask: Task<Void, Never>?

    // Chaîne des prises d'image
    private var captureChain: [HueCaptureMethod] = []
    private var captureIndex = 0
    private var tap: FrameTap?
    private var isTapRunning = false
    /// La prise active a fourni au moins une image non entièrement noire.
    private var isTapProven = false
    private var dimSeconds = 0
    /// Secondes consécutives sans aucune image alors que la prise validée tourne.
    private var stalledSeconds = 0
    private var lastPacketCount = 0
    /// Sonde : prise suivante de la chaîne (en boucle), lancée à côté de la prise active
    /// restée noire. Ses images ne sont pas envoyées aux lampes : elle sert seulement à
    /// distinguer une image noire (les deux restent noires) d'une prise cassée.
    private var probeTap: FrameTap?
    private var probeIndex = 0
    private var isProbeRunning = false
    private var probeLeadSeconds = 0

    // Relances après perte du flux DTLS
    private var streamRecoveries = 0
    private var connectedSeconds = 0
    private var reconnectTask: Task<Void, Never>?
    private var isCheckingArea = false

    init(service: HueSyncService,
         credentials: HueCredentials,
         areaID: String,
         preferences: HuePreferences,
         videoView: UIView,
         player: VLCMediaPlayer) {
        self.service = service
        self.credentials = credentials
        self.areaID = areaID
        self.preferences = preferences
        self.videoView = videoView
        self.player = player
    }

    /// Démarre de façon asynchrone : réservation de la zone, connexion DTLS, pompe,
    /// puis la 1re prise d'image de la chaîne. Sans effet si déjà démarrée ou arrêtée.
    func start() {
        guard phase == .idle || phase == .suspended else { return }
        // App déjà en arrière-plan (1re image rendue juste après l'appui sur Home/TV) : on ne
        // réserve pas la zone ; la session repartira au retour au premier plan (`restartIfSuspended()`).
        guard UIApplication.shared.applicationState != .background else {
            phase = .suspended
            service?.sessionDidEnd(self, error: nil)
            return
        }
        phase = .starting
        service?.sessionIsConnecting(self)

        let run = AmbilightRun(credentials: credentials, areaID: areaID)
        self.run = run
        run.task = Task { [weak self] in
            await self?.connect(run)
        }
    }

    /// Arrête la prise d'image ; la pompe continue (dernières couleurs, keep-alive).
    func pause() {
        isPaused = true
        stopTap()
        stopProbeTap()
    }

    func resume() {
        isPaused = false
        if phase == .running {
            startTap()
            startProbeTap()
        } else {
            restartIfSuspended()
        }
    }

    /// Relance une session suspendue (retour au premier plan), sans changer l'état pause.
    func restartIfSuspended() {
        guard phase == .suspended, UIApplication.shared.applicationState != .background else { return }
        start()
    }

    /// Idempotent : arrête prise + pompe, ferme le transport, PUT stop (Task détachée),
    /// invalide le client.
    func stop() {
        guard phase != .stopped else { return }
        tearDown()
        phase = .stopped
        service?.sessionDidEnd(self, error: nil)
    }

    /// App en arrière-plan : libère la zone sans terminer la session (cf. `resume()`).
    func suspend() {
        guard phase == .starting || phase == .running || phase == .reconnecting else { return }
        tearDown()
        phase = .suspended
        service?.sessionDidEnd(self, error: nil)
    }

    /// `true` si la session a été suspendue (arrière-plan) et peut être relancée.
    var isSuspended: Bool { phase == .suspended }

    // MARK: - Démarrage

    private func connect(_ run: AmbilightRun) async {
        // Annulée avant même de démarrer (ex. suspend() juste après start()) : ne crée pas
        // de client, il ne serait jamais invalidé (la URLSession retient son délégué).
        guard !run.isCancelled else { return }
        // Une libération précédente (PUT stop d'une session ou d'un test interrompu) encore
        // en vol ne doit pas arriver au pont après notre PUT start : on l'attend d'abord.
        // Avant le GET, pour que `availableArea` voie l'état de la zone après cette libération.
        await HueStreamSetup.waitForPendingReleases()
        guard !run.isCancelled else { return }
        do {
            let client = HueBridgeClient(host: run.credentials.host,
                                         pinnedCertificateSHA256: run.credentials.certificateSHA256)
            run.client = client

            // Identité DTLS : l'application ID (lue à l'appairage ; relue ici si elle manque).
            if run.credentials.applicationID == nil,
               let applicationID = try? await client.applicationID(username: run.credentials.username) {
                guard !run.isCancelled else { return }
                run.credentials.applicationID = applicationID
                credentials.applicationID = applicationID
                service?.rememberApplicationID(applicationID)
            }
            guard !run.isCancelled else { return }

            let area = try await HueStreamSetup.availableArea(client: client,
                                                              areaID: run.areaID,
                                                              credentials: run.credentials)
            guard !run.isCancelled else { return }
            run.streamAreaID = area.id

            // Réservation de la zone (PUT {"action":"start"}, précédé d'un PUT stop si un flux
            // à nous est resté actif). Tant que `claim == .pending`, `cancel()` n'annule pas la
            // tâche : la séquence stop → start → libération reste cohérente.
            run.claim = .pending
            do {
                try await HueStreamSetup.claim(client: client, area: area, username: run.credentials.username)
            } catch {
                run.claim = .none
                if run.isCancelled {
                    client.invalidate()
                    return
                }
                if case HueError.timeout = error { throw error }
                throw area.isStreaming ? HueError.areaInUseByAnotherApp : error
            }
            run.claim = .claimed
            guard !run.isCancelled else {
                // Arrêt demandé pendant la réservation : on libère la zone nous-mêmes.
                run.releaseArea()
                return
            }

            // Poignée de main DTLS (application ID, puis 1 nouvel essai avec le username).
            let transport = HueDTLSTransport()
            run.transport = transport
            // Session DTLS perdue en cours de flux (Wi-Fi, pont redémarré…) : on se reconnecte
            // aussitôt, sans attendre le bilan suivant (qui la détecterait aussi via `isConnected`).
            transport.onConnectionLost = { @Sendable [weak self, weak run] _ in
                Task { @MainActor [weak self, weak run] in
                    guard let self, let run else { return }
                    self.streamLost(run)
                }
            }
            var lastError: Error = HueError.handshakeFailed("aucune identité")
            var connected = false
            for identity in HueStreamSetup.pskIdentities(for: run.credentials) {
                do {
                    try await HueStreamSetup.connect(transport,
                                                     host: run.credentials.host,
                                                     identity: identity,
                                                     pskHex: run.credentials.clientKey,
                                                     timeout: Self.handshakeTimeout)
                    connected = true
                    break
                } catch {
                    lastError = error
                }
                guard !run.isCancelled else { return }
            }
            guard !run.isCancelled else { return }
            guard connected else { throw lastError }

            // Pompe 50 Hz.
            let streamer = HueEntertainmentStreamer(areaID: area.id,
                                                    channelIDs: area.channels.map(\.id),
                                                    transport: transport)
            streamer.smoothingTimeConstant = preferences.responsiveness.timeConstant
            streamer.latency = Double(preferences.latencyMs) / 1000
            streamer.start()
            run.streamer = streamer

            let tuning = AmbilightTuning(brightness: preferences.brightness,
                                         saturationBoost: preferences.saturationBoost)
            run.processor = AmbilightFrameProcessor(channels: area.channels, tuning: tuning, streamer: streamer)

            phase = .running
            lastPacketCount = 0
            connectedSeconds = 0
            startHealthMonitor()
            captureChain = Self.captureChain(preferred: preferences.captureMethod,
                                             lastWorking: preferences.lastWorkingCapture,
                                             vlcSnapshotSupported: VLCSnapshotTap.isSupported)
            activateTap(at: 0)
        } catch {
            guard !run.isCancelled else { return }
            if case HueError.timeout = error { service?.bridgeSeemsUnreachable() }
            if streamRecoveries > 0, !Self.isAreaTakenError(error) {
                // Relance après une perte du flux qui échoue (pont en train de redémarrer,
                // Wi-Fi pas encore revenu…) : nouvel essai un peu plus tard.
                recoverLostStream()
            } else {
                fail(error.localizedDescription)
            }
        }
    }

    private static func isAreaTakenError(_ error: Error) -> Bool {
        if case HueError.areaInUseByAnotherApp = error { return true }
        return false
    }

    /// Erreur Hue : on libère tout, la lecture continue normalement.
    private func fail(_ message: String) {
        guard phase == .starting || phase == .running else { return }
        tearDown()
        phase = .stopped
        service?.sessionDidEnd(self, error: message)
    }

    private func tearDown() {
        healthTask?.cancel()
        healthTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopProbe()
        stopTap()
        tap?.onFrame = nil
        tap = nil
        run?.cancel()
        run = nil
    }

    // MARK: - Prises d'image

    /// Ordre d'essai des méthodes de capture.
    /// - choix explicite → cette méthode seule (la vue si le snapshot VLC est indisponible) ;
    /// - automatique → dernière méthode qui a marché, puis la vue, puis le snapshot VLC.
    static func captureChain(preferred: HueCaptureMethod,
                             lastWorking: HueCaptureMethod?,
                             vlcSnapshotSupported: Bool) -> [HueCaptureMethod] {
        let candidates: [HueCaptureMethod]
        switch preferred {
        case .view:
            candidates = [.view]
        case .vlcSnapshot:
            candidates = vlcSnapshotSupported ? [.vlcSnapshot] : [.view]
        case .automatic:
            candidates = [lastWorking, .view, .vlcSnapshot].compactMap { $0 }
        }
        var chain: [HueCaptureMethod] = []
        for method in candidates where method != .automatic && !chain.contains(method) {
            if method == .vlcSnapshot && !vlcSnapshotSupported { continue }
            chain.append(method)
        }
        return chain
    }

    private func makeTap(_ method: HueCaptureMethod) -> FrameTap? {
        switch method {
        case .view:
            guard let videoView else { return nil }
            return ViewSnapshotTap(view: videoView)
        case .vlcSnapshot:
            guard VLCSnapshotTap.isSupported, let player else { return nil }
            return VLCSnapshotTap(player: player)
        case .automatic:
            return nil
        }
    }

    /// Active la 1re prise disponible à partir de `index` dans la chaîne.
    private func activateTap(at index: Int) {
        guard phase == .running, let processor = run?.processor else { return }
        stopProbe()
        stopTap()
        tap?.onFrame = nil
        tap = nil

        var candidate = index
        var newTap: FrameTap?
        while candidate < captureChain.count, newTap == nil {
            newTap = makeTap(captureChain[candidate])
            if newTap == nil { candidate += 1 }
        }
        guard let newTap else {
            fail("Aucune méthode de capture de l'image n'est disponible.")
            return
        }

        captureIndex = candidate
        isTapProven = false
        dimSeconds = 0
        stalledSeconds = 0
        let generation = processor.beginGeneration()
        newTap.onFrame = processor.makeFrameHandler(generation: generation)
        tap = newTap
        startTap()
        service?.sessionIsStreaming(self, captureName: newTap.name)
    }

    private func startTap() {
        guard phase == .running, !isPaused, !isTapRunning, let tap else { return }
        isTapRunning = true
        tap.start()
    }

    private func stopTap() {
        guard isTapRunning else { return }
        isTapRunning = false
        tap?.stop()
    }

    /// Lance comme sonde la prise suivante de la chaîne (en boucle), sans toucher à la prise active.
    private func startProbe() {
        guard probeTap == nil, captureChain.count > 1, let processor = run?.processor else { return }
        for offset in 1..<captureChain.count {
            let index = (captureIndex + offset) % captureChain.count
            guard let candidate = makeTap(captureChain[index]) else { continue }
            probeIndex = index
            probeLeadSeconds = 0
            candidate.onFrame = processor.makeProbeHandler(probe: processor.beginProbe())
            probeTap = candidate
            startProbeTap()
            return
        }
    }

    private func startProbeTap() {
        guard phase == .running, !isPaused, !isProbeRunning, let probeTap else { return }
        isProbeRunning = true
        probeTap.start()
    }

    private func stopProbeTap() {
        guard isProbeRunning else { return }
        isProbeRunning = false
        probeTap?.stop()
    }

    private func stopProbe() {
        stopProbeTap()
        probeTap?.onFrame = nil
        probeTap = nil
        probeLeadSeconds = 0
    }

    // MARK: - Bilan (toutes les secondes)

    private func startHealthMonitor() {
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.healthTick()
            }
        }
    }

    private func healthTick() {
        guard phase == .running,
              let run,
              let processor = run.processor,
              let streamer = run.streamer,
              let tap else { return }

        // Session DTLS perdue après la poignée de main : les datagrammes partent dans le vide.
        if let transport = run.transport, !transport.isConnected {
            recoverLostStream()
            return
        }
        connectedSeconds += 1
        if connectedSeconds >= Self.streamRecoveryResetSeconds { streamRecoveries = 0 }
        // Pertes que la connexion UDP ne signale pas : zone désactivée par le pont, reprise par une autre app.
        if connectedSeconds % Self.areaCheckSeconds == 0 { checkArea(run) }

        let stats = processor.takeStats()
        let packets = streamer.packetsSent
        let packetRate = max(0, packets - lastPacketCount)
        lastPacketCount = packets

        if !isTapProven {
            if stats.sawLitFrame {
                // La prise active voit l'image : elle marche (la sonde éventuelle est inutile).
                isTapProven = true
                dimSeconds = 0
                stopProbe()
                if captureIndex < captureChain.count {
                    preferences.lastWorkingCapture = captureChain[captureIndex]
                }
            } else if isTapRunning {
                dimSeconds += 1
                if probeTap == nil {
                    // Prise muette ou image noire (générique, fondu…) : on ne le sait pas
                    // encore. On compare avec la prise suivante, sans quitter l'actuelle.
                    if dimSeconds >= Self.captureProbeSeconds { startProbe() }
                } else if processor.probeSawLitFrame() {
                    probeLeadSeconds += 1
                    if probeLeadSeconds >= Self.probeConfirmSeconds {
                        // Seule la sonde voit l'image : la prise active est cassée.
                        activateTap(at: probeIndex)
                        return
                    }
                }
            }
        } else if isTapRunning, stats.frames == 0 {
            // Prise validée devenue muette (vue hors fenêtre, instantanés VLC en échec…).
            // On ne change pas de prise (un rebuffering peut affamer les snapshots VLC) :
            // on éteint en fondu, la prochaine image reprend la main.
            stalledSeconds += 1
            if stalledSeconds == Self.stallSeconds {
                processor.submitBlack()
            }
        } else {
            stalledSeconds = 0
        }

        var parts = [tap.name, "\(stats.frames) img/s", "\(packetRate) paquets/s"]
        if isPaused {
            parts.append("en pause")
        } else if !isTapProven && dimSeconds > 0 {
            parts.append("image noire")
        } else if stalledSeconds >= Self.stallSeconds {
            parts.append("aucune image")
        }
        service?.sessionDiagnostics(self, parts.joined(separator: " · "))
    }

    /// Flux DTLS perdu après la poignée de main (réseau coupé, pont redémarré, zone arrêtée
    /// depuis l'app Hue…) : on relance toute la mise en place, PUT start compris (le pont a pu
    /// désactiver la zone), sans PUT stop qui risquerait d'arriver après le nouveau PUT start
    /// (le pont libère seul la zone après 10 s sans paquet ; si elle est encore active à notre
    /// nom, `HueStreamSetup.claim` l'arrête puis la redémarre sur la même connexion HTTPS).
    /// La relance part après un délai croissant (1, 2, 4, 8, 8 s) ; une relance qui échoue en
    /// programme une autre (cf. `connect`). Au-delà de `maxStreamRecoveries` relances rapprochées : erreur.
    private func recoverLostStream() {
        guard phase == .starting || phase == .running else { return }
        guard streamRecoveries < Self.maxStreamRecoveries else {
            fail("Flux Hue interrompu : le pont ne répond plus.")
            return
        }
        streamRecoveries += 1
        // Pas de PUT stop (course avec le PUT start de la relance).
        if let run, run.claim == .claimed { run.claim = .none }
        tearDown()
        phase = .reconnecting
        service?.sessionIsConnecting(self)
        let seconds = UInt64(1) << UInt64(min(streamRecoveries - 1, 3))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.phase == .reconnecting else { return }
            self.reconnectTask = nil
            self.phase = .idle   // start() exige .idle ou .suspended
            self.start()
        }
    }

    /// Perte signalée par le transport (`onConnectionLost`) pour la tentative `lostRun`.
    private func streamLost(_ lostRun: AmbilightRun) {
        guard phase == .running, run === lostRun else { return }
        recoverLostStream()
    }

    /// Le pont désactive la zone après 10 s sans paquet (Wi-Fi coupé, redémarrage) sans que la
    /// connexion UDP ne le signale, et une autre app (Hue Sync sur la télé…) peut la reprendre :
    /// on relit son état. Une seule vérification à la fois ; pont injoignable → on attend la suivante.
    private func checkArea(_ run: AmbilightRun) {
        guard !isCheckingArea, let client = run.client else { return }
        isCheckingArea = true
        let areaID = run.streamAreaID ?? run.areaID
        let username = run.credentials.username
        let ours = Set([run.credentials.applicationID, run.credentials.username].compactMap { $0?.lowercased() })
        let knowsApplicationID = run.credentials.applicationID != nil
        Task { [weak self, weak run] in
            let area = try? await client.entertainmentArea(id: areaID, username: username)
            guard let self else { return }
            self.isCheckingArea = false
            guard let area, let run, self.phase == .running, self.run === run else { return }
            if !area.isStreaming {
                self.recoverLostStream()
            } else if knowsApplicationID,
                      let owner = area.activeStreamerID?.lowercased(), !ours.contains(owner) {
                // Zone reprise par une autre app : on la lui laisse, sans lui envoyer de PUT stop.
                run.claim = .none
                self.fail(HueError.areaInUseByAnotherApp.localizedDescription)
            }
        }
    }
}

// MARK: - Ressources d'une tentative

/// Ressources réseau d'une tentative de session. `cancel()` les libère toutes ;
/// la tâche de démarrage vérifie `isCancelled` après chaque attente.
@MainActor
private final class AmbilightRun {
    enum Claim {
        case none
        /// PUT start en vol : la tâche de démarrage libérera la zone à son retour.
        case pending
        case claimed
    }

    var credentials: HueCredentials
    let areaID: String
    var streamAreaID: String?
    var isCancelled = false
    var task: Task<Void, Never>?
    var client: HueBridgeClient?
    var transport: HueDTLSTransport?
    var streamer: HueEntertainmentStreamer?
    var processor: AmbilightFrameProcessor?
    var claim: Claim = .none

    init(credentials: HueCredentials, areaID: String) {
        self.credentials = credentials
        self.areaID = areaID
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        processor?.shutdown()
        streamer?.stop()
        // Débloque une poignée de main DTLS en cours (sa complétion échoue aussitôt).
        transport?.close()
        switch claim {
        case .claimed:
            releaseArea()
        case .pending:
            // On laisse le PUT start aboutir : la tâche de démarrage libère ensuite la zone.
            // La prochaine réservation attend cette tâche (puis le PUT stop qu'elle enregistre).
            // Sans risque d'interblocage : la tâche a déjà passé son attente des libérations.
            if let task { HueStreamSetup.trackRelease(task) }
        case .none:
            task?.cancel()
            client?.invalidate()
        }
    }

    /// PUT {"action":"stop"} dans une Task détachée (insensible à l'annulation), puis invalide le client.
    func releaseArea() {
        guard claim == .claimed, let client else { return }
        claim = .none
        let username = credentials.username
        let areaID = streamAreaID ?? self.areaID
        HueStreamSetup.release(client: client, areaID: areaID, username: username)
    }
}

// MARK: - Traitement des images (hors main actor)

/// Reçoit les images d'une prise (file quelconque), les traite sur sa file série
/// (`ColorPipeline`, non thread-safe) et soumet les couleurs au streamer.
/// Compte les images pour le bilan de la session. Thread-safe (verrou + file série),
/// d'où `@unchecked Sendable`.
final class AmbilightFrameProcessor: @unchecked Sendable {
    struct Stats {
        /// Images traitées depuis le dernier bilan.
        let frames: Int
        /// Au moins une image non entièrement noire depuis le début de la génération.
        let sawLitFrame: Bool
    }

    /// Une composante ≥ ce seuil (sur 255) suffit pour qu'une image ne soit pas « entièrement noire ».
    private static let litThreshold: UInt8 = 3

    private let queue = DispatchQueue(label: "com.nicolasbataille.stremiotv.ambilight.processing",
                                      qos: .userInitiated)
    /// Utilisé uniquement sur `queue`.
    private let pipeline: ColorPipeline
    private let streamer: HueEntertainmentStreamer

    private let lock = NSLock()
    private var generation = 0
    private var isShutDown = false
    private var isBusy = false
    private var frameCount = 0
    private var sawLitFrame = false
    private var probeGeneration = 0
    private var probeSawLit = false
    private let channelIDs: [UInt8]

    init(channels: [HueChannel], tuning: AmbilightTuning, streamer: HueEntertainmentStreamer) {
        self.pipeline = ColorPipeline(channels: channels, tuning: tuning)
        self.streamer = streamer
        self.channelIDs = channels.map(\.id)
    }

    /// Nouvelle prise d'image : remet les compteurs à zéro ; les images des prises
    /// précédentes sont ignorées.
    func beginGeneration() -> Int {
        lock.withLock {
            generation &+= 1
            frameCount = 0
            sawLitFrame = false
            return generation
        }
    }

    /// Gestionnaire à brancher sur `FrameTap.onFrame` (appelable depuis n'importe quelle file).
    func makeFrameHandler(generation: Int) -> (SampledFrame) -> Void {
        return { [weak self] frame in
            self?.receive(frame, generation: generation)
        }
    }

    /// Compteurs du dernier intervalle (le nombre d'images repart de zéro).
    func takeStats() -> Stats {
        lock.withLock {
            let stats = Stats(frames: frameCount, sawLitFrame: sawLitFrame)
            frameCount = 0
            return stats
        }
    }

    /// Nouvelle sonde : ses images servent seulement à savoir si elle voit autre chose
    /// que du noir (aucune couleur soumise au streamer).
    func beginProbe() -> Int {
        lock.withLock {
            probeGeneration &+= 1
            probeSawLit = false
            return probeGeneration
        }
    }

    /// Gestionnaire à brancher sur `FrameTap.onFrame` de la sonde (n'importe quelle file).
    func makeProbeHandler(probe: Int) -> (SampledFrame) -> Void {
        return { [weak self] frame in
            self?.receiveProbe(frame, probe: probe)
        }
    }

    /// La sonde en cours a vu au moins une image non entièrement noire.
    func probeSawLitFrame() -> Bool {
        lock.withLock { probeSawLit }
    }

    /// Éteint les lumières en fondu (lissage du streamer) : la prise ne fournit plus
    /// d'image alors que la lecture continue. La prochaine image reprend la main.
    func submitBlack() {
        guard !lock.withLock({ isShutDown }) else { return }
        let black = channelIDs.map { HueChannelColor(channelID: $0, color: .black) }
        streamer.submit(black, capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// Plus aucune image traitée ni soumise ensuite.
    func shutdown() {
        lock.withLock { isShutDown = true }
    }

    private func receiveProbe(_ frame: SampledFrame, probe: Int) {
        guard frame.width > 0, frame.height > 0,
              frame.rgba.count >= frame.width * frame.height * 4 else { return }
        let wanted: Bool = lock.withLock { !isShutDown && probe == probeGeneration && !probeSawLit }
        // Test très court (64×36 pixels au plus, arrêt au 1er pixel allumé), sur la file appelante.
        guard wanted, Self.hasLitPixel(frame) else { return }
        lock.withLock {
            if probe == probeGeneration { probeSawLit = true }
        }
    }

    private func receive(_ frame: SampledFrame, generation frameGeneration: Int) {
        guard frame.width > 0, frame.height > 0,
              frame.rgba.count >= frame.width * frame.height * 4 else { return }
        // Une seule image en traitement à la fois : si le traitement prend du retard,
        // on saute les images plutôt que de les empiler.
        let accepted: Bool = lock.withLock {
            guard !isShutDown, frameGeneration == generation, !isBusy else { return false }
            isBusy = true
            return true
        }
        guard accepted else { return }
        queue.async { [weak self] in
            self?.process(frame, generation: frameGeneration)
        }
    }

    private func process(_ frame: SampledFrame, generation frameGeneration: Int) {
        let lit = Self.hasLitPixel(frame)
        let colors = pipeline.process(frame)
        let current: Bool = lock.withLock {
            isBusy = false
            guard !isShutDown, frameGeneration == generation else { return false }
            frameCount += 1
            if lit { sawLitFrame = true }
            return true
        }
        guard current else { return }
        streamer.submit(colors, capturedAt: frame.timestamp)
    }

    private static func hasLitPixel(_ frame: SampledFrame) -> Bool {
        let count = frame.width * frame.height * 4
        return frame.rgba.withUnsafeBufferPointer { pixels -> Bool in
            var index = 0
            while index + 2 < count {
                if pixels[index] >= litThreshold
                    || pixels[index + 1] >= litThreshold
                    || pixels[index + 2] >= litThreshold {
                    return true
                }
                index += 4
            }
            return false
        }
    }
}

// MARK: - Mise en place du flux (partagée avec le test des lumières)

/// Étapes réseau communes à la session et au test des lumières. Non isolé : les
/// complétions (file du transport) ne sont jamais rattachées au main actor.
enum HueStreamSetup {
    /// Zone à jour (GET), avec contrôle des canaux et de l'occupation par une autre app.
    static func availableArea(client: HueBridgeClient,
                              areaID: String,
                              credentials: HueCredentials) async throws -> HueEntertainmentArea {
        let area = try await client.entertainmentArea(id: areaID, username: credentials.username)
        guard !area.channels.isEmpty else { throw HueError.noEntertainmentArea }
        if area.isStreaming, let owner = area.activeStreamerID?.lowercased() {
            // Un flux actif d'une autre application (Hue Sync, Sync Box…) : on ne le vole pas.
            // Le nôtre (session précédente interrompue) peut être repris. Le `rid` du flux est
            // notre application ID : relue si elle manque, sinon notre propre flux resté actif
            // passerait pour celui d'une autre app.
            var applicationID = credentials.applicationID
            if applicationID == nil {
                applicationID = try? await client.applicationID(username: credentials.username)
            }
            let ours = [applicationID, credentials.username].compactMap { $0?.lowercased() }
            if !ours.contains(owner) { throw HueError.areaInUseByAnotherApp }
        }
        return area
    }

    /// Réserve la zone (PUT start). Si un flux à nous est resté actif (session précédente
    /// interrompue, PUT stop perdu ou app tuée il y a moins de 10 s), on l'arrête d'abord,
    /// comme Hyperion : le pont oublie l'ancienne association DTLS. Le PUT start qui suit
    /// est retenté jusqu'à 3 fois (500 ms d'écart), sauf délai dépassé ou annulation.
    /// `area` doit venir de `availableArea` : une zone active y est forcément la nôtre.
    static func claim(client: HueBridgeClient, area: HueEntertainmentArea, username: String) async throws {
        guard area.isStreaming else {
            try await client.setStreaming(true, areaID: area.id, username: username)
            return
        }
        try? await client.setStreaming(false, areaID: area.id, username: username)
        for attempt in 1...3 {
            do {
                try await client.setStreaming(true, areaID: area.id, username: username)
                return
            } catch {
                if attempt == 3 || error is CancellationError { throw error }
                if case HueError.timeout = error { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Identités PSK à essayer, dans l'ordre : application ID puis username.
    static func pskIdentities(for credentials: HueCredentials) -> [String] {
        var identities: [String] = []
        for identity in [credentials.applicationID, credentials.username].compactMap({ $0 })
        where !identity.isEmpty && !identities.contains(identity) {
            identities.append(identity)
        }
        return identities
    }

    /// Poignée de main DTLS, convertie en async. L'annulation de la Task ferme le transport.
    static func connect(_ transport: HueDatagramTransport,
                        host: String,
                        identity: String,
                        pskHex: String,
                        timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                transport.connect(host: host,
                                  pskIdentity: identity,
                                  pskHex: pskHex,
                                  timeout: timeout) { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            transport.close()
        }
        if Task.isCancelled {
            transport.close()
            throw CancellationError()
        }
    }

    /// Libérations de zone (PUT stop) encore en vol, y compris celle différée par un PUT start
    /// en cours. Toute nouvelle réservation les attend : sinon un « stop » tardif d'une session
    /// précédente (ou du test des lumières) désactiverait la zone sous la nouvelle session.
    @MainActor private static var pendingRelease: Task<Void, Never>?

    /// Ajoute `task` aux libérations que la prochaine réservation doit attendre.
    /// `task` ne doit pas elle-même attendre les libérations (`waitForPendingReleases`) après
    /// cet appel, sauf si elle est déjà annulée : sinon elle s'attendrait elle-même.
    @MainActor
    static func trackRelease(_ task: Task<Void, Never>) {
        let previous = pendingRelease
        pendingRelease = Task {
            await previous?.value
            await task.value
        }
    }

    /// Attend la fin des libérations en vol, y compris celles ajoutées pendant l'attente
    /// (chaque requête est bornée par le délai de 8 s du client). Sort dès que la tâche
    /// appelante est annulée, entre deux libérations (attendre une Task n'est pas annulable :
    /// l'appelant revérifie l'annulation au retour).
    @MainActor
    static func waitForPendingReleases() async {
        while !Task.isCancelled, let current = pendingRelease {
            await current.value
            if pendingRelease == current { pendingRelease = nil }
        }
    }

    /// Libère la zone (PUT stop) dans une Task détachée, puis invalide le client.
    /// Demande un peu de temps d'exécution en arrière-plan pour que la requête parte
    /// même si l'app vient d'être suspendue. La prochaine réservation attend cette libération.
    @MainActor
    static func release(client: HueBridgeClient, areaID: String, username: String) {
        let background = BackgroundTaskToken.begin(name: "Hue : libération de la zone")
        trackRelease(Task.detached {
            try? await client.setStreaming(false, areaID: areaID, username: username)
            client.invalidate()
            await background.end()
        })
    }
}

/// Jeton de tâche d'arrière-plan UIKit (fin idempotente, sur le main actor).
@MainActor
final class BackgroundTaskToken {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(name: String) -> BackgroundTaskToken {
        let token = BackgroundTaskToken()
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak token] in
            // Appelé par le système sur le thread principal quand le délai expire.
            MainActor.assumeIsolated { token?.end() }
        }
        return token
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
