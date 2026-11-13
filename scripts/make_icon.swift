// Draws every app icon (light and dark) plus the small previews the in-app picker shows.
// Run from the repo root:
//   swift scripts/make_icon.swift XKCDReader/Assets.xcassets
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let catalog = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "XKCDReader/Assets.xcassets")

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

struct Palette {
    let background: CGColor   // the slate blue of the comic grid, or its night version
    let paper: CGColor        // what comics are drawn on
    let ink: CGColor
    let heart = rgb(0.90, 0.16, 0.18)

    static let light = Palette(background: rgb(0.60, 0.66, 0.78), paper: rgb(1, 1, 1), ink: rgb(0.07, 0.07, 0.08))
    static let dark = Palette(background: rgb(0.08, 0.09, 0.12), paper: rgb(0.17, 0.19, 0.24), ink: rgb(0.93, 0.94, 0.96))
}

struct Pen {
    let ctx: CGContext
    let p: Palette

    func fill(_ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }

    func card(_ rect: CGRect, radius: CGFloat = 54, stroke: CGFloat = 20) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path); ctx.setFillColor(p.paper); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(p.ink); ctx.setLineWidth(stroke); ctx.strokePath()
    }

    func line(_ points: [CGPoint], width: CGFloat) {
        ctx.setStrokeColor(p.ink); ctx.setLineWidth(width)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.addLines(between: points); ctx.strokePath()
    }

    /// A stick figure whose head is centred at `head`, scaled by `s` (1 = 124pt head).
    func figure(head: CGPoint, s: CGFloat, width: CGFloat) {
        let r = 62 * s
        ctx.setStrokeColor(p.ink); ctx.setLineWidth(width)
        ctx.strokeEllipse(in: CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2))
        let neck = CGPoint(x: head.x, y: head.y + r), hip = CGPoint(x: head.x, y: head.y + r + 120 * s)
        line([neck, hip], width: width)
        line([CGPoint(x: head.x - 64 * s, y: neck.y + 100 * s), CGPoint(x: head.x, y: neck.y + 42 * s),
              CGPoint(x: head.x + 64 * s, y: neck.y + 100 * s)], width: width)
        line([CGPoint(x: head.x - 54 * s, y: hip.y + 90 * s), hip, CGPoint(x: head.x + 54 * s, y: hip.y + 90 * s)], width: width)
    }

    func heart(center: CGPoint, w: CGFloat, stroke: CGFloat) {
        let cx = center.x, cy = center.y
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: cy + 0.45 * w))
        path.addCurve(to: CGPoint(x: cx - 0.5 * w, y: cy - 0.12 * w),
                      control1: CGPoint(x: cx - 0.2 * w, y: cy + 0.27 * w), control2: CGPoint(x: cx - 0.5 * w, y: cy + 0.1 * w))
        path.addCurve(to: CGPoint(x: cx, y: cy - 0.2 * w),
                      control1: CGPoint(x: cx - 0.5 * w, y: cy - 0.46 * w), control2: CGPoint(x: cx - 0.12 * w, y: cy - 0.46 * w))
        path.addCurve(to: CGPoint(x: cx + 0.5 * w, y: cy - 0.12 * w),
                      control1: CGPoint(x: cx + 0.12 * w, y: cy - 0.46 * w), control2: CGPoint(x: cx + 0.5 * w, y: cy - 0.46 * w))
        path.addCurve(to: CGPoint(x: cx, y: cy + 0.45 * w),
                      control1: CGPoint(x: cx + 0.5 * w, y: cy + 0.1 * w), control2: CGPoint(x: cx + 0.2 * w, y: cy + 0.27 * w))
        path.closeSubpath()
        ctx.addPath(path); ctx.setFillColor(p.heart); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(p.ink); ctx.setLineWidth(stroke); ctx.setLineJoin(.round); ctx.strokePath()
    }

    func lettering(in rect: CGRect, lengths: [CGFloat], top: CGFloat, gap: CGFloat, inset: CGFloat, width: CGFloat) {
        for (row, length) in lengths.enumerated() {
            let y = rect.minY + top + CGFloat(row) * gap
            line([CGPoint(x: rect.minX + inset, y: y), CGPoint(x: rect.minX + inset + length, y: y)], width: width)
        }
    }
}

// MARK: - Designs

/// A tiny mosaic of comic cards: the app's grid in miniature.
func mosaic(_ pen: Pen) {
    pen.fill(pen.p.background)
    let tallLeft = CGRect(x: 110, y: 110, width: 380, height: 470)
    let shortLeft = CGRect(x: 110, y: 624, width: 380, height: 290)
    let shortRight = CGRect(x: 534, y: 110, width: 380, height: 290)
    let tallRight = CGRect(x: 534, y: 444, width: 380, height: 470)
    [tallLeft, shortLeft, shortRight, tallRight].forEach { pen.card($0) }
    pen.figure(head: CGPoint(x: 300, y: 258), s: 1, width: 20)
    pen.lettering(in: shortRight, lengths: [260, 260, 170], top: 82, gap: 64, inset: 60, width: 22)
    pen.lettering(in: shortLeft, lengths: [260, 200, 260], top: 82, gap: 64, inset: 60, width: 22)
    pen.heart(center: CGPoint(x: tallRight.midX, y: tallRight.midY - 6), w: 220, stroke: 16)
}

