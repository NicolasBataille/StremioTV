import XCTest
@testable import StremioTV

/// Vérifie le pipeline couleur de l'Ambilight sur des images synthétiques :
/// placement des canaux, bandes noires, sous-titres, saturation, luminosité, performances.
final class ColorPipelineTests: XCTestCase {

    // MARK: Outils

    private typealias RGB8 = (UInt8, UInt8, UInt8)

    /// Image w×h dont chaque pixel est donné par `color(x, y)`.
    private func frame(_ width: Int = 64, _ height: Int = 36,
                       timestamp: TimeInterval = 0,
                       _ color: (Int, Int) -> RGB8) -> SampledFrame {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                let i = (y * width + x) * 4
                rgba[i] = c.0; rgba[i + 1] = c.1; rgba[i + 2] = c.2
            }
        }
        return SampledFrame(width: width, height: height, rgba: rgba, timestamp: timestamp)
    }

    private func solid(_ c: RGB8, _ width: Int = 64, _ height: Int = 36) -> SampledFrame {
        frame(width, height) { _, _ in c }
    }

    /// Réglages neutres : ni boost, ni atténuation.
    private let neutral = AmbilightTuning(brightness: 1, saturationBoost: 1)

    private let left = HueChannel(id: 1, x: -1, y: 0.8, z: 0)
    private let right = HueChannel(id: 2, x: 1, y: 0.8, z: 0)
    private let top = HueChannel(id: 3, x: 0, y: 0.8, z: 1)
    private let bottom = HueChannel(id: 4, x: 0, y: 0.8, z: -1)
    private let center = HueChannel(id: 5, x: 0, y: 0, z: 0)
    private let behind = HueChannel(id: 6, x: -0.6, y: -1, z: 0)

    private var allChannels: [HueChannel] { [left, right, top, bottom, center, behind] }

    private func assertColor(_ c: HueRGB, _ r: Double, _ g: Double, _ b: Double,
                             accuracy: Double = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.r, r, accuracy: accuracy, "r", file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: accuracy, "g", file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: accuracy, "b", file: file, line: line)
    }

    private func color(_ out: [HueChannelColor], _ id: UInt8) -> HueRGB {
        out.first { $0.channelID == id }?.color ?? HueRGB(r: -1, g: -1, b: -1)
    }

    /// Image 64×36 en letterbox (`bar` lignes noires en haut et en bas) remplie de `c`.
    private func letterboxed(bar: Int, _ c: RGB8, width: Int = 64, height: Int = 36,
                             subtitleInBar: Bool = false) -> SampledFrame {
        frame(width, height) { x, y in
            if y < bar || y >= height - bar {
                // Sous-titre blanc dessiné dans la bande basse, au centre.
                if subtitleInBar, y == height - bar / 2 - 1, x >= width / 3, x < 2 * width / 3 {
                    return (255, 255, 255)
                }
                return (0, 0, 0)
            }
            return c
        }
    }

    // MARK: Couleurs

    func testSolidColorIsReturnedForEveryChannel() {
        let pipeline = ColorPipeline(channels: allChannels, tuning: neutral)
        let out = pipeline.process(solid((200, 100, 50)))
        XCTAssertEqual(out.map(\.channelID), [1, 2, 3, 4, 5, 6])
        for c in out {
            assertColor(c.color, 200.0 / 255, 100.0 / 255, 50.0 / 255)
        }
    }

    func testLeftRedRightBlue() {
        let pipeline = ColorPipeline(channels: [left, right, center], tuning: neutral)
        let out = pipeline.process(frame { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) })
        assertColor(color(out, 1), 1, 0, 0)
        assertColor(color(out, 2), 0, 0, 1)
        // Le canal central mélange les deux (moyenne linéaire puis gamma ≈ 0,73).
        let mid = color(out, 5)
        XCTAssertEqual(mid.r, mid.b, accuracy: 0.02)
        XCTAssertGreaterThan(mid.r, 0.6)
        XCTAssertEqual(mid.g, 0, accuracy: 0.001)
    }

    func testTopGreenBottomYellow() {
        let pipeline = ColorPipeline(channels: [top, bottom], tuning: neutral)
        let out = pipeline.process(frame { _, y in y < 18 ? (0, 255, 0) : (255, 255, 0) })
        assertColor(color(out, 3), 0, 1, 0)
        assertColor(color(out, 4), 1, 1, 0)
    }

    func testGradientChannelsFollowPosition() {
        // Ruban sur le bord haut : 5 segments de gauche à droite sur un dégradé horizontal.
        let segments = (0..<5).map { i in HueChannel(id: UInt8(10 + i), x: -0.8 + 0.4 * Double(i), y: 1, z: 0.9) }
        let pipeline = ColorPipeline(channels: segments, tuning: neutral)
        let out = pipeline.process(frame { x, _ in (UInt8(x * 4), 0, 0) })
        let reds = out.map(\.color.r)
        XCTAssertEqual(reds, reds.sorted(), "les segments doivent suivre le dégradé gauche → droite")
        XCTAssertLessThan(reds[0], 0.35)
        XCTAssertGreaterThan(reds[4], 0.75)
    }

    /// Lampes proches de la télé (|x| < 0,35) : chacune garde le côté de l'image qui lui fait face.
    func testLampsCloseToTheTVKeepLeftRightSeparation() {
        let near = [HueChannel(id: 1, x: -0.3, y: 0.8, z: 0), HueChannel(id: 2, x: 0.3, y: 0.8, z: 0)]
        let out = ColorPipeline(channels: near, tuning: neutral)
            .process(frame { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) })
        assertColor(color(out, 1), 1, 0, 0, accuracy: 0.05)
        assertColor(color(out, 2), 0, 0, 1, accuracy: 0.05)
        let mixed = near + [HueChannel(id: 3, x: -1, y: -1, z: 0), HueChannel(id: 4, x: 1, y: -1, z: 0)]
        let out2 = ColorPipeline(channels: mixed, tuning: neutral)
            .process(frame { x, _ in x < 32 ? (255, 0, 0) : (0, 0, 255) })
        XCTAssertGreaterThan(color(out2, 1).r, color(out2, 1).b + 0.3)
        XCTAssertGreaterThan(color(out2, 2).b, color(out2, 2).r + 0.3)
    }

    /// Segments d'un gradient derrière la télé (|x| et |z| ≈ 0,4) : ils lisent le coin d'image correspondant.
    func testGradientStripCornersReadImageCorners() {
        let corners = [HueChannel(id: 1, x: -0.4, y: 0.8, z: 0.4), HueChannel(id: 2, x: -0.4, y: 0.8, z: -0.4),
                       HueChannel(id: 3, x: 0, y: 0.8, z: 0.4)]
        let out = ColorPipeline(channels: corners, tuning: neutral)
            .process(frame { _, y in y < 18 ? (0, 255, 0) : (255, 0, 0) })
        assertColor(color(out, 1), 0, 1, 0, accuracy: 0.05)
        assertColor(color(out, 2), 1, 0, 0, accuracy: 0.05)
        assertColor(color(out, 3), 0, 1, 0, accuracy: 0.05)
    }

    func testLinearLightAveraging() {
        // Damier noir / blanc : moyenne linéaire 0,5 → gamma ≈ 0,735 (et non 0,5).
        let pipeline = ColorPipeline(channels: [center], tuning: neutral)
        let out = pipeline.process(frame { x, y in (x + y) % 2 == 0 ? (255, 255, 255) : (0, 0, 0) })
        assertColor(color(out, 5), 0.735, 0.735, 0.735, accuracy: 0.02)
    }

    func testBrightnessScalesOutput() {
        let pipeline = ColorPipeline(channels: [center], tuning: AmbilightTuning(brightness: 0.5, saturationBoost: 1))
        assertColor(color(pipeline.process(solid((204, 204, 204))), 5), 0.4, 0.4, 0.4)
        pipeline.tuning.brightness = 0
        assertColor(color(pipeline.process(solid((204, 204, 204))), 5), 0, 0, 0)
    }

    func testSaturationBoostKeepsGrayAndLuminance() {
        let pipeline = ColorPipeline(channels: [center], tuning: AmbilightTuning(brightness: 1, saturationBoost: 1.6))
        // Un gris reste gris.
        assertColor(color(pipeline.process(solid((128, 128, 128))), 5), 128.0 / 255, 128.0 / 255, 128.0 / 255)

        // Une couleur terne devient plus saturée, à luminance (luma) quasi constante.
        let input = (r: 0.6, g: 0.45, b: 0.4)
        let out = color(pipeline.process(solid((UInt8(input.r * 255), UInt8(input.g * 255), UInt8(input.b * 255)))), 5)
        func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
        XCTAssertGreaterThan(out.r - out.b, input.r - input.b + 0.05)
        XCTAssertEqual(luma(out.r, out.g, out.b), luma(input.r, input.g, input.b), accuracy: 0.01)

        // Une couleur déjà pure reste dans le gamut.
        let red = color(pipeline.process(solid((255, 0, 0))), 5)
        assertColor(red, 1, 0, 0)
    }

    func testSaturationBoostHelper() {
        let gray = ColorPipeline.boostSaturation((0.3, 0.3, 0.3), by: 1.6)
        XCTAssertEqual(gray.0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(gray.1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(gray.2, 0.3, accuracy: 1e-9)
        let boosted = ColorPipeline.boostSaturation((0.8, 0.3, 0), by: 1.2)
        XCTAssertEqual(boosted.2, 0)
        XCTAssertGreaterThan(boosted.0 - boosted.1, 0.5)
        XCTAssertLessThanOrEqual(max(boosted.0, boosted.1), 1)
    }

    // MARK: Image noire

    func testBlackFrameGivesBlackChannels() {
        let pipeline = ColorPipeline(channels: allChannels)
        let out = pipeline.process(solid((0, 0, 0)))
        XCTAssertEqual(out.count, 6)
        XCTAssertTrue(out.allSatisfy { $0.color == .black })
        // Quasi noir (sous le seuil) : aussi noir.
        XCTAssertTrue(pipeline.process(solid((10, 12, 8))).allSatisfy { $0.color == .black })
    }

    func testInvalidFrameDoesNotCrash() {
        let pipeline = ColorPipeline(channels: [left, right])
        let bad = SampledFrame(width: 64, height: 36, rgba: [1, 2, 3], timestamp: 0)
        XCTAssertEqual(pipeline.process(bad).map(\.color), [.black, .black])
        let empty = SampledFrame(width: 0, height: 0, rgba: [], timestamp: 0)
        XCTAssertEqual(pipeline.process(empty).count, 2)
        XCTAssertEqual(ColorPipeline(channels: []).process(solid((255, 0, 0))), [])
    }

    // MARK: Bandes noires

    func testLetterboxDetectedAfterSeveralFrames() {
        let pipeline = ColorPipeline(channels: [top, bottom], tuning: neutral)
        let bar = Int((0.12 * 36).rounded())                 // 4 lignes ≈ 12 %
        let image = letterboxed(bar: bar, (0, 200, 0))

        _ = pipeline.process(image)
        XCTAssertEqual(pipeline.contentRect, .full, "une seule image ne suffit pas")
        for _ in 0..<ColorPipeline.stableFramesRequired { _ = pipeline.process(image) }

        let rect = pipeline.contentRect
        XCTAssertEqual(rect.y, Double(bar) / 36, accuracy: 1.0 / 36)
        XCTAssertEqual(rect.height, Double(36 - 2 * bar) / 36, accuracy: 1.0 / 36)
        XCTAssertEqual(rect.x, 0, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 1, accuracy: 1e-9)

        // Une fois les bandes ignorées, les canaux haut/bas voient la couleur de l'image, pas du noir.
        let out = pipeline.process(image)
        assertColor(color(out, 3), 0, 200.0 / 255, 0)
        assertColor(color(out, 4), 0, 200.0 / 255, 0)
    }

    func testPillarboxDetected() {
        let pipeline = ColorPipeline(channels: [left, right], tuning: neutral)
        let image = frame { x, _ in (x < 8 || x >= 56) ? (0, 0, 0) : (x < 32 ? (255, 0, 0) : (0, 0, 255)) }
        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(image) }
        XCTAssertEqual(pipeline.contentRect.x, 8.0 / 64, accuracy: 1.0 / 64)
        XCTAssertEqual(pipeline.contentRect.width, 48.0 / 64, accuracy: 1.0 / 64)
        let out = pipeline.process(image)
        assertColor(color(out, 1), 1, 0, 0)
        assertColor(color(out, 2), 0, 0, 1)
    }

    func testLetterboxWithSubtitleInBarIsStillDetected() {
        let pipeline = ColorPipeline(channels: [bottom], tuning: neutral)
        let image = letterboxed(bar: 6, (0, 0, 200), subtitleInBar: true)
        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(image) }
        XCTAssertEqual(pipeline.contentRect.y, 6.0 / 36, accuracy: 1.0 / 36)
        XCTAssertEqual(pipeline.contentRect.y + pipeline.contentRect.height, 30.0 / 36, accuracy: 1.0 / 36)
    }

    func testBlackFramesDoNotChangeContentRect() {
        let pipeline = ColorPipeline(channels: [top])
        let image = letterboxed(bar: 4, (200, 200, 200))
        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(image) }
        let detected = pipeline.contentRect
        XCTAssertNotEqual(detected, .full)
        // Un fondu au noir prolongé ne touche pas à la zone utile.
        for _ in 0..<30 { _ = pipeline.process(solid((0, 0, 0))) }
        XCTAssertEqual(pipeline.contentRect, detected)
        // Une scène sombre (pas de bord net) non plus.
        let dark = frame { x, y in (x == 32 && y == 18) ? (255, 255, 255) : (5, 5, 5) }
        for _ in 0..<30 { _ = pipeline.process(dark) }
        XCTAssertEqual(pipeline.contentRect, detected)
    }

    func testFlickeringDetectionDoesNotChangeContentRect() {
        let pipeline = ColorPipeline(channels: [top])
        let boxed = letterboxed(bar: 4, (200, 200, 200))
        let full = solid((200, 200, 200))
        for i in 0..<40 { _ = pipeline.process(i % 3 == 0 ? full : boxed) }
        XCTAssertEqual(pipeline.contentRect, .full)
    }

    func testLetterboxDisappearsAndResetForgets() {
        let pipeline = ColorPipeline(channels: [top])
        let boxed = letterboxed(bar: 4, (200, 200, 200))
        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(boxed) }
        XCTAssertNotEqual(pipeline.contentRect, .full)

        pipeline.reset()
        XCTAssertEqual(pipeline.contentRect, .full)

        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(boxed) }
        XCTAssertNotEqual(pipeline.contentRect, .full)
        // Retour au plein cadre : adopté après quelques images.
        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(solid((200, 200, 200))) }
        XCTAssertEqual(pipeline.contentRect, .full)
    }

    /// Ciel nocturne en haut seulement : pas une letterbox (bandes symétriques exigées).
    func testOneSidedDarkTopIsNotCropped() {
        let pipeline = ColorPipeline(channels: [top], tuning: neutral)
        let image = frame { _, y in y < 10 ? (0, 0, 0) : (255, 140, 0) }
        var out: [HueChannelColor] = []
        for _ in 0...ColorPipeline.stableFramesRequired + 1 { out = pipeline.process(image) }
        XCTAssertEqual(pipeline.contentRect, .full)
        XCTAssertLessThan(color(out, 3).r, 0.6)
    }

    /// Moitié gauche sombre seulement : pas une pillarbox.
    func testOneSidedDarkLeftIsNotCropped() {
        let pipeline = ColorPipeline(channels: [left], tuning: neutral)
        let image = frame { x, _ in x < 16 ? (0, 0, 0) : (0, 90, 255) }
        var out: [HueChannelColor] = []
        for _ in 0...ColorPipeline.stableFramesRequired + 1 { out = pipeline.process(image) }
        XCTAssertEqual(pipeline.contentRect, .full)
        XCTAssertLessThan(color(out, 1).b, 0.3)
    }

    /// Letterbox établie : un plan sombre en haut de l'image ne modifie pas la zone utile.
    func testLetterboxKeptDuringDarkSkyShot() {
        let pipeline = ColorPipeline(channels: [top], tuning: neutral)
        for _ in 0...ColorPipeline.stableFramesRequired { _ = pipeline.process(letterboxed(bar: 4, (0, 200, 0))) }
        let rect = pipeline.contentRect
        XCTAssertEqual(rect.y, 4.0 / 36, accuracy: 1e-9)
        let sky = frame { _, y in (y < 12 || y >= 32) ? (0, 0, 0) : (255, 140, 0) }
        for _ in 0..<20 { _ = pipeline.process(sky) }
        XCTAssertEqual(pipeline.contentRect, rect)
    }

    /// Logo de chaîne dans une bande noire : la bande est quand même détectée.
    func testCornerLogoInLetterboxBar() {
        let pipeline = ColorPipeline(channels: [top], tuning: neutral)
        let image = frame { x, y in
            if y < 4 || y >= 32 { return (x >= 56 && x <= 59 && (y == 1 || y == 2)) ? (180, 180, 180) : (0, 0, 0) }
            return (0, 200, 0)
        }
        for _ in 0...ColorPipeline.stableFramesRequired + 1 { _ = pipeline.process(image) }
        XCTAssertEqual(pipeline.contentRect.y, 4.0 / 36, accuracy: 1e-9)
    }

    /// Logo de chaîne dans une bande latérale : la pillarbox est quand même détectée.
    func testCornerLogoInPillarboxBar() {
        let pipeline = ColorPipeline(channels: [left], tuning: neutral)
        let image = frame { x, y in
            if x < 8 || x >= 56 { return (x >= 58 && x <= 61 && (y == 1 || y == 2)) ? (180, 180, 180) : (0, 0, 0) }
            return (0, 0, 200)
        }
        for _ in 0...ColorPipeline.stableFramesRequired + 1 { _ = pipeline.process(image) }
        XCTAssertEqual(pipeline.contentRect.x, 8.0 / 64, accuracy: 1e-9)
        XCTAssertEqual(pipeline.contentRect.width, 48.0 / 64, accuracy: 1e-9)
    }

    // MARK: Sous-titres

    /// Long sous-titre sur fond noir : les lampes du bas restent éteintes.
    func testLongSubtitleOnBlackKeepsBottomCornersDark() {
        let channels = [HueChannel(id: 1, x: -1, y: 0.8, z: -0.5), HueChannel(id: 2, x: -0.5, y: 0.8, z: -1),
                        HueChannel(id: 3, x: 0, y: 0, z: 0), HueChannel(id: 4, x: 1, y: 0.8, z: -0.5)]
        let pipeline = ColorPipeline(channels: channels)
        let out = pipeline.process(frame { x, y in (y >= 30 && y <= 32 && x >= 6 && x <= 57) ? (235, 235, 235) : (0, 0, 0) })
        for c in out { assertColor(c.color, 0, 0, 0) }
    }

    func testWhiteSubtitlesAreIgnored() {
        let pipeline = ColorPipeline(channels: [bottom, center], tuning: neutral)
        // Fond bleu, sous-titre blanc en bas au centre (lignes 31…34, colonnes 20…43).
        let image = frame { x, y in (y >= 31 && y <= 34 && x >= 20 && x < 44) ? (255, 255, 255) : (0, 0, 200) }
        let out = pipeline.process(image)
        assertColor(color(out, 4), 0, 0, 200.0 / 255)
        assertColor(color(out, 5), 0, 0, 200.0 / 255)
    }

    // MARK: Tailles d'image

    func testDifferentFrameSizes() {
        let pipeline = ColorPipeline(channels: [left, right, top], tuning: neutral)
        for (w, h) in [(64, 36), (32, 18), (128, 72), (16, 9), (64, 36)] {
            let out = pipeline.process(frame(w, h) { x, _ in x < w / 2 ? (255, 0, 0) : (0, 0, 255) })
            assertColor(color(out, 1), 1, 0, 0)
            assertColor(color(out, 2), 0, 0, 1)
        }
        // Image d'un seul pixel : pas de crash, la couleur du pixel.
        let tiny = pipeline.process(solid((0, 255, 0), 1, 1))
        assertColor(color(tiny, 3), 0, 1, 0)
    }

    func testLetterboxKeptAcrossFrameSizes() {
        let pipeline = ColorPipeline(channels: [top], tuning: neutral)
        for _ in 0...ColorPipeline.stableFramesRequired {
            _ = pipeline.process(letterboxed(bar: 4, (0, 200, 0)))
        }
        let rect = pipeline.contentRect
        // Même proportion en 128×72 : la zone utile ne bouge pas, la couleur reste correcte.
        let big = letterboxed(bar: 8, (0, 200, 0), width: 128, height: 72)
        for _ in 0..<10 {
            let out = pipeline.process(big)
            assertColor(color(out, 3), 0, 200.0 / 255, 0)
        }
        XCTAssertEqual(pipeline.contentRect, rect)
    }

    // MARK: Performances

    func testPerformanceBudget() {
        let channels = (0..<10).map { i -> HueChannel in
            let angle = Double(i) / 10 * 2 * Double.pi
            return HueChannel(id: UInt8(i), x: cos(angle), y: i % 3 == 0 ? -0.8 : 0.5, z: sin(angle) * 0.8)
        }
        let pipeline = ColorPipeline(channels: channels)
        let frames: [SampledFrame] = (0..<8).map { (k: Int) -> SampledFrame in
            frame { (x: Int, y: Int) -> RGB8 in
                let r = UInt8((x * 4 + k * 13) % 256)
                let g = UInt8((y * 7 + k) % 256)
                let b = UInt8((x * y + k) % 256)
                return (r, g, b)
            }
        }
        _ = pipeline.process(frames[0])
        let iterations = 300
        let start = Date()
        for i in 0..<iterations { _ = pipeline.process(frames[i % frames.count]) }
        let perFrame = Date().timeIntervalSince(start) / Double(iterations)
        print("ColorPipeline : \(String(format: "%.3f", perFrame * 1000)) ms par image 64×36, 10 canaux")
        // Budget < 1 ms en Release ; marge large pour les builds Debug des tests.
        XCTAssertLessThan(perFrame, 0.005)
    }
}
