import CoreGraphics
import CoreImage
import Foundation

/// Enlarges a comic that is smaller than the screen it fills. Plain stretching leaves lettering
/// soft and jagged, so this resamples with a Lanczos filter and then, for black-and-white comics,
/// steepens the greys at each edge to make lines crisp.
///
/// Only CoreImage and CoreGraphics, so `scripts/night_check` can run it on the Mac.
enum ComicUpscaler {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// How strongly edges are firmed up after enlarging. 0 leaves the Lanczos result alone, 1 is a
    /// steep curve. A steep curve alone makes hand-drawn lines wobbly by exaggerating the jaggies of
    /// the small original, so `smoothing` removes those first. Both values were tuned by eye on an
    /// iPad Pro.
    static var edgeStrength = 2.0

    /// Slight blur applied after enlarging and before firming the edges, in pixels of the enlarged
    /// picture. Removes the jaggies the firming would otherwise exaggerate.
    static var smoothing = 0.3

    /// When set, `smoothing` is in pixels of the small original (the blur grows with the
    /// enlargement) and the work happens at `supersample` times the final size before scaling down,
    /// for cleaner anti-aliased edges. Picked from side-by-side crops of small comics at 3x, where a
    /// fixed small blur left lines soft.
    static var smoothingInSourcePixels = true
    static var supersample = 2.0
    /// How far to look for the two tones an edge runs between, in widths of the soft band.
    static var reachFactor = 1.5

    /// Bump when the tuning changes so cached results made with old values aren't reused.
    static var tuningKey: String { "\(Int(edgeStrength * 100))-\(Int(smoothing * 100))-\(method.rawValue)" }

    /// Ways to enlarge a comic. Always `standard` outside Debug Mode.
    enum Method: String, CaseIterable {
        case tiles      // the trained model, in fixed tiles, on the Neural Engine
        case whole      // the trained model on the whole picture at once (graphics processor)
        case classic    // the hand-written method below

        /// The default. On an iPad Pro the Neural Engine tiles took 73 ms per comic, the whole picture
        /// on the GPU 127 to 239 ms, and the hand-written method about a second. If the tiled model
        /// can't load or declines, the whole-picture model is used.
        static let standard = Method.tiles

        /// Short name for the debug button.
        var label: String {
            switch self {
            case .tiles: "NE"
            case .whole: "GPU"
            case .classic: "Classic"
            }
        }
    }

    static let methodKey = "enlargeMethod"
    static var method: Method {
        #if !DEBUG && !targetEnvironment(simulator)
        return .standard  // Debug Mode is left out of device release builds (see DebugMode.swift)
        #else
        guard UserDefaults.standard.bool(forKey: "debugMode"),
              let chosen = UserDefaults.standard.string(forKey: methodKey).flatMap(Method.init) else { return .standard }
        return chosen
        #endif
    }

    /// Last enlargement (method, size, time) for the debug read-out.
    static let didEnlarge = Notification.Name("ComicUpscaler.didEnlarge")

    /// The trained enlarger, if available. Given a comic and a factor it returns the comic at 2x or
    /// 4x, or nil to decline. Set by the app at launch and left unset in the command-line tools,
    /// which then use the hand-written method below.
    nonisolated(unsafe) static var modelEnlarger: ((CGImage, Double, Method) -> CGImage?)?


    /// Returns `image` enlarged by `factor` (clamped to 1...4), or nil if there is nothing to do.
    static func upscale(_ image: CGImage, by factor: Double) -> CGImage? {
        let method = self.method
        let started = Date()
        let result = enlarge(image, by: factor, method: method)
        if let result {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let report = "\(method.label)  \(image.width)x\(image.height) to \(result.width)x\(result.height)  \(ms) ms"
            NotificationCenter.default.post(name: didEnlarge, object: report)
        }
        return result
    }

    /// Just the enlargement, with the method given explicitly (see `EnlargeBenchmark`).
    static func enlargeForBenchmark(_ image: CGImage, by factor: Double, method: Method) -> CGImage? {
        enlarge(image, by: factor, method: method)
    }

