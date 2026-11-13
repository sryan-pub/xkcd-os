// Quick checks of the parts of the app that would break silently. Run with scripts/run_checks.sh.
// They compile the app's own source files into a command-line tool on the Mac; no simulator needed.
import CoreGraphics
import Foundation

var failures = 0
func check(_ ok: @autoclosure () -> Bool, _ what: String) {
    if ok() { print("  ok    \(what)") } else { failures += 1; print("  FAIL  \(what)") }
}

func greyImage(_ w: Int, _ h: Int, _ value: (Int, Int) -> UInt8) -> CGImage {
    var px = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { px[y * w + x] = value(x, y) } }
    return px.withUnsafeMutableBytes { b in
        CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
    }
}

func greys(_ image: CGImage) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: image.width * image.height)
    px.withUnsafeMutableBytes { b in
        let c = CGContext(data: b.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                          bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return px
}

@MainActor func run() async {
    print("Dark-mode decisions (saved to disk, so the format must round-trip)")
    var generator = SystemRandomNumberGenerator()
    let masks: [(String, [Bool])] = [
        ("all kept", Array(repeating: false, count: 60 * 40)),
        ("all flipped", Array(repeating: true, count: 60 * 40)),
        ("alternating", (0..<2400).map { $0 % 2 == 0 }),
        ("random", (0..<2400).map { _ in Bool.random(using: &generator) }),
        ("long runs", (0..<2400).map { ($0 / 700) % 2 == 1 }),
    ]
    for (name, mask) in masks {
        let decision = NightComic.Decision(treatment: .inverted, width: 60, height: 40, flipMask: mask, solidShare: 0.25)
        let back = NightComic.Decision(data: decision.encoded())
        check(back?.flipMask == mask && back?.width == 60 && back?.height == 40 && back?.treatment == .inverted, "round trip: \(name)")
    }
    let photo = NightComic.Decision(treatment: .photo, width: 10, height: 10, flipMask: [])
    check(NightComic.Decision(data: photo.encoded())?.treatment == .photo, "round trip: photograph (no mask)")
    check(NightComic.Decision(data: Data([1, 2, 3])) == nil, "rubbish data is rejected")
    var cut = NightComic.Decision(treatment: .inverted, width: 60, height: 40, flipMask: masks[2].1).encoded()
    cut.removeLast(40)
    check(NightComic.Decision(data: cut) == nil, "a file cut short is rejected, not half-read")

    print("Dark-mode redraw")
    let white = greyImage(64, 64) { _, _ in 255 }
    if let plain = NightComic.plainInvert(white) {
        let page = UInt8((NightComic.paper * 255).rounded())
        check(greys(plain).allSatisfy { abs(Int($0) - Int(page)) <= 2 }, "white paper becomes the dark page colour")
    } else { check(false, "plain invert returned an image") }
    let black = greyImage(64, 64) { _, _ in 0 }
    if let plain = NightComic.plainInvert(black) {
        check(greys(plain).allSatisfy { $0 >= 250 }, "black ink becomes white")
    } else { check(false, "plain invert returned an image") }

    print("Reading state merged between devices")
    typealias Mark = UserState.Mark
    var local: [Int: Mark] = [1: Mark(on: true, t: 100), 2: Mark(on: true, t: 100), 3: Mark(on: false, t: 50)]
    let changed = UserState.merge(&local, with: [1: Mark(on: false, t: 200), 2: Mark(on: false, t: 50),
                                                 3: Mark(on: true, t: 50), 4: Mark(on: true, t: 10)])
    check(changed, "merge reports a change")
    check(local[1] == Mark(on: false, t: 200), "a later change on the other device wins (un-favoriting syncs)")
    check(local[2] == Mark(on: true, t: 100), "an older change on the other device is ignored")
    check(local[3] == Mark(on: true, t: 50), "a tie keeps the mark on, so nothing is lost")
    check(local[4] == Mark(on: true, t: 10), "a comic only the other device knows is added")
    var same = local
    check(!UserState.merge(&same, with: local), "merging identical states changes nothing")

    print("Explanation text clean-up")
    let html = """
    <div class="mw-parser-output"><h2><span id="Explanation">Explanation</span></h2>
    <table class="notice"><tr><td>This is one of 69 incomplete explanations</td></tr></table>
    <p>Megan&#39;s comment is <b>correct</b> &amp; <a href="/x">linked</a>.<sup>[1]</sup></p>
    <h3>Details</h3><ul><li>First&nbsp;point</li><li>Second &#8212; point</li></ul>
    <p>   </p></div>
    """
    let blocks = ExplanationClient.blocks(fromHTML: html)
    check(blocks.count == 4, "four blocks: paragraph, heading, two bullets (got \(blocks.count))")
    check(blocks.first?.text == "Megan's comment is correct & linked.", "tags, footnote marks and entities are cleaned")
    check(blocks.dropFirst().first?.kind == .heading && blocks.dropFirst().first?.text == "Details", "sub-heading kept")
    check(blocks.last?.kind == .bullet && blocks.last?.text == "Second \u{2014} point", "bullets and numbered entities")
    check(!blocks.contains { $0.text.contains("incomplete") }, "the wiki's notice box is dropped")

    print("Enlarging (hand-written fallback)")
    ComicUpscaler.modelEnlarger = nil
    let flat = greyImage(80, 60) { _, _ in 180 }
    if let big = ComicUpscaler.upscale(flat, by: 3) {
        check(big.width == 240 && big.height == 180, "3x gives exactly 3x the size")
        check(greys(big).allSatisfy { abs(Int($0) - 180) <= 1 }, "a flat grey fill stays that grey")
    } else { check(false, "upscale returned an image") }
    let line = greyImage(80, 60) { x, _ in (38...41).contains(x) ? 0 : 255 }
    if let big = ComicUpscaler.upscale(line, by: 3) {
        let px = greys(big), w = big.width, row = 90 * w
        check(px[row + 10] >= 250 && px[row + 230] >= 250, "paper away from a line stays white (no halo)")
        check(px[row + 119] <= 10, "the line stays black")
        let outside = (60..<105).map { Int(px[row + $0]) }
        check(outside.allSatisfy { $0 >= 250 }, "no ghost outline beside the line")
    } else { check(false, "upscale returned an image") }
    check(ComicUpscaler.upscale(flat, by: 1.05) == nil, "a comic that already fits is left alone")
}

await run()
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
