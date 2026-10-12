import UIKit
import Observation
#if os(tvOS)
import TVVLCKit
#else
import MobileVLCKit
#endif

/// État applicatif des lumières Philips Hue (Ambilight) : pont associé, zones de
/// divertissement, appairage, test des lumières et session de la lecture en cours.
///
/// Injecté dans l'environnement SwiftUI (`.environment(HueSyncService.shared)`) pour
/// l'écran de réglages ; le lecteur l'utilise via `HueSyncService.shared.makeSession(…)`.
/// Les sessions remontent leur état ici (main actor uniquement).
@Observable
@MainActor
final class HueSyncService {
    static let shared = HueSyncService()

    enum Status: Equatable {
        /// Pas de pont associé.
        case notConfigured
        /// Associé, rien en cours.
        case ready
        case connecting
        case streaming(captureName: String)
        case error(String)
    }

    private(set) var status: Status
    private(set) var credentials: HueCredentials?
    private(set) var areas: [HueEntertainmentArea] = []
    private(set) var discoveredBridges: [HueBridgeCandidate] = []
    private(set) var isDiscovering = false
    private(set) var isPairing = false
    private(set) var lastError: String?
    /// Ligne de diagnostic de la session en cours (ex. « Capture de la vue · 11 img/s · 50 paquets/s »).
    private(set) var diagnostics: String?
    let preferences: HuePreferences

    /// Copie observable de `preferences.selectedAreaID` (UserDefaults n'est pas observé).
    private var selectedAreaID: String?
    /// Copie observable de `preferences.isEnabled` (UserDefaults n'est pas observé).
    private(set) var isPlaybackSyncEnabled: Bool
    /// Une zone est choisie (mêmes conditions que `makeSession`).
    var hasSelectedArea: Bool { selectedAreaID != nil }

    private let store: HueCredentialStore
    @ObservationIgnored private var activeSession: AmbilightSession?
    @ObservationIgnored private var pairingTask: Task<Void, Never>?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private var rediscoveryTask: Task<Bool, Never>?

    var isPaired: Bool { credentials != nil }

    var selectedArea: HueEntertainmentArea? {
        guard let selectedAreaID else { return nil }
        return areas.first { $0.id == selectedAreaID }
    }

    init(preferences: HuePreferences = HuePreferences(), store: HueCredentialStore = HueCredentialStore()) {
        self.preferences = preferences
        self.store = store
        let credentials = store.load()
        self.credentials = credentials
        self.status = credentials == nil ? .notConfigured : .ready
        self.selectedAreaID = preferences.selectedAreaID
        self.isPlaybackSyncEnabled = preferences.isEnabled
        if credentials != nil, preferences.isEnabled {
            // Zones à jour (et adresse du pont revérifiée) avant la 1re lecture, sans bloquer le lancement.
            // Désactivé : rien au lancement ; l'écran de réglages rafraîchit lui-même (`.task`).
            Task { [weak self] in await self?.refreshAreas() }
        }
    }