    private static func enlarge(_ image: CGImage, by factor: Double, method: Method) -> CGImage? {
        let factor = min(4, factor)
        guard factor > 1.15 else { return nil }
        // Keep the result to a size a phone can hold comfortably.
        let limit = 24_000_000.0
        let pixels = Double(image.width * image.height) * factor * factor
        let fitScale = pixels > limit ? factor * (limit / pixels).squareRoot() : factor
        guard fitScale > 1.15 else { return nil }

        let finalScale = fitScale

        // Try the trained enlarger first. It produces 2x or 4x, and a normal high-quality resize then
        // brings that to the exact size (usually down).
        if method != .classic, let enlarger = modelEnlarger, let enlarged = enlarger(image, fitScale, method) {
            let exact = CGRect(x: 0, y: 0, width: (Double(image.width) * fitScale).rounded(.down),
                               height: (Double(image.height) * fitScale).rounded(.down))
            let step = exact.width / Double(enlarged.width)
            if abs(step - 1) < 0.01 { return enlarged }
            if let resize = CIFilter(name: "CILanczosScaleTransform") {
                resize.setValue(CIImage(cgImage: enlarged).clampedToExtent(), forKey: kCIInputImageKey)
                resize.setValue(step, forKey: kCIInputScaleKey)
                resize.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let output = resize.outputImage,
                   let result = context.createCGImage(output, from: exact, format: .RGBA8,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
                    return result
                }
            }
        }
        let lineArtFirst = edgeStrength > 0 && !hasColour(image)
        // Working oversized costs memory, so ease off for big pictures.
        let finalPixels = Double(image.width * image.height) * finalScale * finalScale
        let oversize = max(1, min(supersample, (12_000_000 / finalPixels).squareRoot()))
        let scale = lineArtFirst ? finalScale * oversize : finalScale
        var result = CIImage(cgImage: image)
        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        // Extend the edge pixels outward first. Otherwise the filter blends the outer rows with the
        // empty space beyond the picture and leaves a pale line around dark comics.
        let target = CGRect(x: 0, y: 0, width: (Double(image.width) * scale).rounded(.down),
                            height: (Double(image.height) * scale).rounded(.down))
        lanczos.setValue(result.clampedToExtent(), forKey: kCIInputImageKey)
        lanczos.setValue(scale, forKey: kCIInputScaleKey)
        lanczos.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard let scaled = lanczos.outputImage else { return nil }
        result = scaled

        let lineArt = lineArtFirst
        // Smooth, then firm up. Colour comics skip both since a blur with no firming afterwards only
        // softens them.
        if lineArt, smoothing > 0.01 {
            let sigma = smoothingInSourcePixels ? smoothing * scale : smoothing
            result = result.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: target)
        }
        guard let enlarged = context.createCGImage(result, from: target, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        guard lineArt else { return enlarged }
        let firmed = firmEdges(enlarged, scale: scale) ?? enlarged
        guard oversize > 1.01 else { return firmed }
        // Scale down to the final size. Averaging the oversized picture smooths the edges.
        let w = Int((Double(image.width) * finalScale).rounded(.down)), h = Int((Double(image.height) * finalScale).rounded(.down))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return firmed }
        ctx.interpolationQuality = .high
        ctx.draw(firmed, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? firmed
    }

