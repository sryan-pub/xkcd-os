// Runs the app's dark-mode rendering over comic images on the Mac.
// Build:  swiftc -O Shared/NightComic.swift XKCDReader/Model/ComicUpscaler.swift scripts/night_check/main.swift -o /tmp/night_check
// Use:    night_check OUT_DIR image1 image2 ...
// Writes OUT_DIR/<name>.png for every image and prints "<name> <treatment> <milliseconds>".
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: night_check OUT_DIR images..."); exit(1) }
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let writeImages = ProcessInfo.processInfo.environment["NIGHT_CHECK_STATS_ONLY"] == nil

for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print(name, "unreadable 0"); continue }
    // NIGHT_CHECK_SCALE=2.5 enlarges first, as the app does for a big screen.
    var image = loaded
    if let text = ProcessInfo.processInfo.environment["NIGHT_CHECK_SCALE"], let factor = Double(text),
       let enlarged = ComicUpscaler.upscale(image, by: factor) { image = enlarged }
    // NIGHT_CHECK_THUMB=700 renders a card-sized copy, deciding from the full image as the app does.
    var reference: CGImage?
    if let text = ProcessInfo.processInfo.environment["NIGHT_CHECK_THUMB"], let side = Double(text) {
        let f = min(1, side / Double(max(image.width, image.height)))
        let tw = max(1, Int(Double(image.width) * f)), th = max(1, Int(Double(image.height) * f))
        let c = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.interpolationQuality = .high
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        c.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        reference = loaded
        image = c.makeImage()!
    }
    let comicNumber = Int(name.prefix { $0.isNumber })
    let start = Date()
    // NIGHT_CHECK_PLAIN=1 uses the plain invert instead of the region rules.
    let plain = ProcessInfo.processInfo.environment["NIGHT_CHECK_PLAIN"] != nil
    let rendered = plain ? NightComic.plainInvert(image).map { NightComic.Result(image: $0, treatment: .inverted) } : NightComic.render(image, decidingFrom: reference ?? (image === loaded ? nil : loaded), comic: ProcessInfo.processInfo.environment["NIGHT_CHECK_NO_OVERRIDES"] == nil ? comicNumber : nil)
    guard let result = rendered else { print(name, "failed 0"); continue }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    // How much of the result is still bright: a redrawn comic should be mostly dark.
    var small = [UInt8](repeating: 0, count: 64 * 64 * 4)
    small.withUnsafeMutableBytes { buffer in
        let c = CGContext(data: buffer.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.interpolationQuality = .medium
        c.draw(result.image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    var bright = 0
    for i in stride(from: 0, to: small.count, by: 4) {
        if (Int(small[i]) * 54 + Int(small[i + 1]) * 183 + Int(small[i + 2]) * 19) >> 8 > 150 { bright += 1 }
    }
    print(name, result.treatment.rawValue, ms, "\(image.width)x\(image.height)", String(format: "%.3f", result.solidShare),
          String(format: "%.3f", Double(bright) / 4096))
    guard writeImages else { continue }

    // Composite onto the page colour the app uses behind that treatment, so the sheet shows the card.
    let pad = 12, w = image.width + pad * 2, h = image.height + pad * 2
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let card: CGFloat = result.treatment == .photo ? 1 : (result.treatment == .alreadyDark ? 0 : CGFloat(NightComic.paper))
    ctx.setFillColor(CGColor(gray: card, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(result.image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
    let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
