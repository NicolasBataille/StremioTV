import XCTest

/// Tests UI de bout en bout sur l'émulateur tvOS.
/// - L'écran de connexion s'affiche au lancement.
/// - Le mode invité atteint l'accueil et charge réellement les catalogues
///   (réseau live Cinemeta) — pilotés via l'argument de lancement `-uitestGuest`
///   pour un parcours déterministe (la navigation au focus tvOS étant fragile).
final class AppFlowUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testLaunchShowsLogin() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(
            app.staticTexts["StremioTV"].waitForExistence(timeout: 15),
            "Le titre StremioTV doit s'afficher sur l'écran de connexion"
        )
        XCTAssertTrue(
            app.buttons["guestButton"].waitForExistence(timeout: 5),
            "Le bouton d'accès invité doit être présent"
        )
    }

    func testGuestModeLoadsCatalogs() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestGuest"]
        app.launch()

        // La barre d'onglets doit apparaître (on a atteint l'app principale).
        XCTAssertTrue(
            app.buttons["Recherche"].waitForExistence(timeout: 15),
            "La navigation principale (onglets) doit s'afficher en mode invité"
        )

        // Un catalogue Cinemeta doit se charger depuis le réseau.
        let cinemetaRow = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Cinemeta")
        ).firstMatch
        XCTAssertTrue(
            cinemetaRow.waitForExistence(timeout: 30),
            "Au moins un catalogue Cinemeta doit se charger (réseau)"
        )
    }
}
