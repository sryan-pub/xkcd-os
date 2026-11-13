import CoreGraphics
import Foundation

/// Redraws a comic for dark mode.
///
/// - Paper (light areas with drawing on them, or that reach the picture's edge) becomes a dark
///   page and the ink on it becomes light.
/// - Dark backgrounds (night skies, black panels with white lettering) stay as drawn, along with
///   the light details inside them.
/// - Dark objects drawn on paper (a silhouette, a tyre) flip with the rest of the ink.
/// - Colours keep their hue and only lightness flips.
/// - Photographs are left alone.
///
/// Only CoreGraphics, so `scripts/night_check` can compile this file on the Mac and run it over
/// every comic.
enum NightComic {
    /// Page colour (0 = black, 1 = white). Dark grey, easier on the eyes than black.
    static let paper: Double = 0.13

    enum Treatment: String {
        case inverted        // something was redrawn
        case alreadyDark     // nothing needed changing
        case photo           // photograph: left exactly as drawn
    }

    struct Result {
        let image: CGImage
        let treatment: Treatment
        /// Fraction of the picture that is dark background kept as drawn. Only used by the checks.
        var solidShare: Double = 0
    }

    private static let light: UInt8 = 0     // paper, or light artwork
    private static let ink: UInt8 = 1       // pen strokes, and dark shapes drawn on paper
    private static let solid: UInt8 = 2     // dark background

    /// What to flip, decided on a copy of the comic drawn at `w` x `h`.
    private struct Analysis {
        var flipMask: [Bool] = []       // one entry per pixel of the analysis copy
        var treatment: Treatment
        var solidShare: Double = 0
    }

    /// Per-comic result of the slow analysis. It depends only on the published comic, so it is
    /// computed once and cached on disk (a few KB). Redrawing a card or the full-size comic then
    /// just applies it.
    struct Decision {
        var treatment: Treatment
        /// Size of the working copy the mask was made on.
        var width: Int
        var height: Int
        /// One entry per pixel of the working copy, flip or keep. Empty unless `inverted`.
        var flipMask: [Bool]
        var solidShare: Double = 0

        /// Bump when the rules change so cached decisions from older rules are dropped.
        static let rulesVersion = 1

        /// Run-length encoded mask, usually a handful of bytes.
        func encoded() -> Data {
            var out = Data([0x4E, 0x43, UInt8(Self.rulesVersion),
                            treatment == .inverted ? 0 : (treatment == .alreadyDark ? 1 : 2)])
            func put(_ value: Int) {
                var v = UInt64(value)
                repeat {
                    let byte = UInt8(v & 0x7F)
                    v >>= 7
                    out.append(v == 0 ? byte : byte | 0x80)
                } while v != 0
            }
            put(width); put(height); put(Int((solidShare * 1000).rounded()))
            var current = false, run = 0
            for flip in flipMask {
                if flip == current { run += 1 } else { put(run); current = flip; run = 1 }
            }
            put(run)
            return out
        }

        init(treatment: Treatment, width: Int, height: Int, flipMask: [Bool], solidShare: Double = 0) {
            self.treatment = treatment; self.width = width; self.height = height
            self.flipMask = flipMask; self.solidShare = solidShare
        }

        init?(data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count >= 7, bytes[0] == 0x4E, bytes[1] == 0x43, bytes[2] == UInt8(Self.rulesVersion), bytes[3] <= 2 else { return nil }
            var at = 4
            func take() -> Int? {
                var value: UInt64 = 0, shift: UInt64 = 0
                while at < bytes.count, shift < 63 {
                    let byte = bytes[at]; at += 1
                    value |= UInt64(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { return Int(value) }
                    shift += 7
                }
                return nil
            }
            guard let w = take(), let h = take(), let share = take(), w > 0, h > 0, w * h <= 8_000_000 else { return nil }
            treatment = bytes[3] == 0 ? .inverted : (bytes[3] == 1 ? .alreadyDark : .photo)
            width = w; height = h; solidShare = Double(share) / 1000
            var mask = [Bool](); var current = false
            if treatment == .inverted {
                mask.reserveCapacity(w * h)
                while let run = take() {
                    guard mask.count + run <= w * h else { return nil }
                    mask.append(contentsOf: repeatElement(current, count: run))
                    current.toggle()
                }
                guard mask.count == w * h else { return nil }
            }
            flipMask = mask
        }
    }

