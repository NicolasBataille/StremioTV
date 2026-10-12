import XCTest
@testable import StremioTV

/// Décodage / encodage JSON des API du pont Hue (réponses réalistes, sans réseau).
final class HueAPITests: XCTestCase {

    private func json(_ string: String) -> Data { Data(string.utf8) }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Zones de divertissement

    func testDecodeAreasRealisticResponse() throws {
        let data = json("""
        {"errors": [], "data": [
          {"id": "1a8d99cc-967b-44f2-9202-43f976c0fa6b", "id_v1": "/groups/200", "type": "entertainment_configuration",
           "metadata": {"name": "Salon TV"}, "name": "Salon TV", "configuration_type": "screen", "status": "active",
           "active_streamer": {"rid": "8f3a5c3e-0d2b-4c55-9a3e-6a2f7f6e0b11", "rtype": "auth_v1"},
           "stream_proxy": {"mode": "auto", "node": {"rid": "x", "rtype": "entertainment"}},
           "channels": [
             {"channel_id": 0, "position": {"x": -0.8, "y": 0.8, "z": 0}, "members": [
                {"service": {"rid": "a", "rtype": "entertainment"}, "index": 0}]},
             {"channel_id": 1, "position": {"x": 0.8, "y": 0.8, "z": 0.5}, "members": []},
             {"channel_id": 2, "position": {"x": 0, "y": -1, "z": -1}}
           ],
           "locations": {"service_locations": []}, "light_services": []},
          {"id": "c4f9e0b2-1111-2222-3333-444455556666", "configuration_type": "music", "status": "inactive",
           "channels": []}
        ]}
        """)
        let areas = try HueAPI.decodeAreas(data)
        XCTAssertEqual(areas.count, 2)

        let tv = areas[0]
        XCTAssertEqual(tv.id, "1a8d99cc-967b-44f2-9202-43f976c0fa6b")
        XCTAssertEqual(tv.name, "Salon TV")
        XCTAssertEqual(tv.configurationType, "screen")
        XCTAssertTrue(tv.isStreaming)
        XCTAssertEqual(tv.activeStreamerID, "8f3a5c3e-0d2b-4c55-9a3e-6a2f7f6e0b11")
        XCTAssertEqual(tv.channels, [
            HueChannel(id: 0, x: -0.8, y: 0.8, z: 0),
            HueChannel(id: 1, x: 0.8, y: 0.8, z: 0.5),
            HueChannel(id: 2, x: 0, y: -1, z: -1),
        ])

        let music = areas[1]
        XCTAssertEqual(music.name, "Zone")             // metadata absent
        XCTAssertEqual(music.configurationType, "music")
        XCTAssertFalse(music.isStreaming)
        XCTAssertNil(music.activeStreamerID)
        XCTAssertTrue(music.channels.isEmpty)
    }

    func testDecodeAreasToleratesMissingAndOddFields() throws {
        let data = json("""
        {"data": [
          {"id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "metadata": "pas un objet",
           "channels": [{"channel_id": 300, "position": {"x": 0, "y": 0, "z": 0}},
                        {"channel_id": "x"},
                        {"channel_id": 4}]},
          {"metadata": {"name": "Sans id"}},
          {"id": "", "metadata": {"name": "Id vide"}}
        ]}
        """)
        let areas = try HueAPI.decodeAreas(data)
        XCTAssertEqual(areas.count, 1)
        XCTAssertEqual(areas[0].name, "Zone")
        XCTAssertEqual(areas[0].configurationType, "other")   // absent
        XCTAssertFalse(areas[0].isStreaming)                  // status absent
        // channel_id hors 0…255 ou illisible ignoré ; position absente → 0,0,0.
        XCTAssertEqual(areas[0].channels, [HueChannel(id: 4, x: 0, y: 0, z: 0)])
    }

    func testDecodeAreasSingleObjectData() throws {
        let data = json("""
        {"errors": [], "data": {"id": "1a8d99cc-967b-44f2-9202-43f976c0fa6b", "metadata": {"name": "TV"},
          "configuration_type": "screen", "status": "inactive", "channels": []}}
        """)
        let areas = try HueAPI.decodeAreas(data)
        XCTAssertEqual(areas.map(\.name), ["TV"])
    }

    func testDecodeAreasErrorEnvelope() {
        let data = json("""
        {"errors": [{"description": "unauthorized user"}], "data": []}
        """)
        XCTAssertThrowsError(try HueAPI.decodeAreas(data)) { error in
            XCTAssertEqual(error as? HueError, .bridge("unauthorized user"))
        }
    }

    func testDecodeAreasInvalidJSON() {
        XCTAssertThrowsError(try HueAPI.decodeAreas(json("<html>404</html>"))) { error in
            XCTAssertEqual(error as? HueError, .invalidResponse)
        }
        XCTAssertThrowsError(try HueAPI.decodeAreas(json("{\"errors\": []}"))) { error in
            XCTAssertEqual(error as? HueError, .invalidResponse)
        }
        XCTAssertEqual(try HueAPI.decodeAreas(json("{\"errors\": [], \"data\": []}")), [])
    }

    // MARK: - checkErrors

