import SwiftUI
import ImageIO
import UIKit

/// A decoded comic and whether it's the dark mode version (which sits on the dark page).
struct ComicImage {
    let image: UIImage
    let isInverted: Bool
}

/// Downloads comic images, caches them on disk through URLCache, and returns copies downsampled
/// to their display size so a long grid stays light on memory.
actor ImageLoader {
    static let shared = ImageLoader()

    /// Page colour behind inverted comics. Dark grey, easier on the eyes than black.
    static let nightPaper = UIColor(white: NightComic.paper, alpha: 1)

    /// Setting key for redrawing comics in dark mode. On by default.
    static let invertSettingKey = "invertComicsInDarkMode"

    private let session: URLSession
    private let urlCache: URLCache
    private let memory = NSCache<NSString, UIImage>()
    private var keptAsDrawn: Set<String> = []     // photographs, which are never redrawn
    /// Recent dark mode decisions, so the full-size comic reuses its card's.
    private var recentDecisions: [(key: String, decision: NightComic.Decision)] = []
    private var prefetched: Set<String> = []

    private init() {
        urlCache = URLCache(memoryCapacity: 20 << 20, diskCapacity: 600 << 20)
        let config = URLSessionConfiguration.default
        config.urlCache = urlCache
        config.requestCachePolicy = .returnCacheDataElseLoad   // Comics don't change once published.
        config.httpAdditionalHeaders = ["User-Agent": "xkcd-reader-ios"]
        session = URLSession(configuration: config)
        memory.totalCostLimit = 200 << 20
    }

    /// `maxPixel` is the longest side wanted, in pixels. Pass nil for the full image.
    func image(for url: URL, maxPixel: Int?) async -> UIImage? {
        let key = "\(maxPixel ?? 0)|\(url.absoluteString)" as NSString
        if let hit = memory.object(forKey: key) { return hit }

        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = Self.decode(data, maxPixel: maxPixel) else { return nil }

        memory.setObject(image, forKey: key, cost: Self.cost(of: image))
        return image
    }

    /// Like `image(for:maxPixel:)`, but with `invert` the comic is redrawn for dark mode (see
    /// `NightComic`). Photographs stay as drawn, on white.
    func comicImage(for url: URL, maxPixel: Int?, invert: Bool, comic: Int? = nil) async -> ComicImage? {
        guard let original = await image(for: url, maxPixel: maxPixel) else { return nil }
        guard invert else { return ComicImage(image: original, isInverted: false) }

        let key = "night|\(maxPixel ?? 0)|\(url.absoluteString)"
        if let hit = memory.object(forKey: key as NSString) { return ComicImage(image: hit, isInverted: true) }
        if keptAsDrawn.contains(key) { return ComicImage(image: original, isInverted: false) }

        guard let cgImage = original.cgImage else { return ComicImage(image: original, isInverted: false) }
        // What to flip is decided from the published comic, not this smaller copy, so the card and the
        // full-screen comic always match. The decision is cached on disk so this slow step runs once per
        // comic.
        let decision = await nightDecision(for: url, comic: comic)
        // Redraw off the actor so tiles render in parallel.
        let result = await Task.detached(priority: .userInitiated) {
            NightComic.render(cgImage, comic: comic, decision: decision)
        }.value
        guard let result, result.treatment != .photo else {
            keptAsDrawn.insert(key)
            return ComicImage(image: original, isInverted: false)
        }
        let night = UIImage(cgImage: result.image, scale: original.scale, orientation: .up)
        memory.setObject(night, forKey: key as NSString, cost: Self.cost(of: night))
        // Only the dark version will be shown, so don't keep the original in memory too.
        memory.removeObject(forKey: "\(maxPixel ?? 0)|\(url.absoluteString)" as NSString)
        return ComicImage(image: night, isInverted: true)
    }

    /// The comic for the full-screen view, enlarged to `targetPixels` if smaller (see
    /// `ComicUpscaler`) and redrawn for dark mode if `invert` is set. `standardURL` is the published
    /// 1x image. The dark mode decision is made from it even when `url` is the sharper 2x copy, to
    /// match the grid's cards.
    func displayImage(for url: URL, standardURL: URL? = nil, invert: Bool, targetPixels: CGSize, comic: Int? = nil) async -> ComicImage? {
        let key = "display|\(ComicUpscaler.tuningKey)|\(invert)|\(Int(targetPixels.width))x\(Int(targetPixels.height))|\(url.absoluteString)"
        if let hit = memory.object(forKey: key as NSString) {
            return ComicImage(image: hit, isInverted: invert && !keptAsDrawn.contains(key))
        }
        guard let original = await image(for: url, maxPixel: nil), let cgImage = original.cgImage else { return nil }
        let factor = min(targetPixels.width / CGFloat(cgImage.width), targetPixels.height / CGFloat(cgImage.height))
        let decision = invert ? await nightDecision(for: standardURL ?? url, comic: comic) : nil

        let result = await Task.detached(priority: .userInitiated) { () -> (image: CGImage, isNight: Bool) in
            let enlarged = ComicUpscaler.upscale(cgImage, by: Double(factor)) ?? cgImage
            guard invert, let night = NightComic.render(enlarged, decidingFrom: cgImage, comic: comic, decision: decision),
                  night.treatment != .photo else { return (enlarged, false) }
            return (night.image, true)
        }.value

        // Decode for the screen now, off the main thread, so showing it doesn't stall a swipe.
        let made = UIImage(cgImage: result.image, scale: original.scale, orientation: .up)
        let image = await made.byPreparingForDisplay() ?? made
        if invert && !result.isNight { keptAsDrawn.insert(key) }
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        memory.removeObject(forKey: "0|\(url.absoluteString)" as NSString)
        return ComicImage(image: image, isInverted: result.isNight)
    }

    // MARK: Dark-mode decisions

    /// All saved decisions live in one small append-only file of name/data records. Thousands of
    /// separate tiny files would each take a 4 KB block. The whole archive is under 1 MB.
    private static let decisionFile: URL? = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("night-decisions-v\(NightComic.Decision.rulesVersion).bin")
    }()
    private var savedDecisions: [String: Data]?

    private func loadSavedDecisions() -> [String: Data] {
        if let savedDecisions { return savedDecisions }
        var found: [String: Data] = [:]
        if let file = Self.decisionFile, let data = try? Data(contentsOf: file) {
            var at = data.startIndex
            func length() -> Int? {
                guard at + 4 <= data.endIndex else { return nil }
                defer { at += 4 }
                return data[at..<at + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            }
            // A record cut short (app killed mid-write) ends the list.
            while let nameLength = length(), nameLength < 512, at + nameLength <= data.endIndex {
                let name = String(decoding: data[at..<at + nameLength], as: UTF8.self)
                at += nameLength
                guard let size = length(), size < 4_000_000, at + size <= data.endIndex else { break }
                found[name] = Data(data[at..<at + size])
                at += size
            }
        }
        savedDecisions = found
        return found
    }

    private func save(_ decision: Data, named name: String) {
        savedDecisions?[name] = decision
        guard let file = Self.decisionFile else { return }
        var record = Data()
        func put(_ value: Int) { for shift in stride(from: 0, to: 32, by: 8) { record.append(UInt8((value >> shift) & 0xFF)) } }
        let nameBytes = Data(name.utf8)
        put(nameBytes.count); record.append(nameBytes); put(decision.count); record.append(decision)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: record)
        } else {
            try? record.write(to: file)
        }
    }

    /// What to flip for the comic at `standardURL` (its 1x image), from memory, then disk, then
    /// computed and saved. Nil for comics with a hand-set treatment.
    private func nightDecision(for standardURL: URL, comic: Int?) async -> NightComic.Decision? {
        guard !NightComic.hasOverride(comic) else { return nil }
        let key = standardURL.lastPathComponent
        if let hit = recentDecisions.first(where: { $0.key == key }) { return hit.decision }

        var decision = loadSavedDecisions()[key].flatMap { NightComic.Decision(data: $0) }
        if decision == nil, let reference = await image(for: standardURL, maxPixel: nil)?.cgImage {
            decision = await Task.detached(priority: .userInitiated) { NightComic.decide(from: reference) }.value
            if let decision { save(decision.encoded(), named: key) }
            // The full-size copy was only needed for this. Cards keep their own smaller one.
            memory.removeObject(forKey: "0|\(standardURL.absoluteString)" as NSString)
        }
        if let decision {
            recentDecisions.append((key, decision))
            if recentDecisions.count > 8 { recentDecisions.removeFirst() }
        }
        return decision
    }

    /// The picture already made for this comic's grid card, if still in memory.
    func cardImage(for url: URL, invert: Bool) -> ComicImage? {
        let plain = "\(Self.cardPixels)|\(url.absoluteString)"
        if invert {
            if let hit = memory.object(forKey: "night|\(plain)" as NSString) { return ComicImage(image: hit, isInverted: true) }
            guard keptAsDrawn.contains("night|\(plain)") else { return nil }
        }
        return memory.object(forKey: plain as NSString).map { ComicImage(image: $0, isInverted: false) }
    }

    /// Size cards are decoded at.
    static let cardPixels = 700

    /// Loads comics about to scroll into view so they're ready.
    func prefetch(_ comics: [(num: Int, url: URL)], maxPixel: Int?, invert: Bool) async {
        for (num, url) in comics {
            let key = "\(invert)|\(maxPixel ?? 0)|\(url.absoluteString)"
            if Task.isCancelled { return }
            guard prefetched.insert(key).inserted else { continue }
            let made = await comicImage(for: url, maxPixel: maxPixel, invert: invert, comic: num)
            // A load that was cut short can be requested again.
            if made == nil { prefetched.remove(key) }
        }
    }

    func clear() {
        urlCache.removeAllCachedResponses()
        memory.removeAllObjects()
        recentDecisions.removeAll()
        savedDecisions = [:]
        if let file = Self.decisionFile { try? FileManager.default.removeItem(at: file) }
        keptAsDrawn.removeAll()
        prefetched.removeAll()
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    /// Maximum pixel count a comic is ever held at.
    private static let fullSizePixelLimit = 24_000_000.0

    private static func decode(_ data: Data, maxPixel: Int?) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        var maxPixel = maxPixel
        if maxPixel == nil {
            // A few comics are huge (one 2x strip is 44 million pixels, 177 MB decoded). Scale those down
            // to what the rest of the app works with.
            let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let wide = info?[kCGImagePropertyPixelWidth] as? Double ?? 0
            let high = info?[kCGImagePropertyPixelHeight] as? Double ?? 0
            guard wide * high > fullSizePixelLimit else { return UIImage(data: data) }
            maxPixel = Int(max(wide, high) * (fullSizePixelLimit / (wide * high)).squareRoot())
        }
        guard let maxPixel else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }

}

/// A comic image that loads itself, with a placeholder until it arrives.
struct RemoteImage: View {
    let url: URL?
    var maxPixel: Int?
    var invert = false
    /// Comic number, for the few with a hand-set dark mode treatment.
    var comicNumber: Int?
    /// Reports whether the image that arrived is inverted, so the card can match.
    var onLoad: (Bool) -> Void = { _ in }

    @State private var image: UIImage?
    @State private var failed = false
    /// Which version is on screen, as drawn or the dark mode redraw.
    @State private var shownInvert: Bool?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if failed || url == nil {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.gray)
            } else {
                ProgressView()
                    .tint(.gray)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(url?.absoluteString ?? "")|\(invert)") {
            guard let url else { return }
            // When the dark mode setting changes, the picture on screen is the wrong version. Remove it
            // immediately, otherwise a white comic stays on a dark card until the replacement is ready.
            if let shownInvert, shownInvert != invert { image = nil }
            let loaded = await ImageLoader.shared.comicImage(for: url, maxPixel: maxPixel, invert: invert, comic: comicNumber)
            guard !Task.isCancelled else { return }
            shownInvert = invert
            image = loaded?.image
            failed = loaded == nil
            onLoad(loaded?.isInverted ?? false)
        }
    }
}
