import CoreGraphics
import CoreML
import Foundation
import VideoToolbox

/// Enlarges comics with a small neural network trained only on xkcd's own images (the 1x and 2x
/// versions of the same comics). The model and the code to rebuild it live in the separate
/// `xkcd-upscaler` project.
///
/// The network does exactly 2x. It runs once or twice to fill a screen and `ComicUpscaler` then
/// resizes the result to the exact size.
final class ModelUpscaler: @unchecked Sendable {
    /// Loaded on first use. Nil if the model is missing or won't load, and the app falls back to
    /// its hand-written method.
    static let shared: ModelUpscaler? = {
        guard let url = Bundle.main.url(forResource: "XkcdUpscaler", withExtension: "mlmodelc") else { return nil }
        return try? ModelUpscaler(compiledModel: url)
    }()

    private let model: MLModel
    private let lock = NSLock()

    init(compiledModel: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)
    }

    /// Sizes the model accepts. Bigger pictures don't need enlarging in practice.
    static let maximumSide = 2048
    static let minimumSide = 32

    /// Returns `image` at exactly twice its width and height, or nil if it's outside the accepted
    /// sizes or the prediction fails.
    func upscale2x(_ image: CGImage) -> CGImage? {
        let sides = [image.width, image.height]
        guard sides.allSatisfy({ $0 >= Self.minimumSide && $0 <= Self.maximumSide }) else { return nil }
        // The model has no alpha, so lay the comic on white first.
        guard let flat = Self.flattened(image),
              let input = try? MLFeatureValue(cgImage: flat, pixelsWide: flat.width, pixelsHigh: flat.height,
                                              pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let provider = try? MLDictionaryFeatureProvider(dictionary: ["image": input]) else { return nil }
        // One prediction at a time. Several comics get prepared at once and the model is shared.
        lock.lock()
        let output = try? model.prediction(from: provider)
        lock.unlock()
        guard let buffer = output?.featureValue(for: "upscaled")?.imageBufferValue else { return nil }
        var result: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &result)
        return result
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

    private static func flattened(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
