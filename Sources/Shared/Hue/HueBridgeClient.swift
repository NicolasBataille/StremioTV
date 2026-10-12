import CryptoKit
import Foundation
import Security

/// Client HTTPS d'un pont Hue : appairage (API v1 `POST /api`), identifiant d'application (`/auth/v1`)
/// et ressources CLIP v2 des zones de divertissement.
///
/// Confiance TOFU : le certificat du pont est signé par l'autorité privée de Signify (ou auto-signé
/// sur les anciens firmwares), l'évaluation système échoue donc toujours. On accepte le certificat
/// feuille au premier contact et on mémorise son empreinte SHA-256 (`observedCertificateSHA256`) ;
/// ensuite, avec une empreinte épinglée, seul ce certificat est accepté.
///
/// Tout l'encodage / décodage JSON passe par `HueAPI`. Toute erreur remonte en `HueError`
/// (ou `CancellationError` si la `Task` appelante est annulée).
///
/// La `URLSession` retient son délégué (`self`) : appeler `invalidate()` quand le client ne sert plus.
/// `@unchecked Sendable` : tout l'état mutable est protégé par `lock` (`URLSessionDelegate` est `Sendable`).
final class HueBridgeClient: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// Délai de chaque requête HTTPS.
    private static let requestTimeout: TimeInterval = 8

    let host: String

    /// Empreinte SHA-256 (hex minuscule) du certificat feuille vu lors du dernier handshake TLS. Thread-safe.
    var observedCertificateSHA256: String? {
        lock.withLock { observedFingerprint }
    }

    private let pinnedCertificateSHA256: String?
    /// Hôte tel qu'il apparaît dans l'URL (IPv6 littérale entre crochets, `%` de zone échappé).
    private let urlHost: String
    /// Hôte sans crochets, en minuscules, pour la comparaison avec `protectionSpace.host`.
    private let bareHost: String

    // MARK: État protégé par `lock`

    private let lock = NSLock()
    /// `nil` après `invalidate()` : aucune nouvelle tâche ne peut plus être créée.
    private var session: URLSession?
    private var observedFingerprint: String?
    /// `true` si le dernier défi TLS a été refusé parce que l'empreinte ne correspondait pas à l'épinglée.
    private var lastTrustRejected = false

    init(host: String, pinnedCertificateSHA256: String?) {
        self.host = host
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = Self.stripBrackets(trimmed)
        bareHost = bare.lowercased()
        if bare.contains(":") {
            // IPv6 littérale : crochets obligatoires, et le « % » de l'identifiant de zone s'écrit « %25 ».
            urlHost = "[" + bare.replacingOccurrences(of: "%", with: "%25") + "]"
        } else {
            urlHost = bare
        }
        self.pinnedCertificateSHA256 = pinnedCertificateSHA256.flatMap(Self.normalizedFingerprint)
        super.init()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Appairage

    /// `GET /api/0/config` (sans authentification) : identifiant et nom du pont.
    func bridgeConfig() async throws -> (bridgeID: String, name: String) {
        let (data, _) = try await perform(method: "GET", path: "/api/0/config")
        return try HueAPI.decodeBridgeConfig(data)
    }

    /// Interroge POST /api chaque seconde jusqu'à l'appui sur le bouton (ou `timeout` → HueError.linkButtonTimeout).
    /// Respecte l'annulation de la Task (CancellationError).
    func pair(deviceType: String, timeout: TimeInterval = 30) async throws -> (username: String, clientKey: String) {
        let body = HueAPI.pairingBody(deviceType: deviceType)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            try Task.checkCancellation()
            let (data, _) = try await perform(method: "POST", path: "/api", body: body)
            switch try HueAPI.decodePairing(data) {
            case .success(let username, let clientKey):
                return (username, clientKey)
            case .failure(let type, let description):
                throw HueError.bridge(description.isEmpty ? "erreur \(type)" : description)
            case .linkButtonNotPressed:
                break
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HueError.linkButtonTimeout }
            // `Task.sleep` lève CancellationError si la Task est annulée pendant l'attente.
            try await Task.sleep(nanoseconds: UInt64(min(1, remaining) * 1_000_000_000))
        }
    }

    /// `GET /auth/v1` : l'en-tête de réponse `hue-application-id` est l'identité PSK du flux DTLS.
    func applicationID(username: String) async throws -> String {
        let (_, response) = try await perform(method: "GET", path: "/auth/v1", applicationKey: username)
        guard let value = response.value(forHTTPHeaderField: "hue-application-id")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { throw HueError.invalidResponse }
        return value
    }

    // MARK: - Zones de divertissement

    /// `GET /clip/v2/resource/entertainment_configuration` : toutes les zones du pont.
    func entertainmentAreas(username: String) async throws -> [HueEntertainmentArea] {
        let (data, _) = try await perform(method: "GET",
                                          path: "/clip/v2/resource/entertainment_configuration",
                                          applicationKey: username)
        return try HueAPI.decodeAreas(data)
    }

    /// `GET /clip/v2/resource/entertainment_configuration/{id}` : état à jour d'une zone.
    func entertainmentArea(id: String, username: String) async throws -> HueEntertainmentArea {
        let (data, _) = try await perform(method: "GET",
                                          path: try Self.configurationPath(id),
                                          applicationKey: username)
        let areas = try HueAPI.decodeAreas(data)
        let wanted = id.lowercased()
        guard let area = areas.first(where: { $0.id == wanted }) ?? areas.first else {
            throw HueError.noEntertainmentArea
        }
        return area
    }

    /// `PUT /clip/v2/resource/entertainment_configuration/{id}` avec `{"action":"start"|"stop"}` :
    /// réserve (ou libère) la zone pour le flux HueStream.
    func setStreaming(_ active: Bool, areaID: String, username: String) async throws {
        let (data, _) = try await perform(method: "PUT",
                                          path: try Self.configurationPath(areaID),
                                          applicationKey: username,
                                          body: HueAPI.streamingActionBody(start: active))
        try HueAPI.checkErrors(data)
    }

    /// Invalide la URLSession (casse le cycle délégué). Le client est inutilisable ensuite.
    /// Les requêtes déjà parties (ex. le `PUT stop` de fin de session) vont à leur terme
    /// (`finishTasksAndInvalidate`) ; les suivantes échouent avec `HueError.notConfigured`.
    func invalidate() {
        let current: URLSession? = lock.withLock {
            let current = session
            session = nil
            return current
        }
        current?.finishTasksAndInvalidate()
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.stripBrackets(space.host).lowercased() == bareHost,
              let trust = space.serverTrust,
              let fingerprint = Self.leafFingerprint(of: trust)
        else { return (.performDefaultHandling, nil) }

        let accepted = pinnedCertificateSHA256.map { $0 == fingerprint } ?? true
        lock.withLock {
            observedFingerprint = fingerprint
            lastTrustRejected = !accepted
        }
        guard accepted else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    // MARK: - Requêtes

    private func perform(method: String,
                         path: String,
                         applicationKey: String? = nil,
                         body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "https://\(urlHost)\(path)") else { throw HueError.invalidResponse }
        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let applicationKey {
            request.setValue(applicationKey, forHTTPHeaderField: "hue-application-key")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let result: (data: Data, response: URLResponse)
        do {
            result = try await load(request)
        } catch {
            throw mapError(error)
        }
        guard let http = result.response as? HTTPURLResponse else { throw HueError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HueError.http(status: http.statusCode) }
        return (result.data, http)
    }

    /// Lance une tâche de données. La tâche est créée sous le verrou, ce qui évite de créer une tâche
    /// sur une session invalidée entre-temps (exception Objective-C). Annulation de la Task → annulation
    /// de la requête.
    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let handle = DataTaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task: URLSessionDataTask? = lock.withLock {
                    session?.dataTask(with: request) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let response {
                            continuation.resume(returning: (data ?? Data(), response))
                        } else {
                            continuation.resume(throwing: HueError.invalidResponse)
                        }
                    }
                }
                guard let task else {
                    continuation.resume(throwing: HueError.notConfigured)
                    return
                }
                let attached = handle.attach(task)
                task.resume()
                if !attached { task.cancel() }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private func mapError(_ error: Error) -> Error {
        if error is HueError || error is CancellationError { return error }
        guard let urlError = error as? URLError else { return HueError.bridge(error.localizedDescription) }
        let trustRejected = lock.withLock { lastTrustRejected }
        switch urlError.code {
        case .timedOut:
            return HueError.timeout
        case .cancelled:
            if trustRejected { return Self.certificateChangedError }
            return CancellationError()
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet:
            // Pont injoignable (éteint, adresse IP changée…).
            return HueError.timeout
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            if trustRejected { return Self.certificateChangedError }
            return HueError.bridge(urlError.localizedDescription)
        default:
            return HueError.bridge(urlError.localizedDescription)
        }
    }

    private static let certificateChangedError = HueError.bridge(
        "son certificat a changé depuis l'association. Dissocie puis associe à nouveau le pont."
    )

    // MARK: - Utilitaires

    /// Chemin CLIP v2 d'une zone, identifiant échappé (un UUID en pratique).
    private static func configurationPath(_ id: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
        else { throw HueError.noEntertainmentArea }
        return "/clip/v2/resource/entertainment_configuration/\(escaped)"
    }

    /// SHA-256 (hex minuscule) du certificat feuille (DER).
    private static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Empreinte normalisée : hex minuscule, sans « : » ni espaces. Vide → nil.
    private static func normalizedFingerprint(_ value: String) -> String? {
        let cleaned = value.lowercased().filter { $0.isHexDigit }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }
}

/// Tâche de données partagée entre la requête et le gestionnaire d'annulation de la `Task`.
private final class DataTaskHandle {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    /// Mémorise la tâche ; renvoie `false` si l'annulation a déjà eu lieu.
    func attach(_ task: URLSessionTask) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            self.task = task
            return true
        }
    }

    func cancel() {
        let task: URLSessionTask? = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}
