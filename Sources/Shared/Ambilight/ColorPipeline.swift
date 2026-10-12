import Foundation

// Pipeline couleur de l'Ambilight : petite image échantillonnée → une couleur par canal Hue.
// Fichier « pur » Foundation : compilable et testable hors plateformes Apple.
//
// Étapes pour chaque image :
// 1. détection des bandes noires (letterbox haut/bas, pillarbox gauche/droite) avec hystérésis ;
// 2. zones d'échantillonnage par canal (poids précalculés, mis en cache) dans la zone utile ;
// 3. moyenne pondérée en lumière linéaire (EOTF sRGB), reconversion en gamma ;
// 4. boost de saturation à luminance constante, puis luminosité, borne 0…1.

/// Réglages du rendu des couleurs.
struct AmbilightTuning: Equatable {
    /// Échelle de sortie 0…1.
    var brightness: Double = 0.8
    /// Facteur de saturation (1 = inchangé).
    var saturationBoost: Double = 1.2
    /// Seuil (gamma, max des composantes) sous lequel un pixel est considéré noir :
    /// sert aux bandes noires et à la détection d'image noire.
    var blackThreshold: Double = 0.06

    init(brightness: Double = 0.8, saturationBoost: Double = 1.2, blackThreshold: Double = 0.06) {
        self.brightness = brightness
        self.saturationBoost = saturationBoost
        self.blackThreshold = blackThreshold
    }
}

/// Rectangle normalisé 0…1 (origine haut-gauche) de la zone utile de l'image (hors bandes noires).
struct NormalizedRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

/// Transforme les images échantillonnées en couleurs de canaux Hue.
/// Pas thread-safe : à utiliser depuis une seule file.
final class ColorPipeline {

    // MARK: Constantes

    /// Nombre d'images concordantes avant d'adopter une nouvelle zone utile (≈ 0,5 s à 12 img/s).
    static let stableFramesRequired = 6
    /// Taille maximale d'une bande noire, par côté (fraction de la hauteur / largeur).
    static let maxBarFraction = 0.4
    /// Fraction de pixels allumés tolérée dans une ligne / colonne « noire » (bruit, logo discret).
    static let barNoiseFraction = 0.03
    /// Fraction minimale de pixels allumés de la 1re ligne / colonne d'image après une bande :
    /// une vraie bande se termine par un bord net (évite de rogner un fondu ou un vignettage sombre).
    static let barEdgeFraction = 0.2
    /// Écart toléré entre deux bandes opposées (fraction de la hauteur / largeur, au moins 1 pixel) :
    /// les vraies bandes sont centrées, seul l'arrondi de la mise à l'échelle les rend inégales.
    static let barSymmetryFraction = 0.03
    /// Logo de coin (chaîne, rip) toléré dans une bande : au plus 15 % de pixels allumés dans la
    /// ligne / colonne, tous dans le quart extérieur d'un même côté.
    static let barLogoFraction = 0.15
    static let barLogoZone = 0.25
    /// En dessous de cette fraction de pixels allumés, la zone utile est considérée noire.
    static let blackContentFraction = 0.01
    /// Distance au centre (|x| ou |z|) à partir de laquelle un canal lit une bande de bord.
    static let edgeThreshold = 0.35
    /// Profondeur de la bande de bord (fraction de la largeur / hauteur utile).
    static let edgeBandDepth = 0.25
    /// Demi-étendue le long du bord de la fenêtre d'un canal de bord.
    static let edgeBandHalfLength = 0.3
    /// Écart type (fraction de la zone utile) de la fenêtre gaussienne d'un canal central.
    static let centralSpread = 0.18
    /// Étendue minimale de |x| et |z| utilisée pour normaliser les positions des canaux.
    static let minPositionExtent = 0.3
    /// Zone des sous-titres : 18 % inférieurs × 5…95 % de la largeur utile
    /// (une longue ligne de sous-titres VLC peut couvrir 10…90 % de la largeur).
    static let subtitleTop = 0.82
    static let subtitleLeft = 0.05
    static let subtitleRight = 0.95