    func testCheckErrors() {
        XCTAssertNoThrow(try HueAPI.checkErrors(json("{\"errors\": [], \"data\": [{\"rid\": \"x\"}]}")))
        XCTAssertNoThrow(try HueAPI.checkErrors(json("pas du JSON")))
        XCTAssertNoThrow(try HueAPI.checkErrors(Data()))
        XCTAssertNoThrow(try HueAPI.checkErrors(json("[{\"success\": {}}]")))
        XCTAssertThrowsError(try HueAPI.checkErrors(json("""
        {"errors": [{"description": "a"}, {"description": "b"}], "data": []}
        """))) { error in
            XCTAssertEqual(error as? HueError, .bridge("a ; b"))
        }
    }

    // MARK: - Appairage

    func testDecodePairingSuccess() throws {
        let data = json("""
        [{"success": {"username": "83b7780291a6ceffbe0bd049104df", "clientkey": "33DDAFC6B5D4E5F3E4C1A2B3C4D5E6F7"}}]
        """)
        XCTAssertEqual(try HueAPI.decodePairing(data),
                       .success(username: "83b7780291a6ceffbe0bd049104df", clientKey: "33DDAFC6B5D4E5F3E4C1A2B3C4D5E6F7"))
    }

    func testDecodePairingLinkButtonNotPressed() throws {
        let data = json("""
        [{"error": {"type": 101, "address": "", "description": "link button not pressed"}}]
        """)
        XCTAssertEqual(try HueAPI.decodePairing(data), .linkButtonNotPressed)
    }

    func testDecodePairingOtherError() throws {
        let data = json("""
        [{"error": {"type": 7, "address": "/devicetype", "description": "invalid value"}}]
        """)
        XCTAssertEqual(try HueAPI.decodePairing(data), .failure(type: 7, description: "invalid value"))
    }

    func testDecodePairingInvalid() {
        for body in ["", "[]", "{}", "<html></html>", "[{\"success\": {\"username\": \"u\"}}]"] {
            XCTAssertThrowsError(try HueAPI.decodePairing(json(body)), body) { error in
                XCTAssertEqual(error as? HueError, .invalidResponse)
            }
        }
    }

    func testPairingBody() throws {
        let body = try object(HueAPI.pairingBody(deviceType: "stremiotv#Apple TV du salon"))
        XCTAssertEqual(body["devicetype"] as? String, "stremiotv#Apple TV du salon")
        XCTAssertEqual(body["generateclientkey"] as? Bool, true)
        XCTAssertEqual(body.count, 2)

        let long = String(repeating: "é", count: 60)
        let truncated = try object(HueAPI.pairingBody(deviceType: long))
        XCTAssertEqual(truncated["devicetype"] as? String, String(repeating: "é", count: 40))
    }

    // MARK: - Découverte

    func testDecodeDiscovery() throws {
        let data = json("""
        [{"id": "001788FFFE23ABCD", "internalipaddress": "192.168.1.20", "port": 443},
         {"id": "ECB5FAFFFE0A1B2C", "internalipaddress": "192.168.1.21"},
         {"id": "001788fffe23abcd", "internalipaddress": "192.168.1.20", "port": 443},
         {"id": "deadbeef", "port": 443},
         {"internalipaddress": "10.0.0.5"}]
        """)
        XCTAssertEqual(try HueAPI.decodeDiscovery(data), [
            HueBridgeCandidate(id: "001788fffe23abcd", host: "192.168.1.20"),
            HueBridgeCandidate(id: "ecb5fafffe0a1b2c", host: "192.168.1.21"),
            HueBridgeCandidate(id: "10.0.0.5", host: "10.0.0.5"),
        ])
        XCTAssertEqual(try HueAPI.decodeDiscovery(json("[]")), [])
        XCTAssertThrowsError(try HueAPI.decodeDiscovery(json("{\"error\": \"rate limited\"}")))
    }

    func testDecodeBridgeConfig() throws {
        let data = json("""
        {"name": "Hue Bridge", "datastoreversion": "163", "swversion": "1962154010", "apiversion": "1.62.0",
         "mac": "00:17:88:23:ab:cd", "bridgeid": "001788FFFE23ABCD", "factorynew": false,
         "replacesbridgeid": null, "modelid": "BSB002", "starterkitid": ""}
        """)
        let config = try HueAPI.decodeBridgeConfig(data)
        XCTAssertEqual(config.bridgeID, "001788fffe23abcd")
        XCTAssertEqual(config.name, "Hue Bridge")

        let unnamed = try HueAPI.decodeBridgeConfig(json("{\"bridgeid\": \"ABC\"}"))
        XCTAssertEqual(unnamed.name, "Pont Hue")

        XCTAssertThrowsError(try HueAPI.decodeBridgeConfig(json("{\"name\": \"x\"}"))) { error in
            XCTAssertEqual(error as? HueError, .invalidResponse)
        }
        XCTAssertThrowsError(try HueAPI.decodeBridgeConfig(json("""
        [{"error": {"type": 1, "address": "/", "description": "unauthorized user"}}]
        """))) { error in
            XCTAssertEqual(error as? HueError, .bridge("unauthorized user"))
        }
    }

    // MARK: - Flux

    func testStreamingActionBody() throws {
        XCTAssertEqual(try object(HueAPI.streamingActionBody(start: true)) as? [String: String], ["action": "start"])
        XCTAssertEqual(try object(HueAPI.streamingActionBody(start: false)) as? [String: String], ["action": "stop"])
        XCTAssertEqual(String(decoding: HueAPI.streamingActionBody(start: true), as: UTF8.self), "{\"action\":\"start\"}")
    }
}
