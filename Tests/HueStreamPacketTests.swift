import XCTest
@testable import StremioTV

/// Octets exacts des messages HueStream v2 (exemple annoté de Hyperion.ng, LedDevicePhilipsHue.cpp).
final class HueStreamPacketTests: XCTestCase {

    private let areaID = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"

    func testGoldenBytesMatchReferenceExample() {
        let colors = [
            HueChannelColor(channelID: 0, color: HueRGB(r: 1, g: 0, b: 0)),
            HueChannelColor(channelID: 1, color: HueRGB(r: 0, g: 1, b: 0)),
            HueChannelColor(channelID: 2, color: HueRGB(r: 0, g: 0, b: 1)),
            HueChannelColor(channelID: 3, color: HueRGB(r: 1, g: 1, b: 1)),
        ]
        let packet = HueStreamPacket.encode(areaID: areaID, sequence: 7, colors: colors)

        var expected: [UInt8] = [
            0x48, 0x75, 0x65, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D, // "HueStream"
            0x02, 0x00,                                           // version 2.0
            0x07,                                                 // séquence 7
            0x00, 0x00,                                           // réservé
            0x00,                                                 // RGB
            0x00,                                                 // réservé
        ]
        // "1a8d99cc-967b-44f2-9202-43f976c0fa6b"
        expected += [
            0x31, 0x61, 0x38, 0x64, 0x39, 0x39, 0x63, 0x63, 0x2D,
            0x39, 0x36, 0x37, 0x62, 0x2D,
            0x34, 0x34, 0x66, 0x32, 0x2D,
            0x39, 0x32, 0x30, 0x32, 0x2D,
            0x34, 0x33, 0x66, 0x39, 0x37, 0x36, 0x63, 0x30, 0x66, 0x61, 0x36, 0x62,
        ]
        expected += [0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00] // canal 0 rouge
        expected += [0x01, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00] // canal 1 vert
        expected += [0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF] // canal 2 bleu
        expected += [0x03, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] // canal 3 blanc

        XCTAssertEqual(Array(packet), expected)
        XCTAssertEqual(packet.count, 52 + 4 * 7)
    }

    func testSizesConstants() {
        XCTAssertEqual(HueStreamPacket.headerSize, 16)
        XCTAssertEqual(HueStreamPacket.areaIDSize, 36)
        XCTAssertEqual(HueStreamPacket.bytesPerChannel, 7)
        XCTAssertEqual(HueStreamPacket.maxChannels, 20)
        XCTAssertEqual(HueStreamPacket.encode(areaID: areaID, sequence: 0, colors: []).count, 52)
    }

    func testComponentsAreClampedAndRounded() {
        let colors = [HueChannelColor(channelID: 9, color: HueRGB(r: 0.5, g: -0.3, b: 1.7))]
        let bytes = Array(HueStreamPacket.encode(areaID: areaID, sequence: 255, colors: colors))
        XCTAssertEqual(bytes[11], 0xFF)                  // séquence
        XCTAssertEqual(Array(bytes[52...]), [0x09,
                                             0x80, 0x00, // 0,5 × 65535 = 32767,5 → 32768
                                             0x00, 0x00, // négatif → 0
                                             0xFF, 0xFF]) // > 1 → 65535
    }

    func testNonFiniteComponentsBecomeZero() {
        let colors = [HueChannelColor(channelID: 1, color: HueRGB(r: .nan, g: .infinity, b: 0.25))]
        let bytes = Array(HueStreamPacket.encode(areaID: areaID, sequence: 0, colors: colors))
        // 0,25 × 65535 = 16383,75 → 16384 = 0x4000
        XCTAssertEqual(Array(bytes[52...]), [0x01, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00])
    }

    func testAtMostTwentyChannels() {
        let colors = (0..<25).map { HueChannelColor(channelID: UInt8($0), color: .black) }
        let packet = HueStreamPacket.encode(areaID: areaID, sequence: 1, colors: colors)
        XCTAssertEqual(packet.count, 52 + 20 * 7)
        XCTAssertEqual(packet[52 + 19 * 7], 19)          // dernier canal conservé
    }

    func testChannelOrderIsPreserved() {
        let colors = [HueChannelColor(channelID: 5, color: .black), HueChannelColor(channelID: 2, color: .black)]
        let bytes = Array(HueStreamPacket.encode(areaID: areaID, sequence: 0, colors: colors))
        XCTAssertEqual(bytes[52], 5)
        XCTAssertEqual(bytes[59], 2)
    }

    func testAreaIDIsLowercased() {
        let packet = HueStreamPacket.encode(areaID: areaID.uppercased(), sequence: 0, colors: [])
        XCTAssertEqual(String(decoding: packet[16..<52], as: UTF8.self), areaID)
    }

    func testShortAreaIDIsPaddedWithZeros() {
        let bytes = Array(HueStreamPacket.encode(areaID: "abc", sequence: 0, colors: []))
        XCTAssertEqual(bytes.count, 52)
        XCTAssertEqual(Array(bytes[16..<19]), [0x61, 0x62, 0x63])
        XCTAssertEqual(Array(bytes[19..<52]), [UInt8](repeating: 0, count: 33))
    }

    func testEmptyAndLongAreaIDNeverCrash() {
        XCTAssertEqual(HueStreamPacket.encode(areaID: "", sequence: 0, colors: []).count, 52)
        let long = String(repeating: "f", count: 80)
        let bytes = Array(HueStreamPacket.encode(areaID: long, sequence: 0, colors: []))
        XCTAssertEqual(bytes.count, 52)
        XCTAssertEqual(Array(bytes[16..<52]), [UInt8](repeating: 0x66, count: 36))
        // Caractères non ASCII : tronqués à 36 octets sans planter.
        let accents = String(repeating: "é", count: 30)
        XCTAssertEqual(HueStreamPacket.encode(areaID: accents, sequence: 0, colors: []).count, 52)
    }
}
