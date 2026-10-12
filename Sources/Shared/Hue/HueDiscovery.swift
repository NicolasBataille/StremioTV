import Foundation
import Network

/// Recherche des ponts Hue du réseau local.
///
/// Deux sources interrogées en parallèle :
/// - Bonjour `_hue._tcp` (`NWBrowser`, enregistrement TXT `bridgeid`), puis résolution de l'adresse IP
///   par une connexion TCP jetable dont on lit `currentPath.remoteEndpoint` ;
/// - le service de Signify `https://discovery.meethue.com` (limité en débit : résultat mis en cache).
///
/// Sur iOS, Bonjour exige `NSLocalNetworkUsageDescription` et `NSBonjourServices` (`_hue._tcp`) dans
/// l'Info.plist ; sur tvOS, aucune autorisation n'est demandée.
enum HueDiscovery {

    /// Bonjour `_hue._tcp` (NWBrowser) + https://discovery.meethue.com en parallèle, fusion par id, dans `timeout`.
    /// Ne lève jamais : renvoie [] si rien. Préférer les adresses IPv4.
    static func discover(timeout: TimeInterval = 5) async -> [HueBridgeCandidate] {
        let budget = max(1, timeout)
        async let local = bonjourCandidates(timeout: budget)
        async let remote = cloudCandidates(timeout: budget)
        let bonjour = await local
        let cloud = await remote
        return merge(bonjour: bonjour, cloud: cloud)
    }

    // MARK: - Fusion

    /// Fusionne par identifiant (Bonjour d'abord, plus frais) en préférant une adresse IPv4.
    /// Une entrée identifiée par sa seule adresse disparaît si un pont identifié a la même adresse.
    private static func merge(bonjour: [HueBridgeCandidate], cloud: [HueBridgeCandidate]) -> [HueBridgeCandidate] {
        var order: [String] = []
        var byID: [String: HueBridgeCandidate] = [:]
        for candidate in bonjour + cloud {
            if let existing = byID[candidate.id] {
                if !isIPv4(existing.host) && isIPv4(candidate.host) {
                    byID[candidate.id] = candidate
                }
            } else {
                byID[candidate.id] = candidate
                order.append(candidate.id)
            }
        }
        let merged = order.compactMap { byID[$0] }
        let identifiedHosts = Set(merged.filter { $0.id != $0.host.lowercased() }.map { $0.host.lowercased() })
        return merged.filter { candidate in
            let hostOnly = candidate.id == candidate.host.lowercased()
            return !(hostOnly && identifiedHosts.contains(candidate.host.lowercased()))
        }
    }

    private static func isIPv4(_ host: String) -> Bool {
        IPv4Address(host) != nil
    }

    // MARK: - discovery.meethue.com

    /// Un résultat récent est réutilisé tel quel (le service limite le nombre de requêtes).
    private static let cloudCacheLifetime: TimeInterval = 15 * 60
    private static let cloudCache = CloudCache()

