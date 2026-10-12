import XCTest
@testable import StremioTV

/// Défauts et bornes des préférences Hue (UserDefaults jetable).
final class HuePreferencesTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "hue.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaults() {
        let prefs = HuePreferences(defaults: defaults)
        XCTAssertTrue(prefs.isEnabled)
        XCTAssertNil(prefs.selectedAreaID)
        XCTAssertEqual(prefs.brightness, 0.8, accuracy: 1e-9)
        XCTAssertEqual(prefs.saturationBoost, 1.2, accuracy: 1e-9)
        XCTAssertEqual(prefs.latencyMs, 0)
        XCTAssertEqual(prefs.responsiveness, .balanced)
        XCTAssertEqual(prefs.captureMethod, .automatic)
        XCTAssertNil(prefs.lastWorkingCapture)
    }

    func testValuesPersistAcrossInstances() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.isEnabled = false
        prefs.selectedAreaID = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"
        prefs.brightness = 0.5
        prefs.saturationBoost = 1.4
        prefs.latencyMs = 150
        prefs.responsiveness = .fast
        prefs.captureMethod = .vlcSnapshot
        prefs.lastWorkingCapture = .view

        let reloaded = HuePreferences(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.selectedAreaID, "1a8d99cc-967b-44f2-9202-43f976c0fa6b")
        XCTAssertEqual(reloaded.brightness, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reloaded.saturationBoost, 1.4, accuracy: 1e-9)
        XCTAssertEqual(reloaded.latencyMs, 150)
        XCTAssertEqual(reloaded.responsiveness, .fast)
        XCTAssertEqual(reloaded.captureMethod, .vlcSnapshot)
        XCTAssertEqual(reloaded.lastWorkingCapture, .view)
    }

    func testKeysArePrefixed() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.brightness = 0.6
        prefs.latencyMs = 100
        XCTAssertEqual(defaults.double(forKey: "hue.brightness"), 0.6, accuracy: 1e-9)
        XCTAssertEqual(defaults.integer(forKey: "hue.latencyMs"), 100)
    }

    func testBrightnessIsClamped() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.brightness = 0
        XCTAssertEqual(prefs.brightness, 0.1, accuracy: 1e-9)
        prefs.brightness = 3
        XCTAssertEqual(prefs.brightness, 1.0, accuracy: 1e-9)
        prefs.brightness = .nan
        XCTAssertEqual(prefs.brightness, 0.8, accuracy: 1e-9)
    }

    func testSaturationBoostIsClamped() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.saturationBoost = 0.5
        XCTAssertEqual(prefs.saturationBoost, 1.0, accuracy: 1e-9)
        prefs.saturationBoost = 2
        XCTAssertEqual(prefs.saturationBoost, 1.6, accuracy: 1e-9)
    }

    func testLatencyIsClamped() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.latencyMs = -50
        XCTAssertEqual(prefs.latencyMs, 0)
        prefs.latencyMs = 5000
        XCTAssertEqual(prefs.latencyMs, 600)
    }

    func testOutOfRangeStoredValuesAreClampedOnRead() {
        defaults.set(42.0, forKey: "hue.brightness")
        defaults.set(9999, forKey: "hue.latencyMs")
        defaults.set("inconnu", forKey: "hue.responsiveness")
        defaults.set("inconnu", forKey: "hue.captureMethod")
        let prefs = HuePreferences(defaults: defaults)
        XCTAssertEqual(prefs.brightness, 1.0, accuracy: 1e-9)
        XCTAssertEqual(prefs.latencyMs, 600)
        XCTAssertEqual(prefs.responsiveness, .balanced)
        XCTAssertEqual(prefs.captureMethod, .automatic)
    }

    func testSelectedAreaCanBeCleared() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.selectedAreaID = "abc"
        prefs.selectedAreaID = nil
        XCTAssertNil(prefs.selectedAreaID)
        prefs.selectedAreaID = ""
        XCTAssertNil(prefs.selectedAreaID)
    }

    func testLastWorkingCaptureNeverAutomatic() {
        let prefs = HuePreferences(defaults: defaults)
        prefs.lastWorkingCapture = .vlcSnapshot
        prefs.lastWorkingCapture = .automatic
        XCTAssertNil(prefs.lastWorkingCapture)
        defaults.set("automatic", forKey: "hue.lastWorkingCapture")
        XCTAssertNil(prefs.lastWorkingCapture)
        prefs.lastWorkingCapture = .view
        prefs.lastWorkingCapture = nil
        XCTAssertNil(prefs.lastWorkingCapture)
    }

    func testResponsivenessAndCaptureLabels() {
        XCTAssertEqual(HueResponsiveness.smooth.timeConstant, 0.35, accuracy: 1e-9)
        XCTAssertEqual(HueResponsiveness.balanced.timeConstant, 0.18, accuracy: 1e-9)
        XCTAssertEqual(HueResponsiveness.fast.timeConstant, 0.08, accuracy: 1e-9)
        XCTAssertEqual(HueResponsiveness.allCases.map(\.label), ["Douce", "Équilibrée", "Rapide"])
        XCTAssertEqual(HueCaptureMethod.allCases.map(\.label), ["Automatique", "Capture de la vue", "Snapshot VLC"])
        XCTAssertEqual(HueCaptureMethod.vlcSnapshot.id, "vlcSnapshot")
    }
}
