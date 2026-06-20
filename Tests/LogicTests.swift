import XCTest
@testable import StremioTV

/// Vérifie la logique métier sans réseau : normalisation d'URL, classification
/// des flux, affichage des épisodes.
final class LogicTests: XCTestCase {

    func testNormalizeBaseStripsManifest() {
        XCTAssertEqual(AddonClient.normalizeBase("https://x.io/manifest.json"), "https://x.io")
        XCTAssertEqual(AddonClient.normalizeBase("https://x.io/"), "https://x.io")
        XCTAssertEqual(AddonClient.normalizeBase("https://x.io/sub/manifest.json"), "https://x.io/sub")
        XCTAssertEqual(AddonClient.normalizeBase("  https://x.io  "), "https://x.io")
    }

    func testStreamDirectURLIsPlayable() throws {
        let json = """
        {"streams": [
          {"name": "RealDebrid", "title": "1080p", "url": "https://cdn.example/v.mp4"},
          {"name": "Torrent", "title": "720p", "infoHash": "deadbeef"}
        ]}
        """
        let response = try JSONDecoder().decode(StreamResponse.self, from: Data(json.utf8))
        let streams = try XCTUnwrap(response.streams)

        XCTAssertTrue(streams[0].isDirectlyPlayable)
        XCTAssertNotNil(streams[0].playableURL)
        XCTAssertFalse(streams[0].isTorrent)

        XCTAssertFalse(streams[1].isDirectlyPlayable)
        XCTAssertNil(streams[1].playableURL)
        XCTAssertTrue(streams[1].isTorrent)
    }

    func testEpisodeDisplayTitle() {
        let withSeason = MetaVideo(id: "x:2:5", title: "Pilot", season: 2, episode: 5, released: nil, thumbnail: nil)
        XCTAssertEqual(withSeason.displayTitle, "S2E5 · Pilot")

        let movie = MetaVideo(id: "tt1", title: "Le Film", season: nil, episode: nil, released: nil, thumbnail: nil)
        XCTAssertEqual(movie.displayTitle, "Le Film")
    }
}
