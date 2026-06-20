import XCTest
@testable import StremioTV

/// Vérifie la combinaison compte/manuel/repli et la persistance du repository.
final class AddonRepositoryTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test.stremio.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    func testDefaultsToCinemetaWhenEmpty() {
        let repo = AddonRepository(defaults: makeDefaults())
        XCTAssertEqual(repo.addons.count, 1)
        XCTAssertEqual(repo.addons.first?.source, .builtin)
        XCTAssertTrue(repo.addons.first?.base.contains("cinemeta") ?? false)
    }

    func testAddManualAppendsAndPersists() {
        let defaults = makeDefaults()
        let repo = AddonRepository(defaults: defaults)
        repo.addManual("https://my.addon/manifest.json")

        XCTAssertTrue(repo.addons.contains { $0.base == "https://my.addon" })

        // Une nouvelle instance relit la persistance.
        let reloaded = AddonRepository(defaults: defaults)
        XCTAssertTrue(reloaded.addons.contains { $0.base == "https://my.addon" })
    }

    func testAccountAddonsReplaceBuiltin() throws {
        let repo = AddonRepository(defaults: makeDefaults())
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(#"{"id":"t","name":"Torrentio","resources":["stream"],"types":["movie"]}"#.utf8)
        )
        let apiAddon = APIAddon(
            transportUrl: "https://torrentio.strem.fun/rd=KEY/manifest.json",
            manifest: manifest,
            flags: nil
        )
        repo.setAccountAddons([apiAddon])

        XCTAssertFalse(repo.addons.contains { $0.source == .builtin })
        XCTAssertTrue(repo.addons.contains { $0.name == "Torrentio" && $0.source == .account })
    }

    func testClearAccountRestoresBuiltin() {
        let repo = AddonRepository(defaults: makeDefaults())
        let apiAddon = APIAddon(transportUrl: "https://a/manifest.json", manifest: nil, flags: nil)
        repo.setAccountAddons([apiAddon])
        XCTAssertFalse(repo.addons.contains { $0.source == .builtin })

        repo.clearAccountAddons()
        XCTAssertEqual(repo.addons.first?.source, .builtin)
    }

    func testRemoveAddon() {
        let repo = AddonRepository(defaults: makeDefaults())
        repo.addManual("https://my.addon/manifest.json")
        let target = try! XCTUnwrap(repo.addons.first { $0.base == "https://my.addon" })
        repo.remove(target)
        XCTAssertFalse(repo.addons.contains { $0.base == "https://my.addon" })
    }
}
