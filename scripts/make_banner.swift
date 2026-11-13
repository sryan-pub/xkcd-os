// Draws Screenshots/banner.png for the README: the app icon and the name in the xkcd font.
// Run from the repo root:  swift scripts/make_banner.swift
import AppKit

let width: CGFloat = 1280, height: CGFloat = 320
let slate = NSColor(srgbRed: 0.60, green: 0.66, blue: 0.78, alpha: 1)
let ink = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)

let fontURL = URL(fileURLWithPath: "XKCDReader/Resources/Fonts/xkcd.otf")
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as! [CTFontDescriptor]
let font = CTFontCreateWithFontDescriptor(descriptors[0], 92, nil) as NSFont

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
slate.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

let icon = NSImage(contentsOfFile: "XKCDReader/Assets.xcassets/AppIcon.appiconset/light.png")!
let side: CGFloat = 220
let titleWidth = NSAttributedString(string: "xkcd: Open Source", attributes: [.font: font]).size().width
let left = (width - side - 50 - titleWidth) / 2
let iconRect = NSRect(x: left, y: (height - side) / 2, width: side, height: side)
NSBezierPath(roundedRect: iconRect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
icon.draw(in: iconRect)
NSGraphicsContext.current?.cgContext.resetClip()

let title = NSAttributedString(string: "xkcd: Open Source", attributes: [.font: font, .foregroundColor: ink])
let size = title.size()
title.draw(at: NSPoint(x: iconRect.maxX + 50, y: (height - size.height) / 2 + 10))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Screenshots/banner.png"))