    /// Whether a comic has a hand-set treatment, so no decision is needed.
    static func hasOverride(_ comic: Int?) -> Bool { comic.map { overrides[$0] != nil } ?? false }

    /// The slow analysis of what to flip, from the published comic.
    static func decide(from basis: CGImage, analysisPixels: Double = analysisPixelLimit) -> Decision? {
        let bw = basis.width, bh = basis.height
        guard bw > 4, bh > 4 else { return nil }
        // Decide at a fixed working size so the thumbnail, full-size and enlarged versions all get the
        // same treatment.
        let scale = min(Double(analysisWidth) / Double(bw), (analysisPixels / Double(bw * bh)).squareRoot())
        let aw = max(5, Int((Double(bw) * scale).rounded())), ah = max(5, Int((Double(bh) * scale).rounded()))
        guard let analysis = analyse(basis, w: aw, h: ah) else { return nil }
        return Decision(treatment: analysis.treatment, width: aw, height: ah, flipMask: analysis.flipMask,
                        solidShare: analysis.solidShare)
    }

    /// Comics the rules get wrong, by number, with what to do instead. Only add one after the rules
    /// have failed on it.
    enum Override {
        case asDrawn        // leave the comic exactly as published
        case plainInvert    // flip everything
        /// Leave the picture as drawn and flip only the paper around it (margins, gutters, captions),
        /// plus any listed areas given as fractions of width and height.
        case paperOnly(alsoFlip: [CGRect] = [])
    }

    static let overrides: [Int: Override] = [
        // Full-colour or tonal pictures, which flipping lightness ruins.
        170: .paperOnly(),      // painted canyon
        319: .paperOnly(),      // painted desert
        1212: .paperOnly(),     // star map, cream discs on black
        2038: .paperOnly(),     // yellow hazard sign
        2414: .paperOnly(),     // greyscale gradient
        2463: .paperOnly(),     // eclipse
        2715: .paperOnly(),     // grey-toned woodland scene
        2849: .paperOnly(),     // painted blue skies
        // Dark panels with only a speech bubble or two, which the rules read as black objects on
        // paper and turn white.
        313: .paperOnly(),
        649: .paperOnly(),
        686: .paperOnly(),
        1969: .paperOnly(),
        117: .paperOnly(),      // Pong screens
        521: .paperOnly(),      // black squares in a grid of panels
        767: .paperOnly(),
        1194: .paperOnly(),     // Earth in space
        1342: .paperOnly(),
        1377: .paperOnly(),
        2338: .paperOnly(),
        3017: .paperOnly(),     // the Earth as a white disc on black
        // More full-colour pictures.
        1040: .asDrawn,         // cross-section of the oceans, colour to every edge
        1492: .paperOnly(),     // the dress: its colours are the whole point
        1815: .paperOnly(),     // a flag
        2840: .asDrawn,         // layers of the Earth, colour to the edges
        3096: .paperOnly(),     // photograph of the Sun
        // Others.
        1734: .plainInvert,     // a page of text the rules leave white
        2803: .plainInvert,     // a map: black land on a white sea, every part simply flips
        3231: .asDrawn,         // lightning at night: the sky is cut into pieces the rules misread
        // Lunar panels. The dense white ground hides that the sky is a sky. The first panel is a normal
        // one on paper.
        3294: .paperOnly(alsoFlip: [CGRect(x: 0, y: 0, width: 0.243, height: 1)]),
    ]