    /// Coefficients de luminance Rec. 709 / sRGB.
    private static let lumaR = 0.2126, lumaG = 0.7152, lumaB = 0.0722

    /// EOTF sRGB (8 bits → linéaire) précalculée.
    private static let linearLUT: [Float] = (0..<256).map { i in
        let c = Double(i) / 255
        return Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
    }

    // MARK: État

    private let channels: [HueChannel]
    var tuning: AmbilightTuning
    private(set) var contentRect: NormalizedRect = .full

    /// Zone candidate en attente de confirmation (hystérésis).
    private var candidateRect: NormalizedRect?
    private var candidateCount = 0

    /// Poids d'un canal : indices de pixels et poids normalisés (somme 1).
    private struct Zone {
        var indices: [Int32]
        var weights: [Float]
    }

    /// Clé du cache des poids : taille d'image + zone utile en pixels.
    private struct ZoneKey: Equatable {
        let width: Int, height: Int
        let x0: Int, y0: Int, x1: Int, y1: Int
    }

    private var zoneKey: ZoneKey?
    private var zones: [Zone] = []

    /// Tampons réutilisés d'une image à l'autre (évite les allocations).
    private var linear: [Float] = []
    private var lit: [UInt8] = []

    init(channels: [HueChannel], tuning: AmbilightTuning = AmbilightTuning()) {
        self.channels = channels
        self.tuning = tuning
    }

    /// Oublie l'état (bandes noires) — nouveau média.
    func reset() {
        contentRect = .full
        candidateRect = nil
        candidateCount = 0
    }

    // MARK: Traitement

    /// Une couleur par canal, dans l'ordre de `channels`.
    func process(_ frame: SampledFrame) -> [HueChannelColor] {
        let width = frame.width, height = frame.height
        guard !channels.isEmpty else { return [] }
        guard width > 0, height > 0, frame.rgba.count >= width * height * 4 else {
            return blackColors()
        }
        let pixelCount = width * height
        let threshold = Self.thresholdByte(tuning.blackThreshold)

        // Conversion linéaire + repérage des pixels « allumés » en une seule passe.
        if linear.count != pixelCount * 3 { linear = [Float](repeating: 0, count: pixelCount * 3) }
        if lit.count != pixelCount { lit = [UInt8](repeating: 0, count: pixelCount) }
        var totalLit = 0
        frame.rgba.withUnsafeBufferPointer { src in
            linear.withUnsafeMutableBufferPointer { lin in
                lit.withUnsafeMutableBufferPointer { litBuf in
                    Self.linearLUT.withUnsafeBufferPointer { lut in
                        for i in 0..<pixelCount {
                            let r = src[i &* 4], g = src[i &* 4 &+ 1], b = src[i &* 4 &+ 2]
                            lin[i &* 3] = lut[Int(r)]
                            lin[i &* 3 &+ 1] = lut[Int(g)]
                            lin[i &* 3 &+ 2] = lut[Int(b)]
                            let isLit: UInt8 = Int(max(r, max(g, b))) > threshold ? 1 : 0
                            litBuf[i] = isLit
                            totalLit &+= Int(isLit)
                        }
                    }
                }
            }
        }

        // Image entièrement noire : ni détection de bandes, ni couleur.
        if totalLit <= max(0, Int(Double(pixelCount) * Self.blackContentFraction)) {
            return blackColors()
        }

        if let detected = detectContentRect(width: width, height: height) {
            updateContentRect(with: detected, width: width, height: height)
        }

        let key = pixelKey(width: width, height: height)
        if key != zoneKey {
            zones = Self.buildZones(channels: channels, key: key)
            zoneKey = key
        }

        // Zone utile quasi noire → canaux noirs.
        let contentPixels = (key.x1 - key.x0) * (key.y1 - key.y0)
        var contentLit = 0
        lit.withUnsafeBufferPointer { litBuf in
            for y in key.y0..<key.y1 {
                let row = y &* width
                for x in key.x0..<key.x1 { contentLit &+= Int(litBuf[row &+ x]) }
            }
        }
        if contentLit <= Int(Double(contentPixels) * Self.blackContentFraction) {
            return blackColors()
        }

        let tuning = self.tuning
        var output: [HueChannelColor] = []
        output.reserveCapacity(channels.count)
        linear.withUnsafeBufferPointer { lin in
            for (channel, zone) in zip(channels, zones) {
                var r: Float = 0, g: Float = 0, b: Float = 0
                zone.indices.withUnsafeBufferPointer { idx in
                    zone.weights.withUnsafeBufferPointer { w in
                        for k in 0..<idx.count {
                            let p = Int(idx[k]) &* 3
                            let wk = w[k]
                            r += wk * lin[p]
                            g += wk * lin[p &+ 1]
                            b += wk * lin[p &+ 2]
                        }
                    }
                }
                let color = Self.finish(r: Double(r), g: Double(g), b: Double(b), tuning: tuning)
                output.append(HueChannelColor(channelID: channel.id, color: color))
            }
        }
        return output
    }

