import XCTest
@testable import StremioTV

/// Vérifie que les modèles décodent correctement les réponses réelles du
/// protocole d'add-ons et de l'API compte Stremio.
final class DecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testManifestDecodesMixedResources() throws {
        let json = """
        {
          "id": "org.test",
          "name": "Test Addon",
          "resources": ["catalog", {"name": "stream", "types": ["movie"]}],
          "types": ["movie", "series"],
          "catalogs": [
            {"type": "movie", "id": "top", "extra": [{"name": "search"}, {"name": "skip"}]}
          ]
        }
        """
        let manifest = try decode(Manifest.self, json)
        XCTAssertEqual(manifest.name, "Test Addon")
        XCTAssertTrue(manifest.provides("catalog"))
        XCTAssertTrue(manifest.provides("stream"))
        XCTAssertFalse(manifest.provides("meta"))

        let catalog = try XCTUnwrap(manifest.catalogs?.first)
        XCTAssertEqual(catalog.uniqueKey, "movie/top")
        XCTAssertFalse(catalog.isSearchOnly) // search présent mais non requis
    }

    func testSearchOnlyCatalogDetected() throws {
        let json = """
        {"type": "movie", "id": "search", "extra": [{"name": "search", "isRequired": true}]}
        """
        let catalog = try decode(CatalogDescriptor.self, json)
        XCTAssertTrue(catalog.isSearchOnly)
    }

    func testCatalogResponseDecodesMetas() throws {
        let json = """
        {"metas": [{"id": "tt1", "type": "movie", "name": "Film", "poster": "https://x/p.jpg"}]}
        """
        let response = try decode(CatalogResponse.self, json)
        XCTAssertEqual(response.metas?.count, 1)
        XCTAssertEqual(response.metas?.first?.id, "tt1")
    }

    func testMetaDetailDecodesVideos() throws {
        let json = """
        {"meta": {"id": "tt9", "type": "series", "name": "Série",
          "videos": [{"id": "tt9:1:1", "title": "Pilot", "season": 1, "episode": 1}]}}
        """
        let response = try decode(MetaResponse.self, json)
        let meta = try XCTUnwrap(response.meta)
        XCTAssertEqual(meta.videos?.count, 1)
        XCTAssertEqual(meta.videos?.first?.id, "tt9:1:1")
    }

    func testAddonCollectionDecodesTransportURL() throws {
        let json = """
        {"result": {"addons": [
          {"transportUrl": "https://torrentio.strem.fun/realdebrid=KEY/manifest.json",
           "manifest": {"id": "torrentio", "name": "Torrentio", "resources": ["stream"], "types": ["movie"]},
           "flags": {"official": false, "protected": false}}
        ], "lastModified": "2024-01-01T00:00:00Z"}}
        """
        let envelope = try decode(APIEnvelope<CollectionResponse>.self, json)
        let addons = try XCTUnwrap(envelope.result?.addons)
        XCTAssertEqual(addons.count, 1)
        XCTAssertEqual(addons.first?.transportUrl, "https://torrentio.strem.fun/realdebrid=KEY/manifest.json")
        XCTAssertEqual(addons.first?.manifest?.name, "Torrentio")
        XCTAssertNil(envelope.error)
    }

    func testAuthErrorDecodes() throws {
        let json = """
        {"error": {"code": 2, "message": "User not found", "wrongEmail": true}}
        """
        let envelope = try decode(APIEnvelope<AuthResponse>.self, json)
        XCTAssertNil(envelope.result)
        XCTAssertEqual(envelope.error?.code, 2)
        XCTAssertEqual(envelope.error?.message, "User not found")
    }

    func testAuthSuccessDecodes() throws {
        let json = """
        {"result": {"authKey": "abc123", "user": {"_id": "u1", "email": "me@example.com"}}}
        """
        let envelope = try decode(APIEnvelope<AuthResponse>.self, json)
        XCTAssertEqual(envelope.result?.authKey, "abc123")
        XCTAssertEqual(envelope.result?.user?.email, "me@example.com")
    }
}
