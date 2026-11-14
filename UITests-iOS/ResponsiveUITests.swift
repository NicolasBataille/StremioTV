import XCTest

/// Tests UI iPhone / iPad (simulateur), lancés en CI (`.github/workflows/ios-check.yml`).
///
/// Vérifie :
/// - la barre de recherche est visible d'emblée, sous le titre (pas cachée sur
///   iPhone, pas reléguée en haut à droite sur iPad) ;
/// - revenir sur l'Accueil depuis la Bibliothèque ne relance pas le chargement
///   des catalogues ;
/// - la recherche est conservée quand on change de section.
///
/// Chaque étape joint une capture d'écran (exportée en artefact par la CI).
final class ResponsiveUITests: XCTestCase {

    private var app: XCUIApplication!
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    private var device: String { isPad ? "iPad" : "iPhone" }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // iPad en paysage : la barre latérale de NavigationSplitView est visible.
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        app = XCUIApplication()
        app.launchArguments = ["-uitestGuest"]
        app.launch()
    }

    func testResponsiveLayoutAndNoRefetch() {
        // 1. Accueil : les catalogues se chargent.
        XCTAssertTrue(cinemetaRow.waitForExistence(timeout: 40), "Les catalogues doivent se charger")
        snapshot("01-accueil")

        // 2. Recherche : champ visible immédiatement, sous le titre.
        goTo("Recherche")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Le champ de recherche doit exister")
        XCTAssertTrue(field.isHittable, "Le champ de recherche doit être visible sans défiler")
        let window = app.windows.firstMatch.frame
        let detailMinX = isPad ? window.width * 0.25 : 0 // à droite de la barre latérale
        XCTAssertLessThan(field.frame.minX - detailMinX, 60,
                          "Le champ doit être aligné à gauche du contenu, pas dans le coin droit")
        XCTAssertGreaterThan(field.frame.width, (window.width - detailMinX) * 0.6,
                             "Le champ doit occuper la largeur du contenu")
        snapshot("02-recherche-vide")

        field.tap()
        field.typeText("matrix")
        let result = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Matrix")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "Des résultats doivent s'afficher")
        dismissKeyboard()
        snapshot("03-recherche-resultats")

        // 3. Bibliothèque puis retour Accueil : pas de rechargement.
        goTo("Bibliothèque")
        snapshot("04-bibliotheque")
        goTo("Accueil")
        XCTAssertTrue(cinemetaRow.waitForExistence(timeout: 2),
                      "L'accueil doit réafficher immédiatement ses catalogues")
        let loading = app.staticTexts["Chargement des catalogues…"]
        for _ in 0..<6 {
            XCTAssertFalse(loading.exists, "L'accueil ne doit pas recharger au retour")
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(cinemetaRow.exists, "Les catalogues doivent rester affichés")
        snapshot("05-accueil-retour")

        // 4. Retour sur Recherche : saisie et résultats conservés.
        goTo("Recherche")
        XCTAssertTrue(result.waitForExistence(timeout: 3), "Les résultats doivent être conservés")
        snapshot("06-recherche-conservee")

        // 5. Fiche détaillée.
        result.tap()
        Thread.sleep(forTimeInterval: 3)
        snapshot("07-fiche")
    }

    // MARK: - Helpers

    private var cinemetaRow: XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Cinemeta")).firstMatch
    }

    /// Navigue vers une section : onglet (iPhone) ou ligne de barre latérale (iPad).
    private func goTo(_ section: String) {
        let candidates = [
            app.tabBars.buttons[section],
            app.collectionViews.cells.containing(.staticText, identifier: section).firstMatch,
            app.cells.containing(.staticText, identifier: section).firstMatch,
            app.buttons[section],
        ]
        for element in candidates where element.waitForExistence(timeout: 1) && element.isHittable {
            element.tap()
            Thread.sleep(forTimeInterval: 1)
            return
        }
        snapshot("echec-navigation-\(section)")
        XCTFail("Impossible d'atteindre la section \(section)")
    }

    private func dismissKeyboard() {
        // En CI le clavier matériel est souvent « connecté » : pas de clavier logiciel.
        let submit = app.keyboards.buttons.matching(
            NSPredicate(format: "label IN {'search', 'Search', 'Rechercher', 'rechercher'}")
        ).firstMatch
        if submit.exists { submit.tap() }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