    private func blackColors() -> [HueChannelColor] {
        channels.map { HueChannelColor(channelID: $0.id, color: .black) }
    }

    /// Écart maximal (en pixels) entre deux bandes opposées pour une dimension `size`.
    private static func barTolerance(_ size: Int) -> Int {
        max(1, Int(Double(size) * barSymmetryFraction))
    }

    /// Octet au-dessus duquel une composante est « allumée ».
    private static func thresholdByte(_ threshold: Double) -> Int {
        Int((max(0, min(1, threshold)) * 255).rounded(.down))
    }

    // MARK: Couleur

    /// Linéaire → gamma, boost de saturation à luminance constante, luminosité, borne 0…1.
    static func finish(r: Double, g: Double, b: Double, tuning: AmbilightTuning) -> HueRGB {
        var c = (encodeGamma(r), encodeGamma(g), encodeGamma(b))
        c = boostSaturation(c, by: tuning.saturationBoost)
        let gain = max(0, min(1, tuning.brightness))
        return HueRGB(r: clamp01(c.0 * gain), g: clamp01(c.1 * gain), b: clamp01(c.2 * gain))
    }

    /// OETF sRGB (linéaire → gamma).
    static func encodeGamma(_ value: Double) -> Double {
        let v = clamp01(value)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// Écarte chaque composante de la luminance d'un facteur `k`, puis rééchelonne pour retrouver
    /// la luminance d'origine (les composantes négatives sont ramenées à 0). Un gris reste gris.
    static func boostSaturation(_ c: (Double, Double, Double), by k: Double) -> (Double, Double, Double) {
        guard k != 1, k.isFinite, k > 0 else { return c }
        let luma = lumaR * c.0 + lumaG * c.1 + lumaB * c.2
        guard luma > 0 else { return c }
        var r = max(0, luma + (c.0 - luma) * k)
        var g = max(0, luma + (c.1 - luma) * k)
        var b = max(0, luma + (c.2 - luma) * k)
        let newLuma = lumaR * r + lumaG * g + lumaB * b
        if newLuma > 0 {
            let scale = luma / newLuma
            r *= scale; g *= scale; b *= scale
        }
        // Hors gamut : on garde la teinte en divisant par le maximum.
        let peak = max(r, max(g, b))
        if peak > 1 { r /= peak; g /= peak; b /= peak }
        return (r, g, b)
    }

    private static func clamp01(_ v: Double) -> Double {
        v.isNaN ? 0 : max(0, min(1, v))
    }

    // MARK: Bandes noires

    /// Zone utile détectée sur cette image, ou `nil` si l'image ne permet pas de conclure
    /// (bande qui ne se termine pas par un bord net : fondu, scène sombre…).
    private func detectContentRect(width: Int, height: Int) -> NormalizedRect? {
        var rowLit = [Int](repeating: 0, count: height)
        var rowMinX = [Int](repeating: width, count: height)
        var rowMaxX = [Int](repeating: -1, count: height)
        lit.withUnsafeBufferPointer { litBuf in
            for y in 0..<height {
                let row = y &* width
                var count = 0, minX = width, maxX = -1
                for x in 0..<width where litBuf[row &+ x] != 0 {
                    count &+= 1
                    if x < minX { minX = x }
                    maxX = x
                }
                rowLit[y] = count; rowMinX[y] = minX; rowMaxX[y] = maxX
            }
        }

        let rowNoise = max(1, Int(Double(width) * Self.barNoiseFraction))
        let maxRows = Int(Double(height) * Self.maxBarFraction)
        let rowEdge = max(1, Int((Double(width) * Self.barEdgeFraction).rounded(.up)))
        let rowLogo = max(rowNoise, Int(Double(width) * Self.barLogoFraction))
        let logoLeftMaxX = Int(Double(width) * Self.barLogoZone)
        let logoRightMinX = width - logoLeftMaxX
        let subtitleMinX = Int(Double(width) * 0.1)
        let subtitleMaxX = Int((Double(width) * 0.9).rounded(.up))

        func isBlackRow(_ y: Int) -> Bool { rowLit[y] <= rowNoise }
        /// Ligne compatible avec une bande : noire, ne contenant que du texte centré (sous-titres
        /// dessinés dans la bande), ou qu'un petit logo dans un coin.
        func isBarRow(_ y: Int) -> Bool {
            isBlackRow(y)
                || (rowMinX[y] >= subtitleMinX && rowMaxX[y] < subtitleMaxX
                    && rowLit[y] <= Int(Double(width) * 0.6))
                || (rowLit[y] <= rowLogo && (rowMaxX[y] < logoLeftMaxX || rowMinX[y] >= logoRightMinX))
        }

        // Bande haute / basse : dernière ligne noire de la série de lignes « compatibles » depuis le bord.
        func bar(from start: Int, step: Int) -> Int? {
            var size = 0
            var i = 0
            while i < maxRows {
                let y = start + step * i
                guard isBarRow(y) else { break }
                if isBlackRow(y) { size = i + 1 }
                i += 1
            }
            guard size > 0 else { return 0 }
            // Bord net exigé : l'une des deux premières lignes d'image doit être bien allumée.
            let first = start + step * size
            let second = first + step
            let edgeLit = max(rowLit[first], (0..<height).contains(second) ? rowLit[second] : 0)
            return edgeLit >= rowEdge ? size : nil
        }

        // Une vraie bande letterbox est centrée : haut et bas doivent concorder (± arrondi), sinon
        // c'est une image sombre d'un seul côté (ciel de nuit, plafond dans l'ombre) → pas de conclusion.
        guard let top = bar(from: 0, step: 1),
              let bottom = bar(from: height - 1, step: -1),
              abs(top - bottom) <= Self.barTolerance(height) else { return nil }
        let rowBar = min(top, bottom)
        let y0 = rowBar, y1 = height - rowBar
        guard y1 > y0 else { return nil }

        // Colonnes, comptées uniquement entre les bandes haute et basse.
        // On note aussi la première et la dernière ligne allumée de chaque colonne (logo de coin).
        var colLit = [Int](repeating: 0, count: width)
        var colMinY = [Int](repeating: y1, count: width)
        var colMaxY = [Int](repeating: -1, count: width)
        lit.withUnsafeBufferPointer { litBuf in
            for y in y0..<y1 {
                let row = y &* width
                for x in 0..<width where litBuf[row &+ x] != 0 {
                    colLit[x] &+= 1
                    if y < colMinY[x] { colMinY[x] = y }
                    colMaxY[x] = y
                }
            }
        }
        let rows = y1 - y0
        let colNoise = max(1, Int(Double(rows) * Self.barNoiseFraction))
        let maxCols = Int(Double(width) * Self.maxBarFraction)
        let colEdge = max(1, Int((Double(rows) * Self.barEdgeFraction).rounded(.up)))
        let colLogo = max(colNoise, Int(Double(rows) * Self.barLogoFraction))
        let logoTopMaxY = y0 + Int(Double(rows) * Self.barLogoZone)
        let logoBottomMinY = y1 - Int(Double(rows) * Self.barLogoZone)

        func isBlackColumn(_ x: Int) -> Bool { colLit[x] <= colNoise }
        /// Colonne compatible avec une bande : noire, ou ne contenant qu'un petit logo dans un coin.
        func isBarColumn(_ x: Int) -> Bool {
            isBlackColumn(x)
                || (colLit[x] <= colLogo && (colMaxY[x] < logoTopMaxY || colMinY[x] >= logoBottomMinY))
        }

        // Bande gauche / droite : dernière colonne noire de la série de colonnes « compatibles ».
        func sideBar(from start: Int, step: Int) -> Int? {
            var size = 0
            var i = 0
            while i < maxCols {
                let x = start + step * i
                guard isBarColumn(x) else { break }
                if isBlackColumn(x) { size = i + 1 }
                i += 1
            }
            guard size > 0 else { return 0 }
            let first = start + step * size
            let second = first + step
            let edgeLit = max(colLit[first], (0..<width).contains(second) ? colLit[second] : 0)
            return edgeLit >= colEdge ? size : nil
        }

        // Idem pour le pillarbox : bandes gauche / droite symétriques (mur dans l'ombre d'un côté → nil).
        guard let left = sideBar(from: 0, step: 1),
              let right = sideBar(from: width - 1, step: -1),
              abs(left - right) <= Self.barTolerance(width) else { return nil }
        let colBar = min(left, right)
        let x0 = colBar, x1 = width - colBar
        guard x1 > x0 else { return nil }

        let w = Double(width), h = Double(height)
        return NormalizedRect(x: Double(x0) / w, y: Double(y0) / h,
                              width: Double(x1 - x0) / w, height: Double(y1 - y0) / h)
    }

    /// Hystérésis : la zone utile ne change qu'après `stableFramesRequired` détections concordantes.
    private func updateContentRect(with detected: NormalizedRect, width: Int, height: Int) {
        let tolX = 1.5 / Double(width), tolY = 1.5 / Double(height)
        func close(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
            abs(a.x - b.x) <= tolX && abs(a.y - b.y) <= tolY
                && abs((a.x + a.width) - (b.x + b.width)) <= tolX
                && abs((a.y + a.height) - (b.y + b.height)) <= tolY
        }
        if close(detected, contentRect) {
            candidateRect = nil
            candidateCount = 0
        } else if let candidate = candidateRect, close(detected, candidate) {
            candidateCount += 1
            candidateRect = detected
            if candidateCount >= Self.stableFramesRequired {
                contentRect = detected
                candidateRect = nil
                candidateCount = 0
            }
        } else {
            candidateRect = detected
            candidateCount = 1
        }
    }

    // MARK: Zones d'échantillonnage

    /// Zone utile en pixels pour cette taille d'image (au moins 1 × 1).
    private func pixelKey(width: Int, height: Int) -> ZoneKey {
        let r = contentRect
        func px(_ v: Double, _ size: Int) -> Int { max(0, min(size, Int((v * Double(size)).rounded()))) }
        var x0 = px(r.x, width), x1 = px(r.x + r.width, width)
        var y0 = px(r.y, height), y1 = px(r.y + r.height, height)
        if x1 <= x0 { x0 = min(x0, width - 1); x1 = x0 + 1 }
        if y1 <= y0 { y0 = min(y0, height - 1); y1 = y0 + 1 }
        return ZoneKey(width: width, height: height, x0: x0, y0: y0, x1: x1, y1: y1)
    }

    /// Précalcule les poids de chaque canal dans la zone utile.
    ///
    /// Placement : les positions sont d'abord divisées par l'étendue de la zone de divertissement
    /// (max |x| et max |z| des canaux, au moins 0,3), puis u = (x/étendue+1)/2 (gauche → droite),
    /// v = (1−z/étendue)/2 (haut → bas).
    /// - Canal près d'un bord (|x| ou |z| normalisé ≥ 0,35) : bande de bord (25 % de profondeur) sur le
    ///   bord dominant, centrée sur la projection du canal le long de ce bord.
    /// - Canal central : moyenne pondérée (gaussienne d'écart type 0,18) autour du centre de la zone utile.
    /// - Canal derrière le spectateur (y < −0,5) : zone élargie.
    /// Les pixels de la zone des sous-titres sont ignorés s'il reste au moins un autre pixel.
    private static func buildZones(channels: [HueChannel], key: ZoneKey) -> [Zone] {
        let cw = Double(key.x1 - key.x0), ch = Double(key.y1 - key.y0)
        // Positions ramenées à l'étendue de la zone : des lampes groupées autour de la TV
        // (Play à x ≈ ±0,3, ruban gradient à ±0,4) lisent les bords et les coins de l'image.
        func clamped(_ v: Double) -> Double { v.isFinite ? max(-1, min(1, v)) : 0 }
        let extentX = max(minPositionExtent, channels.map { abs(clamped($0.x)) }.max() ?? 0)
        let extentZ = max(minPositionExtent, channels.map { abs(clamped($0.z)) }.max() ?? 0)
        return channels.map { channel in
            let x = clamped(channel.x) / extentX
            let z = clamped(channel.z) / extentZ
            let y = channel.y.isFinite ? channel.y : 0
            let u0 = (x + 1) / 2, v0 = (1 - z) / 2
            let spread = y < -0.5 ? 1 + 0.8 * min(1, (-0.5 - y) / 0.5) : 1
            let isEdge = max(abs(x), abs(z)) >= edgeThreshold
            let isSide = abs(x) >= abs(z)

            let depthMax = min(1, edgeBandDepth * spread)
            let halfLength = edgeBandHalfLength * spread
            let alongSigma = halfLength * 0.6
            let centralSigma = centralSpread * spread

            func weight(u: Double, v: Double) -> Double {
                if isEdge {
                    let depth: Double, along: Double
                    if isSide {
                        depth = x < 0 ? u : 1 - u
                        along = abs(v - v0)
                    } else {
                        depth = z > 0 ? v : 1 - v
                        along = abs(u - u0)
                    }
                    guard depth <= depthMax, along <= halfLength else { return 0 }
                    let a = along / alongSigma
                    return (1 - 0.5 * depth / depthMax) * exp(-0.5 * a * a)
                } else {
                    let du = (u - u0) / centralSigma, dv = (v - v0) / centralSigma
                    let w = exp(-0.5 * (du * du + dv * dv))
                    return w > 0.02 ? w : 0
                }
            }

            var indices: [Int32] = [], weights: [Double] = []
            var subIndices: [Int32] = [], subWeights: [Double] = []
            var bestIndex = Int32(key.y0 * key.width + key.x0), bestDistance = Double.infinity
            for py in key.y0..<key.y1 {
                let v = (Double(py - key.y0) + 0.5) / ch
                for px in key.x0..<key.x1 {
                    let u = (Double(px - key.x0) + 0.5) / cw
                    let index = Int32(py * key.width + px)
                    let d = (u - u0) * (u - u0) + (v - v0) * (v - v0)
                    if d < bestDistance { bestDistance = d; bestIndex = index }
                    let w = weight(u: u, v: v)
                    guard w > 0 else { continue }
                    if v >= subtitleTop && u >= subtitleLeft && u <= subtitleRight {
                        subIndices.append(index); subWeights.append(w)
                    } else {
                        indices.append(index); weights.append(w)
                    }
                }
            }
            if indices.isEmpty {
                indices = subIndices; weights = subWeights
            }
            if indices.isEmpty {
                // Zone utile minuscule : le pixel le plus proche du canal.
                indices = [bestIndex]; weights = [1]
            }
            let total = weights.reduce(0, +)
            return Zone(indices: indices, weights: weights.map { Float($0 / total) })
        }
    }
}