/// One stick figure on a single sheet of paper.
func figure(_ pen: Pen) {
    pen.fill(pen.p.background)
    pen.card(CGRect(x: 150, y: 110, width: 724, height: 804), radius: 90, stroke: 30)
    pen.figure(head: CGPoint(x: 512, y: 330), s: 2.0, width: 38)
}

/// A favorite: the heart on its card.
func heart(_ pen: Pen) {
    pen.fill(pen.p.background)
    pen.card(CGRect(x: 150, y: 150, width: 724, height: 724), radius: 110, stroke: 30)
    pen.heart(center: CGPoint(x: 512, y: 500), w: 440, stroke: 30)
}

/// The alt text: a speech bubble full of lettering.
func bubble(_ pen: Pen) {
    pen.fill(pen.p.background)
    let body = CGRect(x: 130, y: 170, width: 764, height: 520)
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 300, y: 670)); tail.addLine(to: CGPoint(x: 250, y: 880)); tail.addLine(to: CGPoint(x: 470, y: 670))
    tail.closeSubpath()
    // Tail first, then the body over its top edge so the two read as one outline.
    pen.ctx.addPath(tail); pen.ctx.setFillColor(pen.p.paper); pen.ctx.fillPath()
    pen.ctx.addPath(tail); pen.ctx.setStrokeColor(pen.p.ink); pen.ctx.setLineWidth(30); pen.ctx.setLineJoin(.round); pen.ctx.strokePath()
    pen.card(body, radius: 130, stroke: 30)
    pen.ctx.setFillColor(pen.p.paper)
    pen.ctx.fill(CGRect(x: 316, y: 650, width: 138, height: 26))      // open the seam between body and tail
    pen.lettering(in: body, lengths: [520, 520, 340], top: 150, gap: 110, inset: 122, width: 36)
}

// MARK: - Output

func render(_ draw: (Pen) -> Void, _ palette: Palette, size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(size) / 1024
    ctx.translateBy(x: 0, y: CGFloat(size))          // work in top-left coordinates, 1024 units wide
    ctx.scaleBy(x: scale, y: -scale)
    draw(Pen(ctx: ctx, p: palette))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func writeSet(_ folder: URL, contents: String, images: [(String, CGImage)]) {
    try? FileManager.default.removeItem(at: folder)
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! contents.write(to: folder.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    for (name, image) in images { write(image, to: folder.appendingPathComponent(name)) }
}

let iconContents = """
{
  "images" : [
    { "filename" : "light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
let previewContents = """
{
  "images" : [
    { "filename" : "light.png", "idiom" : "universal" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "dark.png", "idiom" : "universal" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""

// The first is the primary icon ("AppIcon"); the rest are alternates the user can pick.
let designs: [(name: String, draw: (Pen) -> Void)] = [("Mosaic", mosaic), ("Figure", figure), ("Heart", heart), ("Bubble", bubble)]
for (index, design) in designs.enumerated() {
    let iconSet = index == 0 ? "AppIcon" : "AppIcon-\(design.name)"
    writeSet(catalog.appendingPathComponent("\(iconSet).appiconset"), contents: iconContents,
             images: [("light.png", render(design.draw, .light, size: 1024)), ("dark.png", render(design.draw, .dark, size: 1024))])
    writeSet(catalog.appendingPathComponent("IconPreview-\(design.name).imageset"), contents: previewContents,
             images: [("light.png", render(design.draw, .light, size: 240)), ("dark.png", render(design.draw, .dark, size: 240))])
    print("wrote \(iconSet) and IconPreview-\(design.name)")
}

// The original "xkcd: Open Source" icon (Mike Amaral's app, MIT; xkcd characters by Randall
// Munroe, CC BY-NC 2.5) is kept as artwork next to this script. Its dark version is the same
// drawing inverted: white lines on black.
let classicURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("classic-icon.png")
if let source = CGImageSourceCreateWithURL(classicURL as CFURL, nil), let classic = CGImageSourceCreateImageAtIndex(source, 0, nil) {
    func renderClassic(dark: Bool, size: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.draw(classic, in: rect)
        if dark {
            ctx.setBlendMode(.difference)
            ctx.setFillColor(rgb(1, 1, 1))
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }
    writeSet(catalog.appendingPathComponent("AppIcon-Classic.appiconset"), contents: iconContents,
             images: [("light.png", renderClassic(dark: false, size: 1024)), ("dark.png", renderClassic(dark: true, size: 1024))])
    writeSet(catalog.appendingPathComponent("IconPreview-Classic.imageset"), contents: previewContents,
             images: [("light.png", renderClassic(dark: false, size: 240)), ("dark.png", renderClassic(dark: true, size: 240))])
    print("wrote AppIcon-Classic and IconPreview-Classic")
} else {
    print("skipped the classic icon: \(classicURL.path) not found")
}