    /// Narrows the soft band that enlarging leaves along every line without touching flat areas.
    /// Each pixel on a slope between two tones is pushed toward the nearer one, where the two tones
    /// are the darkest and lightest values close by. A grey fill keeps its exact grey (nothing nearby
    /// differs) and a line drawn on grey sharpens between black and that grey. A plain contrast curve
    /// over the whole picture would push every mid-grey toward black or white and ruin shaded comics.
    private static func firmEdges(_ image: CGImage, scale: Double) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 2, h > 2 else { return nil }
        var grey = [UInt8](repeating: 255, count: w * h)
        let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // The soft band is about `scale` pixels wide. Look that far for the two tones, but not so far
        // as to reach across a line to whatever is on its other side.
        let reach = max(1, Int((scale * reachFactor).rounded()))
        // Whether a pixel is on a soft edge at all is judged over about half that distance, which
        // includes the faint outer tail of the edge. Judging from immediate neighbours only missed that
        // tail and left a pale ghost outline.
        let near = max(1, reach / 2)
        let (near0, near1) = localRange(grey, w: w, h: h, radius: near)
        let (lo, hi) = reach == near ? (near0, near1) : localRange(grey, w: w, h: h, radius: reach)

        // A grey fill and the sliver of paper inside a "$" or an "8" can have the same value, since the
        // sliver is only a pixel wide in the original and never fully white. The difference is room:
        // somewhere inside a fill there is a spot with nothing dark nearby, and inside a tangle of
        // strokes there isn't. `open` is the lightest such clear level nearby. Dark means a tangle, and
        // there the light tone is taken to be paper.
        let open = localRange(lo, w: w, h: h, radius: reach).high

        // S-curve between the two tones, steeper for a higher `edgeStrength`.
        let power = 1 + 2.6 * edgeStrength
        var curve = [Float](repeating: 0, count: 257)
        for i in 0...256 {
            let t = Double(i) / 256
            curve[i] = Float(t < 0.5 ? 0.5 * pow(2 * t, power) : 1 - 0.5 * pow(2 * (1 - t), power))
        }

        var out = grey
        for i in 0..<(w * h) {
            // How much of a slope this pixel is on, from its immediate neighbours.
            let slope = Int(near1[i]) - Int(near0[i])
            guard slope > 3 else { continue }
            let low = Int(lo[i])
            var high = Int(hi[i])
            let tangle = min(1, max(0, Float(110 - Int(open[i])) / 60))
            if tangle > 0 { high += Int(Float(255 - high) * tangle) }
            let span = high - low
            guard span > 12 else { continue }
            let v = Int(grey[i])
            let target = Float(low) + Float(span) * curve[min(256, max(0, (v - low) * 256 / span))]
            let weight = min(1, Float(slope - 3) / 12)
            out[i] = UInt8(max(0, min(255, (Float(v) + weight * (target - Float(v))).rounded())))
        }

        return out.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    /// Darkest and lightest value within `radius` pixels of each pixel (square window, done across
    /// then down).
    private static func localRange(_ grey: [UInt8], w: Int, h: Int, radius: Int) -> (low: [UInt8], high: [UInt8]) {
        var rowLow = grey, rowHigh = grey
        grey.withUnsafeBufferPointer { src in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w {
                    var lo: UInt8 = 255, hi: UInt8 = 0
                    for n in max(0, x - radius)...min(w - 1, x + radius) {
                        let v = src[row + n]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                    }
                    rowLow[row + x] = lo
                    rowHigh[row + x] = hi
                }
            }
        }
        var low = rowLow, high = rowHigh
        rowLow.withUnsafeBufferPointer { lows in
            rowHigh.withUnsafeBufferPointer { highs in
                for y in 0..<h {
                    let y0 = max(0, y - radius), y1 = min(h - 1, y + radius)
                    for x in 0..<w {
                        var lo: UInt8 = 255, hi: UInt8 = 0
                        var n = y0
                        while n <= y1 {
                            let a = lows[n * w + x], b = highs[n * w + x]
                            if a < lo { lo = a }
                            if b > hi { hi = b }
                            n += 1
                        }
                        low[y * w + x] = lo
                        high[y * w + x] = hi
                    }
                }
            }
        }
        return (low, high)
    }

    /// True if a noticeable share of the picture is coloured rather than black, white or grey.
    private static func hasColour(_ image: CGImage) -> Bool {
        let side = 48
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        var coloured = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if max(r, g, b) - min(r, g, b) > 30 { coloured += 1 }
        }
        return Double(coloured) / Double(side * side) > 0.01
    }
}
