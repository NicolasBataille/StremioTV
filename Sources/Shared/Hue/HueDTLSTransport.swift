import Foundation
import Network
import Security

/// DTLS 1.2 PSK (TLS_PSK_WITH_AES_128_GCM_SHA256 = 0x00A8) vers <host>:2100 via Network.framework.
///
/// Le pont Hue n'accepte que cette suite pour le flux HueStream : clé PSK = `clientkey` de l'appairage
/// (16 octets, transmis en 32 caractères hexadécimaux), identité = `hue-application-id` (ou, à défaut,
/// le `username`). Aucun certificat n'est échangé en PSK ; le bloc de vérification accepte donc tout.
///
/// Thread-safety : `connect`, `send` et `close` sont appelables depuis n'importe quelle file.
/// Un datagramme = un enregistrement DTLS ; `send` n'attend aucun accusé et ne bloque jamais.
final class HueDTLSTransport: HueDatagramTransport {

    private static let port: NWEndpoint.Port = 2100
    /// TLS_PSK_WITH_AES_128_GCM_SHA256 (RFC 5487). Absente de l'énumération `tls_ciphersuite_t`,
    /// mais une énumération C importée accepte toute valeur brute.
    private static let pskCipherSuite: UInt16 = 0x00A8

    private let queue = DispatchQueue(label: "com.nicolasbataille.stremiotv.hue.dtls", qos: .userInteractive)

    // MARK: État protégé par `lock`

    private let lock = NSLock()
    private var connection: NWConnection?
    /// `true` une fois le handshake terminé (état `.ready`) : `send` n'envoie qu'à ce moment-là.
    private var isReady = false
    private var _onConnectionLost: (@Sendable (String) -> Void)?

