import Foundation

// Encodage / décodage JSON des API du pont Hue (CLIP v2, appairage v1, découverte).
// Fichier « pur » Foundation : aucune E/S réseau ici, uniquement des `Data` en entrée/sortie.

enum HueAPI {

    // MARK: - Zones de divertissement

    /// Décode GET /clip/v2/resource/entertainment_configuration (liste ou un seul élément `/{id}`).
    /// Enveloppe : {"errors":[{"description":…}], "data":[{ "id", "metadata":{"name"}, "configuration_type",
    /// "status":"active|inactive", "active_streamer":{"rid","rtype"}?, "channels":[{"channel_id",
    /// "position":{"x","y","z"}, "members":[…]}] , …}]}. Lève HueError.bridge si `errors` non vide.
    /// Tolère les champs inconnus/absents (metadata absent → nom "Zone", configuration_type absent → "other").
    /// Une entrée sans `id` est ignorée, de même qu'un canal sans `channel_id` valide (0…255).
    static func decodeAreas(_ data: Data) throws -> [HueEntertainmentArea] {
        try checkErrors(data)
        let envelope: AreaEnvelope
        do {
            envelope = try JSONDecoder().decode(AreaEnvelope.self, from: data)
        } catch {
            throw HueError.invalidResponse
        }
        guard let items = envelope.data else { throw HueError.invalidResponse }
        return items.compactMap { $0.area }
    }

    // MARK: - Appairage

    /// Décode la réponse de POST /api : [{"success":{"username","clientkey"}}] ou [{"error":{"type","description"}}]
    /// (type 101 → .linkButtonNotPressed). Réponse vide/illisible → throw HueError.invalidResponse.
    /// Un succès sans `clientkey` (inutilisable pour le flux DTLS) est aussi une réponse invalide.
    static func decodePairing(_ data: Data) throws -> HuePairingResult {
        let entries: [PairingEntry]
        if let list = try? JSONDecoder().decode([PairingEntry].self, from: data) {
            entries = list
        } else if let single = try? JSONDecoder().decode(PairingEntry.self, from: data) {
            entries = [single]
        } else {
            throw HueError.invalidResponse
        }
        // Un succès l'emporte sur d'éventuelles erreurs dans la même réponse.
        for entry in entries {
            if let success = entry.success {
                guard let username = success.username, !username.isEmpty,
                      let clientKey = success.clientkey, !clientKey.isEmpty
                else { throw HueError.invalidResponse }
                return .success(username: username, clientKey: clientKey)
            }
        }
        for entry in entries {
            if let error = entry.error, let type = error.type {
                if type == 101 { return .linkButtonNotPressed }
                return .failure(type: type, description: error.description ?? "")
            }
        }
        throw HueError.invalidResponse
    }

    /// Corps JSON de l'appairage : {"devicetype": deviceType (tronqué à 40 caractères), "generateclientkey": true}.
    static func pairingBody(deviceType: String) -> Data {
        encode(PairingBody(devicetype: String(deviceType.prefix(40)), generateclientkey: true))
    }

    // MARK: - Découverte

    /// Décode https://discovery.meethue.com : [{"id","internalipaddress","port"?}] → id en minuscules.
    /// Les entrées sans adresse sont ignorées ; sans `id`, l'hôte sert d'identifiant.
    static func decodeDiscovery(_ data: Data) throws -> [HueBridgeCandidate] {
        let entries: [DiscoveryEntry]
        do {
            entries = try JSONDecoder().decode([DiscoveryEntry].self, from: data)
        } catch {
            throw HueError.invalidResponse
        }
        var seen = Set<String>()
        var result: [HueBridgeCandidate] = []
        for entry in entries {
            guard let host = entry.internalipaddress?.trimmingCharacters(in: .whitespaces), !host.isEmpty
            else { continue }
            let rawID = entry.id?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = rawID.isEmpty ? host : rawID.lowercased()
            guard seen.insert(id).inserted else { continue }
            result.append(HueBridgeCandidate(id: id, host: host))
        }
        return result
    }

    /// Décode GET /api/0/config (sans authentification) : {"bridgeid":"001788FFFE…","name":…} → id en minuscules.
    /// Nom absent → « Pont Hue ». `bridgeid` absent → HueError.invalidResponse ; erreur v1 → HueError.bridge.
    static func decodeBridgeConfig(_ data: Data) throws -> (bridgeID: String, name: String) {
        if let errors = try? JSONDecoder().decode([PairingEntry].self, from: data),
           let error = errors.compactMap({ $0.error }).first {
            throw HueError.bridge(error.description ?? "erreur \(error.type ?? 0)")
        }
        guard let config = try? JSONDecoder().decode(BridgeConfig.self, from: data),
              let rawID = config.bridgeid?.trimmingCharacters(in: .whitespaces), !rawID.isEmpty
        else { throw HueError.invalidResponse }
        let name = config.name?.trimmingCharacters(in: .whitespaces) ?? ""
        return (rawID.lowercased(), name.isEmpty ? "Pont Hue" : name)
    }