    /// Redraws `source` for dark mode. When `reference` (the published comic) is given, the
    /// decision comes from it so the thumbnail, full-size and enlarged copies match. Pass an
    /// earlier `decision` to skip the analysis.
    static func render(_ source: CGImage, decidingFrom reference: CGImage? = nil, comic: Int? = nil,
                       analysisPixels: Double = analysisPixelLimit, decision: Decision? = nil) -> Result? {
        if let comic, let override = overrides[comic] {
            switch override {
            case .asDrawn:
                return Result(image: source, treatment: .alreadyDark)
            case .plainInvert:
                return plainInvert(source).map { Result(image: $0, treatment: .inverted) }
            case .paperOnly(let alsoFlip):
                return paperOnly(source, alsoFlip: alsoFlip, captions: true).map { Result(image: $0, treatment: .inverted) }
            }
        }
        let w = source.width, h = source.height
        guard w > 4, h > 4, w * h <= 40_000_000 else { return nil }

        guard let analysis = decision ?? decide(from: reference ?? source, analysisPixels: analysisPixels) else { return nil }
        let aw = analysis.width, ah = analysis.height
        guard analysis.treatment == .inverted, analysis.flipMask.count == aw * ah else {
            // A dark comic can still have slivers of white paper at its edges and corners.
            let image = analysis.treatment == .alreadyDark ? paperOnly(source, alsoFlip: [], captions: false) ?? source : source
            return Result(image: image, treatment: analysis.treatment, solidShare: analysis.solidShare)
        }

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let lift = Int((paper * 255).rounded())
        let mask = analysis.flipMask
        let output = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = buffer.bindMemory(to: UInt8.self)
            for y in 0..<h {
                let ay = min(ah - 1, y * ah / h)
                for x in 0..<w {
                    let ax = min(aw - 1, x * aw / w)
                    let i = (y * w + x) * 4
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    let flip = mask[ay * aw + ax]
                    // Pixels on the seam between kept and flipped areas blend a dark area with white paper, and
                    // both end up dark. Take the darker of the two versions there or a pale line is left.
                    var onSeam = false
                    let x0 = max(0, ax - 1), x1 = min(aw - 1, ax + 1), y0 = max(0, ay - 1), y1 = min(ah - 1, ay + 1)
                    search: for ny in y0...y1 {
                        for nx in x0...x1 where mask[ny * aw + nx] != flip {
                            onSeam = true
                            break search
                        }
                    }
                    guard flip || onSeam else { continue }
                    // Flip lightness and keep hue: c + (1 - max - min). Then screen with the page colour so black
                    // becomes the page and white stays white.
                    let shift = 255 - max(r, g, b) - min(r, g, b)
                    let lightness = (r * 54 + g * 183 + b * 19) >> 8
                    let flippedLightness = 255 - (255 - (lightness + shift)) * (255 - lift) / 255
                    if onSeam && flippedLightness >= lightness { continue }
                    for c in 0..<3 {
                        let flipped = Int(p[i + c]) + shift
                        p[i + c] = UInt8(255 - (255 - flipped) * (255 - lift) / 255)
                    }
                }
            }
            return ctx.makeImage()
        }
        guard let output else { return nil }
        return Result(image: output, treatment: .inverted, solidShare: analysis.solidShare)
    }

    /// Working size: twice xkcd's standard width, where lettering resolves cleanly.
    private static let analysisWidth = 1480
    /// Widgets have far less memory and pass a smaller limit.
    static let analysisPixelLimit = 6_000_000.0