    /// Appelé une fois, sur la file du transport, si une session DTLS **établie** se termine sans
    /// `close()` (`.failed`, `.waiting` ou annulation par le système). Hors protocole
    /// `HueDatagramTransport` (contrat figé) : utilisé par `AmbilightSession` pour se reconnecter.
    var onConnectionLost: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onConnectionLost } }
        set { lock.withLock { _onConnectionLost = newValue } }
    }

    /// `true` tant que la session DTLS est établie (handshake terminé, ni perdue ni fermée). Thread-safe.
    var isConnected: Bool { lock.withLock { isReady } }

    init() {}

    deinit {
        close()
    }

    /// Établit la session DTLS. `completion` est appelée une seule fois, sur une file quelconque :
    /// `.ready` → succès ; `.failed`, `.waiting`, fermeture ou délai dépassé → `HueError.handshakeFailed`.
    /// Une connexion précédente éventuelle est fermée.
    func connect(host: String,
                 pskIdentity: String,
                 pskHex: String,
                 timeout: TimeInterval,
                 completion: @escaping (Result<Void, Error>) -> Void) {
        let once = CompletionOnce(completion)

        guard let psk = Self.bytes(fromHex: pskHex), !psk.isEmpty else {
            once.take()?(.failure(HueError.handshakeFailed("clé PSK invalide")))
            return
        }
        guard !pskIdentity.isEmpty else {
            once.take()?(.failure(HueError.handshakeFailed("identité PSK vide")))
            return
        }
        let bareHost = Self.stripBrackets(host.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !bareHost.isEmpty else {
            once.take()?(.failure(HueError.handshakeFailed("adresse du pont vide")))
            return
        }
        guard let cipherSuite = tls_ciphersuite_t(rawValue: Self.pskCipherSuite) else {
            once.take()?(.failure(HueError.handshakeFailed("suite TLS PSK indisponible")))
            return
        }

        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .DTLSv12)
        sec_protocol_options_append_tls_ciphersuite(security, cipherSuite)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(security, pskData as __DispatchData, identityData as __DispatchData)
        sec_protocol_options_set_verify_block(security, { (_: sec_protocol_metadata_t,
                                                           _: sec_trust_t,
                                                           complete: @escaping sec_protocol_verify_complete_t) in
            complete(true)
        }, queue)

        let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(bareHost), port: Self.port, using: parameters)

        let previous: NWConnection? = lock.withLock {
            let previous = self.connection
            self.connection = connection
            isReady = false
            return previous
        }
        previous?.cancel()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                guard let complete = once.take() else { return }
                if let connection { self?.markReady(connection) }
                complete(.success(()))
            case .waiting(let error):
                // Pour un handshake DTLS, `.waiting` signifie en pratique un échec (réseau, PSK refusée…) ;
                // après `.ready`, la session est perdue.
                let complete = once.take()
                if let connection {
                    self?.lose(connection, reason: error.localizedDescription)
                    connection.cancel()
                }
                complete?(.failure(HueError.handshakeFailed(error.localizedDescription)))
            case .failed(let error):
                let complete = once.take()
                if let connection {
                    self?.lose(connection, reason: error.localizedDescription)
                    connection.cancel()
                }
                complete?(.failure(HueError.handshakeFailed(error.localizedDescription)))
            case .cancelled:
                if let connection { self?.lose(connection, reason: "connexion fermée") }
                once.take()?(.failure(HueError.handshakeFailed("connexion fermée")))
            default:
                break
            }
        }

        // La connexion est retenue jusqu'au délai : la complétion est garantie au plus tard à ce moment.
        queue.asyncAfter(deadline: .now() + max(0.5, timeout)) { [weak self] in
            guard let complete = once.take() else { return }
            self?.drop(connection)
            connection.cancel()
            complete(.failure(HueError.handshakeFailed("le pont n'a pas répondu à temps")))
        }

        connection.start(queue: queue)
    }

    /// Envoie un datagramme HueStream (ignoré tant que le handshake n'est pas terminé ou après `close`).
    func send(_ datagram: Data) {
        let connection: NWConnection? = lock.withLock { isReady ? self.connection : nil }
        connection?.send(content: datagram, completion: .idempotent)
    }

    /// Ferme la session (idempotent). La connexion est oubliée avant l'annulation : une fermeture
    /// volontaire ne déclenche jamais `onConnectionLost`.
    func close() {
        let connection: NWConnection? = lock.withLock {
            let connection = self.connection
            self.connection = nil
            isReady = false
            return connection
        }
        connection?.cancel()
    }

    // MARK: - Privé

    private func markReady(_ connection: NWConnection) {
        lock.withLock {
            if self.connection === connection { isReady = true }
        }
    }

    /// Oublie `connection` si c'est la connexion courante (échec ou fermeture).
    private func drop(_ connection: NWConnection) {
        lock.withLock {
            if self.connection === connection {
                self.connection = nil
                isReady = false
            }
        }
    }

    /// Comme `drop`, et prévient `onConnectionLost` si la session de `connection` était établie
    /// (perte en cours de flux ; après `close()` la connexion n'est plus la courante : rien).
    private func lose(_ connection: NWConnection, reason: String) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard self.connection === connection else { return nil }
            let wasReady = isReady
            self.connection = nil
            isReady = false
            return wasReady ? _onConnectionLost : nil
        }
        handler?(reason)
    }

    /// Décode une chaîne hexadécimale (longueur paire) ; nil si invalide.
    private static func bytes(fromHex hex: String) -> Data? {
        let digits = Array(hex.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard digits.count % 2 == 0 else { return nil }
        var data = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else { return host }
        return String(host.dropFirst().dropLast())
    }
}

/// Complétion de `connect` à n'appeler qu'une fois : `take()` la rend au premier appelant seulement.
private final class CompletionOnce {
    private let lock = NSLock()
    private var completion: ((Result<Void, Error>) -> Void)?

    init(_ completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
    }

    func take() -> ((Result<Void, Error>) -> Void)? {
        lock.withLock {
            defer { completion = nil }
            return completion
        }
    }
}