    // MARK: - Flux

    /// Corps JSON {"action":"start"} ou {"action":"stop"}.
    static func streamingActionBody(start: Bool) -> Data {
        encode(ActionBody(action: start ? "start" : "stop"))
    }

    // MARK: - Erreurs CLIP v2

    /// Lève HueError.bridge(description) si le JSON est une enveloppe CLIP v2 avec `errors` non vide. Sinon ne fait rien.
    /// Plusieurs erreurs sont jointes par « ; ».
    static func checkErrors(_ data: Data) throws {
        guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
              let errors = envelope.errors, !errors.isEmpty
        else { return }
        let descriptions = errors.compactMap { $0.description?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        throw HueError.bridge(descriptions.isEmpty ? "erreur inconnue" : descriptions.joined(separator: " ; "))
    }

    // MARK: - Privé

    private static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // L'encodage de ces petites structures ne peut pas échouer en pratique.
        return (try? encoder.encode(value)) ?? Data()
    }

    private struct PairingBody: Encodable {
        let devicetype: String
        let generateclientkey: Bool
    }

    private struct ActionBody: Encodable {
        let action: String
    }

    private struct ErrorEnvelope: Decodable {
        struct Item: Decodable { let description: String? }
        let errors: [Item]?
    }

    private struct AreaEnvelope: Decodable {
        let data: [AreaDTO]?

        enum CodingKeys: String, CodingKey { case data }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let list = try? container.decode([Lenient<AreaDTO>].self, forKey: .data) {
                data = list.compactMap { $0.value }
            } else if let single = try? container.decode(AreaDTO.self, forKey: .data) {
                data = [single]
            } else {
                data = nil
            }
        }
    }

    /// Élément décodé « au mieux » : une entrée illisible devient `nil` sans faire échouer la liste.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    private struct AreaDTO: Decodable {
        struct Position: Decodable { let x: Double?; let y: Double?; let z: Double? }
        struct Channel: Decodable {
            let channelID: Int?
            let position: Position?
            enum CodingKeys: String, CodingKey {
                case channelID = "channel_id"
                case position
            }
        }
        struct Named: Decodable { let name: String? }
        struct Streamer: Decodable { let rid: String? }

        let id: String?
        let name: String?
        let configurationType: String?
        let status: String?
        let activeStreamerID: String?
        let channels: [Channel]

        enum CodingKeys: String, CodingKey {
            case id, metadata, status, channels
            case configurationType = "configuration_type"
            case activeStreamer = "active_streamer"
        }

        /// Chaque champ est décodé indépendamment : un champ de type inattendu est traité comme absent.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            name = (try? container.decode(Named.self, forKey: .metadata))?.name
            configurationType = try? container.decode(String.self, forKey: .configurationType)
            status = try? container.decode(String.self, forKey: .status)
            activeStreamerID = (try? container.decode(Streamer.self, forKey: .activeStreamer))?.rid
            let list = (try? container.decode([Lenient<Channel>].self, forKey: .channels)) ?? []
            channels = list.compactMap { $0.value }
        }

        var area: HueEntertainmentArea? {
            guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
            let name = name?.trimmingCharacters(in: .whitespaces) ?? ""
            let type = configurationType?.trimmingCharacters(in: .whitespaces) ?? ""
            let hueChannels: [HueChannel] = channels.compactMap { channel in
                guard let rawID = channel.channelID, let channelID = UInt8(exactly: rawID) else { return nil }
                return HueChannel(id: channelID,
                                  x: Self.finite(channel.position?.x),
                                  y: Self.finite(channel.position?.y),
                                  z: Self.finite(channel.position?.z))
            }
            let streamerID = activeStreamerID.flatMap { $0.isEmpty ? nil : $0 }
            return HueEntertainmentArea(id: id.lowercased(),
                                        name: name.isEmpty ? "Zone" : name,
                                        configurationType: type.isEmpty ? "other" : type,
                                        isStreaming: status == "active",
                                        activeStreamerID: streamerID,
                                        channels: hueChannels)
        }

        private static func finite(_ value: Double?) -> Double {
            guard let value, value.isFinite else { return 0 }
            return value
        }
    }

    private struct PairingEntry: Decodable {
        struct Success: Decodable { let username: String?; let clientkey: String? }
        struct Failure: Decodable { let type: Int?; let description: String? }
        let success: Success?
        let error: Failure?
    }

    private struct DiscoveryEntry: Decodable {
        let id: String?
        let internalipaddress: String?
    }

    private struct BridgeConfig: Decodable {
        let bridgeid: String?
        let name: String?
    }
}
