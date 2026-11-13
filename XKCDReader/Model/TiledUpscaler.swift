import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// The same 2x enlargement as `ModelUpscaler`, done in fixed 512 px tiles with
/// `XkcdUpscalerTile.mlpackage` so Core ML can run it on the Neural Engine, which it only does for
/// fixed-size inputs. The output matches the flexible model to within rounding.
///
/// The comic is laid on white, its edge pixels are repeated outward, and it is cut into 512 px
/// tiles overlapping by 32 px. Each tile is enlarged to 1024 px and only its middle 960 px is
/// kept, so nothing within 16 input pixels of a cut is used. The network's receptive field is 6
/// pixels each way (plus 8 of its own padding), so the kept parts are identical to enlarging the
/// whole picture at once and there are no seams.
///
/// Accepts any size from 1 pixel up to `maximumSide` per side, including pictures smaller than one
/// tile and very tall ones (a column of tiles).
final class TiledUpscaler: @unchecked Sendable {
    private let model: MLModel
    private let lock = NSLock()
    /// Input tiles, created once and reused (guarded by `lock`).
    private var buffers: [CVPixelBuffer] = []

    /// Model input side, the part of each side that is discarded, and the step between tiles.
    static let tile = 512
    static let margin = 16
    static let stride = tile - 2 * margin

    /// Tiles handed to Core ML per batch. Each is about 1 MB in and 4 MB out, so this also caps
    /// working memory (about 40 MB at 8).
    static let batch = 8

    /// Same upper limit as the flexible model so the two are interchangeable.
    static let maximumSide = 2048

    /// - Parameters:
    ///   - compiledModel: URL of `XkcdUpscalerTile.mlmodelc`.
    ///   - computeUnits: `.cpuAndNeuralEngine` keeps the work off the GPU. Without a usable Neural
    ///     Engine, Core ML runs the model on the CPU instead (slower, same output).
    init(compiledModel: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)
    }

    /// Returns `image` at exactly twice its width and height, or nil if it is too large or a
    /// prediction fails.
    func upscale2x(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w >= 1, h >= 1, w <= Self.maximumSide, h <= Self.maximumSide else { return nil }
        // The comic on white, as bytes in the pixel buffer order the model uses (B, G, R, x).
        guard let source = Self.bitmap(width: w, height: h) else { return nil }
        source.setFillColor(CGColor(gray: 1, alpha: 1))
        source.fill(CGRect(x: 0, y: 0, width: w, height: h))
        source.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = Self.bitmap(width: w * 2, height: h * 2),
              let sourceBytes = source.data, let resultBytes = result.data else { return nil }
        let sourceRow = source.bytesPerRow, resultRow = result.bytesPerRow

        var corners: [(left: Int, top: Int)] = []
        for top in Swift.stride(from: 0, to: h, by: Self.stride) {
            for left in Swift.stride(from: 0, to: w, by: Self.stride) {
                corners.append((left, top))
            }
        }

        // One comic at a time. Several get prepared at once, and the model and tile buffers are shared
        // for the length of this call.
        lock.lock()
        defer { lock.unlock() }
        while buffers.count < min(Self.batch, corners.count) {
            guard let buffer = Self.pixelBuffer(side: Self.tile) else { return nil }
            buffers.append(buffer)
        }
        // Batches to Core ML are nearly twice as fast as one tile at a time.
        for start in Swift.stride(from: 0, to: corners.count, by: Self.batch) {
            let group = corners[start..<min(start + Self.batch, corners.count)]
            var inputs: [MLFeatureProvider] = []
            for (index, corner) in group.enumerated() {
                Self.fill(buffers[index], from: sourceBytes, rowBytes: sourceRow, width: w, height: h,
                          left: corner.left - Self.margin, top: corner.top - Self.margin)
                guard let provider = try? MLDictionaryFeatureProvider(
                    dictionary: ["image": MLFeatureValue(pixelBuffer: buffers[index])]) else { return nil }
                inputs.append(provider)
            }
            guard let outputs = try? model.predictions(fromBatch: MLArrayBatchProvider(array: inputs)),
                  outputs.count == group.count else { return nil }
            for (index, corner) in group.enumerated() {
                guard let enlarged = outputs.features(at: index).featureValue(for: "upscaled")?.imageBufferValue else { return nil }
                Self.keepMiddle(of: enlarged, into: resultBytes, rowBytes: resultRow,
                                width: w * 2, height: h * 2, left: corner.left * 2, top: corner.top * 2)
            }
        }
        return result.makeImage()
    }

    /// Enlarges toward `factor`, running 2x passes while more than 1.25x is still missing (at most
    /// two). The caller resizes to the exact size. Nil if no pass ran.
    func upscale(_ image: CGImage, towards factor: Double) -> CGImage? {
        var current = image, remaining = factor, passes = 0
        while remaining > 1.25, passes < 2, let next = upscale2x(current) {
            current = next
            remaining /= 2
            passes += 1
        }
        return passes > 0 ? current : nil
    }

    // MARK: - Pieces

    /// sRGB bitmap with bytes B, G, R, unused, matching a 32BGRA pixel buffer.
    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    private static func pixelBuffer(side: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        // IOSurface-backed, which Core ML can hand to the Neural Engine without a copy.
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attributes, &buffer)
        return buffer
    }

    /// Copies the `tile` x `tile` window with its corner at (`left`, `top`) into `buffer`. Where
    /// the window hangs past the picture's edge, the nearest edge pixel is repeated.
    private static func fill(_ buffer: CVPixelBuffer, from source: UnsafeMutableRawPointer, rowBytes: Int,
                             width: Int, height: Int, left: Int, top: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bufferRow = CVPixelBufferGetBytesPerRow(buffer)
        // Columns of the window that lie inside the picture.
        let inside0 = max(0, -left), inside1 = min(tile, width - left)
        for y in 0..<tile {
            let from = source + min(height - 1, max(0, top + y)) * rowBytes
            let to = (base + y * bufferRow).assumingMemoryBound(to: UInt32.self)
            let pixels = from.assumingMemoryBound(to: UInt32.self)
            if inside1 > inside0 {
                memcpy(to + inside0, pixels + left + inside0, (inside1 - inside0) * 4)
            }
            let first = pixels[0], last = pixels[width - 1]
            for x in 0..<max(0, min(tile, inside0)) { to[x] = first }
            for x in max(0, inside1)..<tile { to[x] = last }
        }
    }

    /// Copies the middle of an enlarged tile (everything more than 2 x `margin` from its edges) to
    /// (`left`, `top`) in the result, skipping anything past the result's edges.
    private static func keepMiddle(of buffer: CVPixelBuffer, into result: UnsafeMutableRawPointer, rowBytes: Int,
                                   width: Int, height: Int, left: Int, top: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bufferRow = CVPixelBufferGetBytesPerRow(buffer)
        let skip = 2 * margin, side = 2 * stride
        let columns = min(side, width - left), rows = min(side, height - top)
        guard columns > 0 else { return }
        for y in 0..<max(0, rows) {
            memcpy(result + (top + y) * rowBytes + left * 4, base + (skip + y) * bufferRow + skip * 4, columns * 4)
        }
    }
}

extension TiledUpscaler {
    /// Loaded on first use. Nil if the model is missing or won't load, and the app then uses the
    /// whole-picture model.
    static let shared: TiledUpscaler? = {
        guard let url = Bundle.main.url(forResource: "XkcdUpscalerTile", withExtension: "mlmodelc") else { return nil }
        return try? TiledUpscaler(compiledModel: url)
    }()
}
