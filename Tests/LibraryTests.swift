import XCTest
@testable import StremioTV

// Désambiguïsation : un autre module visible via le host de test déclare aussi
// `LibraryItem` ; on force notre type applicatif.
private typealias LibraryItem = StremioTV.LibraryItem

/// Décodage des LibraryItem + logique bibliothèque / Continuer à regarder / reprise.
final class LibraryTests: XCTestCase {

    private func decodeItem(_ json: String) throws -> LibraryItem {
        try JSONDecoder().decode(LibraryItem.self, from: Data(json.utf8))
    }

    func testDecodesStateAndComputeds() throws {
        let item = try decodeItem("""
        {"_id":"tt0111161","name":"Shawshank","type":"movie","removed":false,"temp":false,
         "_mtime":"2026-01-01T00:00:00Z",
         "state":{"timeOffset":600000,"duration":1200000,"video_id":"tt0111161","flaggedWatched":0}}
        """)
        XCTAssertEqual(item.id, "tt0111161")
        XCTAssertEqual(item.state.timeOffset, 600_000)
        XCTAssertEqual(item.state.videoId, "tt0111161") // snake_case décodé
        XCTAssertTrue(item.isInLibrary)
        XCTAssertTrue(item.isInContinueWatching)
        XCTAssertEqual(item.progress, 0.5, accuracy: 0.01)
        XCTAssertFalse(item.isWatched)
    }

    func testContinueWatchingExcludesZeroOffsetAndOther() throws {
        let noProgress = try decodeItem("""
        {"_id":"a","name":"A","type":"movie","removed":false,"temp":false,"_mtime":"2026-01-01T00:00:00Z",
         "state":{"timeOffset":0,"duration":1000}}
        """)
        XCTAssertFalse(noProgress.isInContinueWatching)

        let other = try decodeItem("""
        {"_id":"b","name":"B","type":"other","removed":false,"temp":false,"_mtime":"2026-01-01T00:00:00Z",
         "state":{"timeOffset":500,"duration":1000}}
        """)
        XCTAssertFalse(other.isInContinueWatching)
    }

    func testTempItemInContinueWatchingButNotLibrary() throws {
        let temp = try decodeItem("""
        {"_id":"c","name":"C","type":"series","removed":true,"temp":true,"_mtime":"2026-01-01T00:00:00Z",
         "state":{"timeOffset":500,"duration":1000,"video_id":"c:1:1"}}
        """)
        XCTAssertFalse(temp.isInLibrary)           // pas sauvegardé
        XCTAssertTrue(temp.isInContinueWatching)   // mais en cours
    }

    func testWatchedFlag() throws {
        let watched = try decodeItem("""
        {"_id":"d","name":"D","type":"movie","removed":false,"temp":false,"_mtime":"2026-01-01T00:00:00Z",
         "state":{"timeOffset":950,"duration":1000,"flaggedWatched":1}}
        """)
        XCTAssertTrue(watched.isWatched)
    }

    func testEncodeProducesWireKeys() throws {
        var item = LibraryItem(autoCreatedId: "tt1", type: "series", name: "X", poster: nil)
        item.state.videoId = "tt1:1:2"
        item.state.timeOffset = 1000
        let json = String(data: try JSONEncoder().encode(item), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"_id\""), "doit sérialiser _id")
        XCTAssertTrue(json.contains("\"_mtime\""), "doit sérialiser _mtime")
        XCTAssertTrue(json.contains("\"video_id\""), "doit sérialiser video_id en snake_case")
    }

    func testAutoCreatedItemIsTempAndRemoved() {
        let item = LibraryItem(autoCreatedId: "tt9", type: "movie", name: "N", poster: nil)
        XCTAssertTrue(item.temp)
        XCTAssertTrue(item.removed)
        XCTAssertFalse(item.isInLibrary)
    }
}