    private static func cloudCandidates(timeout: TimeInterval) async -> [HueBridgeCandidate] {
        if let fresh = cloudCache.value(maxAge: cloudCacheLifetime) { return fresh }
        guard let url = URL(string: "https://discovery.meethue.com/") else { return [] }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return cloudCache.value(maxAge: .infinity) ?? []
            }
            let candidates = try HueAPI.decodeDiscovery(data)
            if !candidates.isEmpty { cloudCache.store(candidates) }
            return candidates
        } catch {
            // Hors ligne, limité (HTTP 429)… : dernier résultat connu, même ancien.
            return cloudCache.value(maxAge: .infinity) ?? []
        }
    }

    // MARK: - Bonjour

    private struct BonjourService {
        let endpoint: NWEndpoint
        /// `bridgeid` de l'enregistrement TXT, en minuscules.
        let bridgeID: String?
    }

    private static func bonjourCandidates(timeout: TimeInterval) async -> [HueBridgeCandidate] {
        let start = ProcessInfo.processInfo.systemUptime
        // Les réponses mDNS arrivent en général en moins d'une seconde ; le reste du budget sert à résoudre.
        let services = await browse(duration: min(max(1, timeout * 0.4), 2))
        let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
        guard !services.isEmpty, remaining > 0.2 else { return [] }

        return await withTaskGroup(of: HueBridgeCandidate?.self) { group in
            for service in services {
                group.addTask { await resolve(service, timeout: remaining) }
            }
            var candidates: [HueBridgeCandidate] = []
            for await candidate in group {
                if let candidate { candidates.append(candidate) }
            }
            return candidates
        }
    }

    /// Parcourt `_hue._tcp` pendant `duration` secondes et renvoie les services vus.
    private static func browse(duration: TimeInterval) async -> [BonjourService] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[BonjourService], Never>) in
            let queue = DispatchQueue(label: "com.nicolasbataille.stremiotv.hue.bonjour")
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: "local."),
                                    using: parameters)
            let collector = BrowseCollector(continuation)

            browser.browseResultsChangedHandler = { results, _ in
                collector.update(results.compactMap(Self.service(from:)))
            }
            browser.stateUpdateHandler = { [weak browser] state in
                if case .failed = state {
                    collector.finish()
                    browser?.cancel()
                }
            }
            queue.asyncAfter(deadline: .now() + duration) {
                collector.finish()
                browser.cancel()
            }
            browser.start(queue: queue)
        }
    }

    private static func service(from result: NWBrowser.Result) -> BonjourService? {
        guard case .service = result.endpoint else { return nil }
        var bridgeID: String?
        if case .bonjour(let record) = result.metadata,
           let raw = record["bridgeid"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            bridgeID = raw.lowercased()
        }
        return BonjourService(endpoint: result.endpoint, bridgeID: bridgeID)
    }

    /// Résout l'adresse IP d'un service : d'abord sans contrainte, puis en IPv4 seule si la première
    /// réponse est IPv6.
    private static func resolve(_ service: BonjourService, timeout: TimeInterval) async -> HueBridgeCandidate? {
        let start = ProcessInfo.processInfo.systemUptime
        guard let first = await resolveAddress(service.endpoint, version: .any, timeout: timeout) else {
            return nil
        }
        var host = first
        if !isIPv4(first) {
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - start)
            if remaining > 0.2,
               let v4 = await resolveAddress(service.endpoint, version: .v4, timeout: remaining) {
                host = v4
            }
        }
        return HueBridgeCandidate(id: service.bridgeID ?? host.lowercased(), host: host)
    }

    /// Connexion TCP jetable vers le service ; renvoie l'adresse IP distante une fois prête.
    private static func resolveAddress(_ endpoint: NWEndpoint,
                                       version: NWProtocolIP.Options.Version,
                                       timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let queue = DispatchQueue(label: "com.nicolasbataille.stremiotv.hue.resolve")
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = false
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = version
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let once = ResumeOnce(continuation)

            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    let address = connection?.currentPath?.remoteEndpoint.flatMap(Self.address(of:))
                    once.resume(address)
                    connection?.cancel()
                case .failed:
                    once.resume(nil)
                    connection?.cancel()
                case .cancelled:
                    once.resume(nil)
                default:
                    // .waiting : on laisse Network.framework réessayer jusqu'au délai.
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(nil)
                connection.cancel()
            }
            connection.start(queue: queue)
        }
    }

    /// Adresse textuelle d'un point de terminaison `hôte:port`.
    private static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return nil }
            return bytes.map(String.init).joined(separator: ".")
        case .ipv6(let address):
            let text = "\(address)"
            return text.isEmpty ? nil : text
        case .name(let name, _):
            return name.isEmpty ? nil : name
        @unknown default:
            return nil
        }
    }
}

// MARK: - Auxiliaires thread-safe

/// Reprend une continuation une seule fois, quel que soit le nombre d'appels.
private final class ResumeOnce<Value> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Dernier ensemble de résultats du navigateur Bonjour, livré une seule fois par `finish()`.
private final class BrowseCollector<Service> {
    private let lock = NSLock()
    private var services: [Service] = []
    private var continuation: CheckedContinuation<[Service], Never>?

    init(_ continuation: CheckedContinuation<[Service], Never>) {
        self.continuation = continuation
    }

    func update(_ services: [Service]) {
        lock.withLock { self.services = services }
    }

    func finish() {
        let (pending, result): (CheckedContinuation<[Service], Never>?, [Service]) = lock.withLock {
            defer { continuation = nil }
            return (continuation, services)
        }
        pending?.resume(returning: result)
    }
}

/// Cache mémoire du dernier résultat de discovery.meethue.com.
private final class CloudCache {
    private let lock = NSLock()
    private var candidates: [HueBridgeCandidate]?
    private var storedAt: TimeInterval = 0

    func value(maxAge: TimeInterval) -> [HueBridgeCandidate]? {
        lock.withLock {
            guard let candidates, ProcessInfo.processInfo.systemUptime - storedAt <= maxAge else { return nil }
            return candidates
        }
    }

    func store(_ candidates: [HueBridgeCandidate]) {
        lock.withLock {
            self.candidates = candidates
            storedAt = ProcessInfo.processInfo.systemUptime
        }
    }
}
