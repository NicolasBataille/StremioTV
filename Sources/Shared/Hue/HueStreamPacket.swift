import Foundation

/// Encodeur des messages HueStream v2 (API Entertainment, envoyés en DTLS sur UDP 2100).
///
/// Format (mode RGB) :
/// ```
/// "HueStream"            9 octets ASCII
/// 0x02 0x00              version 2.0
/// seq                    numéro de séquence (ignoré par le pont, utile au débogage)
/// 0x00 0x00              réservé
/// 0x00                   espace couleur : 0x00 = RGB, 0x01 = xy + luminosité
/// 0x00                   réservé
/// <36 octets>            UUID de la zone de divertissement (ASCII)
/// pour chaque canal :    channel_id (1 octet) + R, G, B (UInt16 big-endian)
/// ```
/// Au plus 20 canaux par message.
enum HueStreamPacket {
    static let headerSize = 16          // "HueStream" + 02 00 + seq + 00 00 + espace couleur (00 = RGB) + 00
    static let areaIDSize = 36
    static let bytesPerChannel = 7      // channel_id + R,G,B en UInt16 big-endian
    static let maxChannels = 20

    private static let protocolName: [UInt8] = Array("HueStream".utf8)

    /// Encode un message HueStream v2 en mode RGB. Composantes bornées à 0…1 puis × 65535 arrondi.
    /// Au plus `maxChannels` canaux (les suivants ignorés). `areaID` en minuscules, exactement 36 octets ASCII
    /// (si la chaîne fait une autre longueur : tronquer / compléter avec des 0x00 — ne jamais crasher).
    static func encode(areaID: String, sequence: UInt8, colors: [HueChannelColor]) -> Data {
        let channels = colors.prefix(maxChannels)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(headerSize + areaIDSize + bytesPerChannel * channels.count)

        // En-tête (16 octets).
        bytes.append(contentsOf: protocolName)
        bytes.append(contentsOf: [0x02, 0x00])  // version 2.0
        bytes.append(sequence)
        bytes.append(contentsOf: [0x00, 0x00])  // réservé
        bytes.append(0x00)                      // espace couleur RGB
        bytes.append(0x00)                      // réservé

        // Identifiant de zone : exactement 36 octets.
        var idBytes = Array(areaID.lowercased().utf8.prefix(areaIDSize))
        if idBytes.count < areaIDSize {
            idBytes.append(contentsOf: repeatElement(0x00, count: areaIDSize - idBytes.count))
        }
        bytes.append(contentsOf: idBytes)

        // Canaux.
        for channel in channels {
            bytes.append(channel.channelID)
            for component in [channel.color.r, channel.color.g, channel.color.b] {
                let value = quantize(component)
                bytes.append(UInt8(value >> 8))
                bytes.append(UInt8(value & 0xFF))
            }
        }
        return Data(bytes)
    }

    /// Composante 0…1 → 0…65535 (valeur non finie → 0).
    private static func quantize(_ component: Double) -> UInt16 {
        guard component.isFinite else { return 0 }
        let clamped = min(1, max(0, component))
        return UInt16((clamped * 65535).rounded())
    }
}