    private static func analyse(_ source: CGImage, w: Int, h: Int) -> Analysis? {
        let count = w * h

        var pixels = [UInt8](repeating: 255, count: count * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))      // transparent comics sit on white paper
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // 1. Light or dark, per pixel.
        var kind = [UInt8](repeating: light, count: count)
        var midTones = 0
        var paperWhite = 0
        pixels.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let lum = (Int(p[i * 4]) * 54 + Int(p[i * 4 + 1]) * 183 + Int(p[i * 4 + 2]) * 19) >> 8
                if lum < 128 { kind[i] = ink }
                if lum > 70 && lum < 185 { midTones += 1 }
                if lum > 245 { paperWhite += 1 }
            }
        }

        // 2. Photographs have smooth tones everywhere and no blank paper. A colour drawing with white
        //    paper around it still counts as a drawing.
        if Double(midTones) / Double(count) > 0.42 && Double(paperWhite) / Double(count) < 0.08
            && looksPhotographic(pixels, w: w, h: h) {
            return Analysis(treatment: .photo)
        }

        // 3. Separate filled dark areas from pen strokes. A dark pixel is "core" if nearly all of its
        //    surroundings are dark too (a few stars or specks are allowed). Everything dark within reach
        //    of a core pixel belongs to a filled area. A stroke that only touches a filled area stays ink.
        let reach = max(3, min(w, h) / 90)
        var core = [Bool](repeating: false, count: count)
        var anyCore = false
        if w > reach * 2 + 1 && h > reach * 2 + 1 {
            // Summed-area table of dark pixels.
            let tw = w + 1
            var table = [Int32](repeating: 0, count: tw * (h + 1))
            for y in 0..<h {
                var row: Int32 = 0
                for x in 0..<w {
                    if kind[y * w + x] == ink { row += 1 }
                    table[(y + 1) * tw + x + 1] = table[y * tw + x + 1] + row
                }
            }
            let side = reach * 2 + 1
            let needed = Int32(Double(side * side) * 0.8)
            for y in reach..<(h - reach) {
                for x in reach..<(w - reach) {
                    guard kind[y * w + x] == ink else { continue }
                    let x0 = x - reach, y0 = y - reach, x1 = x + reach + 1, y1 = y + reach + 1
                    let dark = table[y1 * tw + x1] - table[y0 * tw + x1] - table[y1 * tw + x0] + table[y0 * tw + x0]
                    if dark >= needed {
                        core[y * w + x] = true
                        anyCore = true
                    }
                }
            }
        }
        if anyCore {
            // Grow the core by `reach` (rows, then columns) to get the area it may claim,
            var grownRows = [Bool](repeating: false, count: count)
            for y in 0..<h {
                var lastCore = -1 - reach
                for x in 0..<w where core[y * w + x] {
                    let from = max(max(0, x - reach), lastCore + 1)
                    let to = min(w - 1, x + reach)
                    if from <= to { for fill in from...to { grownRows[y * w + fill] = true } }
                    lastCore = to
                }
            }
            var claim = [Bool](repeating: false, count: count)
            for x in 0..<w {
                var lastFilled = -1
                for y in 0..<h where grownRows[y * w + x] {
                    let from = max(max(0, y - reach), lastFilled + 1)
                    let to = min(h - 1, y + reach)
                    if from <= to {
                        for fill in from...to where kind[fill * w + x] == ink { claim[fill * w + x] = true }
                    }
                    lastFilled = to
                }
            }
            // then keep only what connects to the core through dark pixels. Otherwise the claim leaks
            // across a thin white stroke into the hole of a white letter O.
            var frontier: [Int32] = []
            for i in 0..<count where core[i] {
                kind[i] = solid
                frontier.append(Int32(i))
            }
            while let top = frontier.popLast() {
                let i = Int(top)
                let x = i % w, y = i / w
                if x > 0, claim[i - 1], kind[i - 1] == ink { kind[i - 1] = solid; frontier.append(Int32(i - 1)) }
                if x < w - 1, claim[i + 1], kind[i + 1] == ink { kind[i + 1] = solid; frontier.append(Int32(i + 1)) }
                if y > 0, claim[i - w], kind[i - w] == ink { kind[i - w] = solid; frontier.append(Int32(i - w)) }
                if y < h - 1, claim[i + w], kind[i + w] == ink { kind[i + w] = solid; frontier.append(Int32(i + w)) }
            }
        }

        // 4. Group pixels of the same kind into regions.
        var labels = [Int32](repeating: 0, count: count)        // 0 = unvisited
        var regionKind: [UInt8] = [light]                       // index = label
        var regionTouchesBorder: [Bool] = [false]
        var regionArea: [Int] = [0]
        var regionBoxArea: [Int] = [0]
        var regionIsThick: [Bool] = [false]                     // filled, as opposed to a pen stroke
        var regionSpansPicture: [Bool] = [false]                // reaches two opposite edges
        var regionIsBar: [Bool] = [false]                       // long, straight and filled: a gutter
        var stack: [Int32] = []
        stack.reserveCapacity(4096)

        for start in 0..<count where labels[start] == 0 {
            let label = Int32(regionKind.count)
            let k = kind[start]
            var area = 0
            var touchesBorder = false
            var minX = w, maxX = 0, minY = h, maxY = 0
            labels[start] = label
            stack.append(Int32(start))
            while let top = stack.popLast() {
                let i = Int(top)
                area += 1
                let x = i % w, y = i / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if x > 0, labels[i - 1] == 0, kind[i - 1] == k { labels[i - 1] = label; stack.append(Int32(i - 1)) }
                if x < w - 1, labels[i + 1] == 0, kind[i + 1] == k { labels[i + 1] = label; stack.append(Int32(i + 1)) }
                if y > 0, labels[i - w] == 0, kind[i - w] == k { labels[i - w] = label; stack.append(Int32(i - w)) }
                if y < h - 1, labels[i + w] == 0, kind[i + w] == k { labels[i + w] = label; stack.append(Int32(i + w)) }
            }
            regionKind.append(k)
            regionIsThick.append(k == solid)
            regionSpansPicture.append((minX == 0 && maxX == w - 1) || (minY == 0 && maxY == h - 1))
            let boxW = maxX - minX + 1, boxH = maxY - minY + 1
            regionIsBar.append(area * 100 >= boxW * boxH * 85 && max(boxW, boxH) >= 8 * min(boxW, boxH) && max(boxW, boxH) * 3 >= min(w, h))
            regionTouchesBorder.append(touchesBorder)
            regionArea.append(area)
            regionBoxArea.append((maxX - minX + 1) * (maxY - minY + 1))
        }
        let regionCount = regionKind.count

        /// Calls `body(a, b)` for every pair of different regions that share an edge.
        func forEachNeighbourPair(_ body: (Int, Int) -> Void) {
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let a = Int(labels[i])
                    if x + 1 < w {
                        let b = Int(labels[i + 1])
                        if a != b { body(a, b); body(b, a) }
                    }
                    if y + 1 < h {
                        let b = Int(labels[i + w])
                        if a != b { body(a, b); body(b, a) }
                    }
                }
            }
        }

        // 5. Find which dark areas are backgrounds: filled dark areas with light details in them (stars
        //    in a sky, white lettering on a black panel). An empty dark area (a silhouetted mountain, a
        //    tyre, a black bar) is an object on paper at any size and flips like other ink.
        var firstNeighbour = [Int32](repeating: 0, count: regionCount)
        var hasSeveralNeighbours = [Bool](repeating: false, count: regionCount)
        var edges = Set<UInt64>()
        forEachNeighbourPair { a, b in
            if firstNeighbour[a] == 0 { firstNeighbour[a] = Int32(b) }
            else if firstNeighbour[a] != Int32(b) { hasSeveralNeighbours[a] = true }
            if a < b { edges.insert(UInt64(a) << 32 | UInt64(b)) }
        }
        var neighbours = [[Int32]](repeating: [], count: regionCount)
        for edge in edges {
            let a = Int(edge >> 32), b = Int(edge & 0xFFFF_FFFF)
            neighbours[a].append(Int32(b))
            neighbours[b].append(Int32(a))
        }

        var detailsInside = [Int](repeating: 0, count: regionCount)
        for label in 1..<regionCount where regionKind[label] == light {
            guard !regionTouchesBorder[label], !hasSeveralNeighbours[label] else { continue }
            let holder = Int(firstNeighbour[label])
            if holder > 0, regionKind[holder] != light { detailsInside[holder] += 1 }
        }
        var solidArea = 0
        for label in 1..<regionCount where regionKind[label] != light {
            let panelShaped = Double(regionArea[label]) >= 0.75 * Double(regionBoxArea[label])
            if regionIsThick[label] && regionArea[label] * 100 >= count
                && (detailsInside[label] >= 12 || (detailsInside[label] >= 4 && panelShaped)) {
                regionKind[label] = solid
                solidArea += regionArea[label]
            } else {
                regionKind[label] = ink
            }
        }

        // Dark gaps inside a background (between white letters on a black panel) come out of step 3 as
        // separate slivers. A sliver touching a background and no real paper joins that background.
        let largeShape = max(1, count * 15 / 1000)
        for label in 1..<regionCount where regionKind[label] == ink && !regionIsThick[label] {
            var touchesBackground = false, touchesPaper = false
            for other in neighbours[label] {
                let o = Int(other)
                if regionKind[o] == solid { touchesBackground = true }
                if regionKind[o] == light && (regionTouchesBorder[o] || regionArea[o] >= largeShape) { touchesPaper = true }
            }
            if touchesBackground && (!touchesPaper || regionArea[label] * 300 < count) {
                regionKind[label] = solid
                solidArea += regionArea[label]
            }
        }

        // A light area is blank if no pen stroke is drawn on it (dark holes inside the shape and filled
        // objects don't count). Blank light shapes touching a background are artwork, like lightning or
        // a moon. A filled dark area separated from the background only by such artwork (sky on the far
        // side of a lightning bolt) is still background.
        var isHole = [Bool](repeating: false, count: regionCount)
        for label in 1..<regionCount where regionKind[label] == ink {
            let holder = Int(firstNeighbour[label])
            isHole[label] = !regionTouchesBorder[label] && !hasSeveralNeighbours[label]
                && holder > 0 && regionKind[holder] == light
        }
        var isArtwork = [Bool](repeating: false, count: regionCount)
        for label in 1..<regionCount where regionKind[label] == light {
            var hasStroke = false, touchesBackground = false
            for other in neighbours[label] {
                let o = Int(other)
                if regionKind[o] == solid { touchesBackground = true }
                if regionKind[o] == ink && !regionIsThick[o] && !isHole[o] { hasStroke = true }
            }
            isArtwork[label] = touchesBackground && !hasStroke
        }
        for label in 1..<regionCount where regionKind[label] == ink && regionIsThick[label] {
            if neighbours[label].contains(where: { isArtwork[Int($0)] }) {
                regionKind[label] = solid
                solidArea += regionArea[label]
            }
        }
        let mostlyDark = Double(solidArea) / Double(count) > 0.5

        // 6. Decide what flips. Start from paper: light areas that reach the picture's edge (in a mostly
        //    dark comic, only ones running all the way across, which are margins and gutters). Ink drawn
        //    on paper flips, light areas that ink encloses or borders count as paper, and so on.
        //    Backgrounds stop the spread, so anything inside a night sky or black panel stays as drawn.
        var flips = [Bool](repeating: false, count: regionCount)
        var queue: [Int] = []
        for label in 1..<regionCount where regionKind[label] != solid {
            let atEdge = regionTouchesBorder[label] && !isArtwork[label] && (!mostlyDark || regionSpansPicture[label])
            // A frame drawn at the picture's edge counts as the edge, and a straight white bar between
            // panels is a gutter even when the panels box it in.
            if atEdge || (regionKind[label] == light && regionIsBar[label]) {
                flips[label] = true
                queue.append(label)
            }
        }
        while let label = queue.popLast() {
            let wanted: UInt8 = regionKind[label] == light ? ink : light
            for other in neighbours[label] {
                let o = Int(other)
                if regionKind[o] == wanted && !flips[o] && (!isArtwork[o] || regionIsBar[o]) {
                    flips[o] = true
                    queue.append(o)
                }
            }
        }
        guard flips.contains(true) else {
            return Analysis(treatment: .alreadyDark, solidShare: Double(solidArea) / Double(count))
        }

        return Analysis(flipMask: labels.map { flips[Int($0)] }, treatment: .inverted,
                        solidShare: Double(solidArea) / Double(count))
    }

    /// Flips only the paper around a picture: near-white reached from the edge, small marks on it
    /// when `captions` is set (caption lettering), and the listed areas (fractions of width and
    /// height). Everything else stays as drawn.
    static func paperOnly(_ source: CGImage, alsoFlip: [CGRect], captions: Bool) -> CGImage? {
        let w = source.width, h = source.height
        guard w > 4, h > 4, w * h <= 40_000_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let lift = Int((paper * 255).rounded())
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = buffer.bindMemory(to: UInt8.self)

            func isWhite(_ i: Int) -> Bool {
                (Int(p[i * 4]) * 54 + Int(p[i * 4 + 1]) * 183 + Int(p[i * 4 + 2]) * 19) >> 8 >= 236
            }
            // 1 = flip, 2 = looked at and kept.
            var mark = [UInt8](repeating: 0, count: w * h)
            var queue = [Int]()
            func seed(_ i: Int) { if mark[i] == 0, isWhite(i) { mark[i] = 1; queue.append(i) } }
            var cleaned = false
            if !captions {
                // A dark picture with rounded corners leaves a pale dot of paper in each corner. Black out
                // anything not dark that connects to the corner.
                let box = max(3, min(w, h) / 60)
                for (cx, cy) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
                    var stack = [(cx, cy)]
                    while let (x, y) = stack.popLast() {
                        guard abs(x - cx) < box, abs(y - cy) < box else { continue }
                        let i = (y * w + x) * 4
                        guard max(p[i], p[i + 1], p[i + 2]) > 24 else { continue }
                        p[i] = 0; p[i + 1] = 0; p[i + 2] = 0
                        mark[y * w + x] = 2
                        cleaned = true
                        stack.append((x + (cx == 0 ? 1 : -1), y))
                        stack.append((x, y + (cy == 0 ? 1 : -1)))
                    }
                }
            }
            for x in 0..<w { seed(x); seed((h - 1) * w + x) }
            for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
            var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % w, y = i / w
                if x > 0 { seed(i - 1) }
                if x < w - 1 { seed(i + 1) }
                if y > 0 { seed(i - w) }
                if y < h - 1 { seed(i + w) }
            }
            if queue.isEmpty && alsoFlip.isEmpty { return cleaned ? ctx.makeImage() : nil }

            for rect in alsoFlip {
                let x0 = max(0, Int(rect.minX * CGFloat(w))), x1 = min(w, Int(rect.maxX * CGFloat(w)))
                let y0 = max(0, Int(rect.minY * CGFloat(h))), y1 = min(h, Int(rect.maxY * CGFloat(h)))
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 { for x in x0..<x1 { mark[y * w + x] = 1 } }
            }

            if captions {
                // Lettering on the paper is small islands surrounded by it. Panels are big ones.
                let maxSide = max(6, Int(Double(max(w, h)) * 0.07))
                var island = [Int]()
                for start in 0..<(w * h) where mark[start] == 0 {
                    island.removeAll(keepingCapacity: true)
                    island.append(start)
                    mark[start] = 2
                    var minX = w, maxX = 0, minY = h, maxY = 0, next = 0
                    while next < island.count {
                        let i = island[next]; next += 1
                        let x = i % w, y = i / w
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        for dy in -1...1 {
                            for dx in -1...1 where dx != 0 || dy != 0 {
                                let nx = x + dx, ny = y + dy
                                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                                let n = ny * w + nx
                                if mark[n] == 0 { mark[n] = 2; island.append(n) }
                            }
                        }
                    }
                    // Judged by height only, since letters in a line often touch and merge.
                    if maxY - minY < maxSide {
                        for i in island { mark[i] = 1 }
                    }
                }
            }

            // The soft edge between picture and paper blends the two. Take the darker version there so no
            // pale outline is left around the picture.
            let reach = max(1, w / 500)
            // Find pixels within reach of flipped paper in two passes (across, then down) so large enlarged
            // comics stay fast.
            var across = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                var last = -1_000_000
                for x in 0..<w { if mark[y * w + x] == 1 { last = x }; if x - last <= reach { across[y * w + x] = true } }
                last = 1_000_000
                for x in stride(from: w - 1, through: 0, by: -1) { if mark[y * w + x] == 1 { last = x }; if last - x <= reach { across[y * w + x] = true } }
            }
            var near = [Bool](repeating: false, count: w * h)
            for x in 0..<w {
                var last = -1_000_000
                for y in 0..<h { if across[y * w + x] { last = y }; if y - last <= reach { near[y * w + x] = true } }
                last = 1_000_000
                for y in stride(from: h - 1, through: 0, by: -1) { if across[y * w + x] { last = y }; if last - y <= reach { near[y * w + x] = true } }
            }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let onSeam = mark[i] != 1 && near[i]
                    let flip = mark[i] == 1 || onSeam
                    guard flip else { continue }
                    let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
                    let shift = 255 - max(r, g, b) - min(r, g, b)
                    if onSeam {
                        let lightness = (r * 54 + g * 183 + b * 19) >> 8
                        if 255 - (255 - (lightness + shift)) * (255 - lift) / 255 >= lightness { continue }
                    }
                    for c in 0..<3 {
                        let flipped = Int(p[i * 4 + c]) + shift
                        p[i * 4 + c] = UInt8(255 - (255 - flipped) * (255 - lift) / 255)
                    }
                }
            }
            return ctx.makeImage()
        }
    }

    /// Plain invert of the whole picture: lightness flipped, hue kept, black lifted to the page
    /// colour. For comics where every region should flip.
    static func plainInvert(_ source: CGImage) -> CGImage? {
        let w = source.width, h = source.height
        guard w > 0, h > 0, w * h <= 40_000_000 else { return nil }
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let lift = Int((paper * 255).rounded())
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = buffer.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                let r = Int(p[i * 4]), g = Int(p[i * 4 + 1]), b = Int(p[i * 4 + 2])
                let shift = 255 - max(r, g, b) - min(r, g, b)
                for c in 0..<3 {
                    let flipped = Int(p[i * 4 + c]) + shift
                    p[i * 4 + c] = UInt8(255 - (255 - flipped) * (255 - lift) / 255)
                }
            }
            return ctx.makeImage()
        }
    }

    /// Drawings use a handful of flat colours, photographs and paintings use thousands.
    private static func looksPhotographic(_ pixels: [UInt8], w: Int, h: Int) -> Bool {
        var seen = Set<Int>()
        let stepX = max(1, w / 96), stepY = max(1, h / 96)
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let i = (y * w + x) * 4
                seen.insert((Int(pixels[i]) >> 4) << 8 | (Int(pixels[i + 1]) >> 4) << 4 | Int(pixels[i + 2]) >> 4)
                x += stepX
            }
            y += stepY
        }
        return seen.count > 260
    }
}