    // MARK: - Pont

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        lastError = nil
        let bridges = await HueDiscovery.discover()
        discoveredBridges = bridges
        isDiscovering = false
        if bridges.isEmpty {
            lastError = HueError.noBridgeFound.localizedDescription
        }
    }

    /// Appairage complet : bridgeConfig → pair (bouton) → applicationID → sauvegarde (avec empreinte TOFU)
    /// → refreshAreas → sélection auto de la 1re zone `screen` (sinon la 1re) si aucune n'est choisie.
    func pair(host: String) async {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isPairing else { return }
        guard !host.isEmpty else {
            lastError = "Adresse du pont invalide."
            return
        }
        isPairing = true
        lastError = nil
        let task = Task<Void, Never> { [weak self] in
            await self?.performPairing(host: host)
        }
        pairingTask = task
        await task.value
        pairingTask = nil
        isPairing = false
    }

    func cancelPairing() {
        pairingTask?.cancel()
    }

    private func performPairing(host: String) async {
        let client = HueBridgeClient(host: host, pinnedCertificateSHA256: nil)
        defer { client.invalidate() }
        do {
            let config = try await client.bridgeConfig()
            let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceType = "StremioTV#" + (device.isEmpty ? "Apple" : device)
            let keys = try await client.pair(deviceType: deviceType)
            // L'application ID sert d'identité DTLS ; à défaut, la session la relira.
            let applicationID = try? await client.applicationID(username: keys.username)
            try Task.checkCancellation()

            let previous = credentials
            let paired = HueCredentials(bridgeID: config.bridgeID,
                                        host: host,
                                        username: keys.username,
                                        clientKey: keys.clientKey,
                                        applicationID: applicationID,
                                        certificateSHA256: client.observedCertificateSHA256)
            if previous?.bridgeID != paired.bridgeID {
                // Autre pont : la zone choisie n'existe pas là-bas.
                setSelectedAreaID(nil)
                areas = []
            }
            store.save(paired)
            credentials = paired
            discoveredBridges = []
            if !isBusyStatus { status = .ready }

            await refreshAreas()
        } catch is CancellationError {
            // Annulé par l'utilisateur : pas d'erreur à afficher.
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unpair() {
        pairingTask?.cancel()
        testTask?.cancel()
        activeSession?.stop()
        activeSession = nil
        store.clear()
        credentials = nil
        areas = []
        setSelectedAreaID(nil)
        diagnostics = nil
        lastError = nil
        status = .notConfigured
    }

    // MARK: - Zones de divertissement

    func refreshAreas() async {
        guard let credentials else { return }
        let fetched: [HueEntertainmentArea]
        do {
            fetched = try await fetchAreas(credentials)
        } catch HueError.timeout {
            // Pont injoignable : son adresse IP a peut-être changé (DHCP).
            if isCurrentBridge(credentials), await rediscoverHost(), let updated = self.credentials {
                do {
                    fetched = try await fetchAreas(updated)
                } catch is CancellationError {
                    return
                } catch {
                    if isCurrentBridge(credentials) { lastError = error.localizedDescription }
                    return
                }
            } else {
                if isCurrentBridge(credentials) { lastError = HueError.timeout.localizedDescription }
                return
            }
        } catch is CancellationError {
            return
        } catch {
            if isCurrentBridge(credentials) { lastError = error.localizedDescription }
            return
        }
        // Dissocié (ou autre pont associé) pendant la requête : résultat périmé, on n'y touche pas.
        guard isCurrentBridge(credentials) else { return }
        areas = fetched
        lastError = nil
        // Zone choisie absente (aucune, ou supprimée dans l'app Hue) : 1re zone `screen`, sinon la 1re.
        if selectedArea == nil,
           let area = areas.first(where: { $0.configurationType == "screen" }) ?? areas.first {
            setSelectedAreaID(area.id)
        }
        if case .error = status { status = idleStatus }
    }

    /// Vrai si `credentials` désigne toujours le pont associé (ni dissocié ni remplacé entre-temps).
    private func isCurrentBridge(_ credentials: HueCredentials) -> Bool {
        self.credentials?.bridgeID == credentials.bridgeID
    }

    func selectArea(_ area: HueEntertainmentArea) {
        setSelectedAreaID(area.id)
    }

    /// Active / désactive la synchronisation pendant la lecture (préférence + copie observable).
    func setPlaybackSyncEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        isPlaybackSyncEnabled = preferences.isEnabled
    }

    private func fetchAreas(_ credentials: HueCredentials) async throws -> [HueEntertainmentArea] {
        let client = makeClient(credentials)
        defer { client.invalidate() }
        return try await client.entertainmentAreas(username: credentials.username)
    }

    // MARK: - Test des lumières

    /// Test ~6 s : réserve la zone, fait défiler rouge/vert/bleu/blanc canal par canal, puis libère.
    func testLights() async {
        guard testTask == nil, let credentials else { return }
        guard let areaID = selectedAreaID else {
            lastError = HueError.noEntertainmentArea.localizedDescription
            return
        }
        activeSession?.stop()
        activeSession = nil
        let task = Task<Void, Never> { [weak self] in
            await self?.performLightTest(credentials: credentials, areaID: areaID)
        }
        testTask = task
        await task.value
        testTask = nil
    }

    private func performLightTest(credentials: HueCredentials, areaID: String) async {
        setTestStatus(.connecting)
        lastError = nil
        let client = makeClient(credentials)
        let transport = HueDTLSTransport()
        var streamer: HueEntertainmentStreamer?
        var claimedAreaID: String?
        do {
            // Libération (PUT stop) d'une session de lecture qui vient de s'arrêter, encore en vol :
            // elle ne doit pas arriver au pont après notre PUT start. Avant le GET, pour lire l'état à jour.
            await HueStreamSetup.waitForPendingReleases()
            try Task.checkCancellation()
            let area = try await HueStreamSetup.availableArea(client: client, areaID: areaID, credentials: credentials)
            try Task.checkCancellation()
            // PUT start refusé (zone tenue par Hue Sync, une Sync Box…) : la zone n'est pas à nous,
            // on ne lui enverra pas de stop. Requête non annulable : on sait toujours si elle a abouti.
            // `claim` arrête d'abord un flux à nous resté actif (session interrompue), comme la session.
            do {
                try await Task {
                    try await HueStreamSetup.claim(client: client, area: area, username: credentials.username)
                }.value
            } catch {
                if case HueError.timeout = error { throw error }
                throw area.isStreaming && !(error is CancellationError) ? HueError.areaInUseByAnotherApp : error
            }
            // Réservée : libérée à la fin quoi qu'il arrive (annulation comprise).
            claimedAreaID = area.id
            try Task.checkCancellation()

            var connected = false
            var handshakeError: Error = HueError.handshakeFailed("aucune identité")
            for identity in HueStreamSetup.pskIdentities(for: credentials) {
                do {
                    try await HueStreamSetup.connect(transport,
                                                     host: credentials.host,
                                                     identity: identity,
                                                     pskHex: credentials.clientKey,
                                                     timeout: 5)
                    connected = true
                    break
                } catch {
                    handshakeError = error
                    try Task.checkCancellation()
                }
            }
            guard connected else { throw handshakeError }

            let channelIDs = area.channels.map(\.id)
            let pump = HueEntertainmentStreamer(areaID: area.id, channelIDs: channelIDs, transport: transport)
            pump.smoothingTimeConstant = 0.05
            pump.start()
            streamer = pump
            setTestStatus(.streaming(captureName: "Test des lumières"))

            let palette: [HueRGB] = [HueRGB(r: 1, g: 0, b: 0),
                                     HueRGB(r: 0, g: 1, b: 0),
                                     HueRGB(r: 0, g: 0, b: 1),
                                     HueRGB(r: 1, g: 1, b: 1)]
            // ~6 s au total, entre 0,15 s et 1,5 s par canal.
            let stepCount = max(1, palette.count * channelIDs.count)
            let stepSeconds = min(1.5, max(0.15, 6.0 / Double(stepCount)))
            for color in palette {
                for lit in channelIDs {
                    let colors = channelIDs.map { HueChannelColor(channelID: $0, color: $0 == lit ? color : .black) }
                    pump.submit(colors, capturedAt: ProcessInfo.processInfo.systemUptime)
                    try await Task.sleep(nanoseconds: UInt64(stepSeconds * 1_000_000_000))
                }
            }
            setTestStatus(idleStatus)
        } catch is CancellationError {
            setTestStatus(idleStatus)
        } catch {
            if case HueError.timeout = error { bridgeSeemsUnreachable() }
            lastError = error.localizedDescription
            setTestStatus(.error(error.localizedDescription))
        }

        streamer?.stop()
        transport.close()
        if let claimedAreaID {
            // Détachée : la libération part même si la tâche de test a été annulée.
            HueStreamSetup.release(client: client, areaID: claimedAreaID, username: credentials.username)
        } else {
            client.invalidate()
        }
    }

    // MARK: - Sessions de lecture

    /// Session pour le lecteur si activé + associé + zone choisie ; sinon nil. Une seule session active à la fois
    /// (une nouvelle arrête la précédente).
    func makeSession(videoView: UIView, player: VLCMediaPlayer) -> AmbilightSession? {
        activeSession?.stop()
        activeSession = nil
        guard preferences.isEnabled,
              let credentials,
              let areaID = selectedAreaID else { return nil }
        if let testTask {
            // Annulé d'abord, suivi ensuite : sa propre attente des libérations voit l'annulation
            // et ne s'attend pas elle-même. La session attendra la fin du test (et son PUT stop).
            testTask.cancel()
            HueStreamSetup.trackRelease(testTask)
        }
        let session = AmbilightSession(service: self,
                                       credentials: credentials,
                                       areaID: areaID,
                                       preferences: preferences,
                                       videoView: videoView,
                                       player: player)
        activeSession = session
        return session
    }

    /// App en arrière-plan : arrête la session active (libère la zone).
    /// Elle reprend au retour au premier plan (`resumeSuspendedSession()`) ou à la reprise de la lecture.
    func suspendActiveSession() {
        activeSession?.suspend()
    }

    /// Retour au premier plan : relance la session suspendue, si la lecture est toujours ouverte.
    func resumeSuspendedSession() {
        activeSession?.restartIfSuspended()
    }

    // MARK: - Remontées des sessions (main actor)

    func sessionIsConnecting(_ session: AmbilightSession) {
        guard session === activeSession else { return }
        status = .connecting
    }

    func sessionIsStreaming(_ session: AmbilightSession, captureName: String) {
        guard session === activeSession else { return }
        status = .streaming(captureName: captureName)
        lastError = nil
    }

    func sessionDiagnostics(_ session: AmbilightSession, _ text: String) {
        guard session === activeSession, diagnostics != text else { return }
        diagnostics = text
    }

    /// Fin (ou suspension) d'une session. `error` non nil → statut d'erreur.
    func sessionDidEnd(_ session: AmbilightSession, error: String?) {
        guard session === activeSession else { return }
        if !session.isSuspended { activeSession = nil }
        if let error {
            reportError(error)
        } else if isBusyStatus {
            status = idleStatus
        }
        // L'écran de réglages n'est pas visible pendant la lecture (tvOS) : on garde le dernier bilan.
        if let diagnostics, !diagnostics.hasPrefix(Self.lastSessionPrefix) {
            self.diagnostics = Self.lastSessionPrefix + diagnostics
        }
    }

    /// Application ID relue par une session (anciens identifiants) : on la persiste.
    func rememberApplicationID(_ applicationID: String) {
        guard var credentials, credentials.applicationID == nil else { return }
        credentials.applicationID = applicationID
        store.save(credentials)
        self.credentials = credentials
    }

    /// Le pont ne répond plus : relance une recherche en arrière-plan pour retrouver son adresse.
    func bridgeSeemsUnreachable() {
        Task { [weak self] in _ = await self?.rediscoverHost() }
    }

    // MARK: - Privé

    private static let lastSessionPrefix = "Dernière session : "

    private var idleStatus: Status { credentials == nil ? .notConfigured : .ready }

    private var isBusyStatus: Bool {
        switch status {
        case .connecting, .streaming: return true
        case .notConfigured, .ready, .error: return false
        }
    }

    private func reportError(_ message: String) {
        lastError = message
        status = .error(message)
    }

    /// Statut du test des lumières, sauf si une session de lecture a pris la main entre-temps.
    private func setTestStatus(_ newStatus: Status) {
        guard activeSession == nil else { return }
        status = newStatus
    }

    private func setSelectedAreaID(_ id: String?) {
        preferences.selectedAreaID = id
        selectedAreaID = preferences.selectedAreaID
    }

    private func makeClient(_ credentials: HueCredentials) -> HueBridgeClient {
        HueBridgeClient(host: credentials.host, pinnedCertificateSHA256: credentials.certificateSHA256)
    }

    /// Recherche le pont associé (même identifiant) et met à jour son adresse si elle a changé.
    /// Renvoie true si l'adresse a été mise à jour.
    private func rediscoverHost() async -> Bool {
        if let rediscoveryTask { return await rediscoveryTask.value }
        let task = Task { [weak self] () -> Bool in
            guard let bridgeID = self?.credentials?.bridgeID.lowercased() else { return false }
            let bridges = await HueDiscovery.discover()
            guard let self,
                  var credentials = self.credentials,
                  credentials.bridgeID.lowercased() == bridgeID,
                  let match = bridges.first(where: { $0.id.lowercased() == bridgeID }),
                  match.host != credentials.host else { return false }
            credentials.host = match.host
            self.store.save(credentials)
            self.credentials = credentials
            return true
        }
        rediscoveryTask = task
        let updated = await task.value
        rediscoveryTask = nil
        return updated
    }
}
