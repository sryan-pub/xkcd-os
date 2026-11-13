import Foundation

/// One xkcd comic. Decodes both the bundled seed (which already has the aspect ratio and
/// interactive flag) and xkcd.com's own JSON (which has neither).
struct Comic: Codable, Identifiable, Hashable, Sendable {
    let num: Int
    var title: String
    var safeTitle: String
    var alt: String
    var transcript: String
    var img: String
    var day: String
    var month: String
    var year: String
    /// Width divided by height. Drives the tile shape in the mosaic grid.
    var aspectRatio: Double
    /// Comics that only work on the website (games, zoomable maps, and so on).
    var isInteractive: Bool

    var id: Int { num }

    static let knownInteractive: Set<Int> = [1193, 1331, 1446, 1525, 1608, 1663]

    /// Flagged as special by xkcd.com, but the page is just the picture now with nothing to play.
    static let pictureOnly: Set<Int> = [1005, 1335, 1446, 3227]

    /// Whether the comic does something on xkcd.com that the picture alone doesn't.
    var isPlayable: Bool { isInteractive && !Self.pictureOnly.contains(num) }

    enum CodingKeys: String, CodingKey {
        case num, title, alt, transcript, img, day, month, year, isInteractive
        case safeTitle = "safe_title"
        case aspectRatio = "img_aspect_ratio"
        case extraParts = "extra_parts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = try c.decode(Int.self, forKey: .num)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        safeTitle = try c.decodeIfPresent(String.self, forKey: .safeTitle) ?? ""
        alt = try c.decodeIfPresent(String.self, forKey: .alt) ?? ""
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        img = try c.decodeIfPresent(String.self, forKey: .img) ?? ""
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        month = try c.decodeIfPresent(String.self, forKey: .month) ?? ""
        year = try c.decodeIfPresent(String.self, forKey: .year) ?? ""
        aspectRatio = try c.decodeIfPresent(Double.self, forKey: .aspectRatio) ?? 1
        let flagged = try c.decodeIfPresent(Bool.self, forKey: .isInteractive) ?? false
        isInteractive = flagged || c.contains(.extraParts) || Self.knownInteractive.contains(num)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(num, forKey: .num)
        try c.encode(title, forKey: .title)
        try c.encode(safeTitle, forKey: .safeTitle)
        try c.encode(alt, forKey: .alt)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(img, forKey: .img)
        try c.encode(day, forKey: .day)
        try c.encode(month, forKey: .month)
        try c.encode(year, forKey: .year)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(isInteractive, forKey: .isInteractive)
    }

    var imageURL: URL? {
        guard img.hasPrefix("http"), !img.hasSuffix("/") else { return nil }
        return URL(string: img)
    }

    /// xkcd publishes a double-resolution copy of most comics next to the standard one
    /// (`name_2x.png`). Not every comic has it, so callers fall back to `imageURL`.
    var highResImageURL: URL? {
        guard let url = imageURL, !url.pathExtension.isEmpty else { return nil }
        let name = url.deletingPathExtension().lastPathComponent + "_2x." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    var pageURL: URL { URL(string: "https://xkcd.com/\(num)/")! }

    var explainURL: URL { URL(string: "https://www.explainxkcd.com/wiki/index.php/\(num)")! }

    var displayTitle: String { safeTitle.isEmpty ? title : safeTitle }

    var date: Date? {
        guard let d = Int(day), let m = Int(month), let y = Int(year) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))
    }

    var dateText: String {
        date?.formatted(date: .abbreviated, time: .omitted) ?? ""
    }

    /// Tile shape, kept within sane bounds so one very tall or very wide comic can't wreck the grid.
    var tileAspectRatio: Double { min(max(aspectRatio, 0.4), 3.2) }
}
