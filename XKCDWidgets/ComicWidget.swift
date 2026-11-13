import ImageIO
import SwiftUI
import UIKit
import WidgetKit

/// What a widget shows at one moment.
struct ComicEntry: TimelineEntry {
    let date: Date
    var num: Int?
    var title: String
    var image: UIImage?
    /// The comic redrawn for dark mode, when the reader has that switched on (and it isn't a photo).
    var nightImage: UIImage?
    var message: String?

    static let placeholder = ComicEntry(date: .now, num: nil, title: "xkcd", image: nil, message: nil)
}

/// Loads a comic straight from xkcd.com. The widget does not depend on the app having run.
struct ComicProvider: TimelineProvider {
    enum Mode { case latest, random }
    let mode: Mode

    func placeholder(in context: Context) -> ComicEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ComicEntry) -> Void) {
        // Also used for the widget gallery, so the picker shows a real comic, not an empty card.
        Task { completion(await load(in: context)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComicEntry>) -> Void) {
        Task {
            let entry = await load(in: context)
            // Retry sooner after a failure; otherwise the latest is checked every 2 hours and the
            // random comic changes every 6.
            let hours = entry.image == nil ? 1 : (mode == .latest ? 2 : 6)
            let next = Calendar.current.date(byAdding: .hour, value: hours, to: .now) ?? .now.addingTimeInterval(7200)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    /// The shape of the space the comic gets: the widget, less its margins and the title line.
    private func comicAspect(in context: Context) -> Double {
        let size = context.displaySize
        let width = size.width - 32, height = size.height - 32 - 22
        return width > 0 && height > 0 ? width / height : 0
    }

    private func load(in context: Context) async -> ComicEntry {
        let family = context.family
        do {
            var comic: WidgetComic
            if mode == .random, SharedSettings.randomFillsWidget,
               let pick = WidgetPool.load()?.pick(aspect: comicAspect(in: context)),
               let fitted = try? await WidgetFetcher.comic(pick) {
                comic = fitted
            } else {
                let latest = try await WidgetFetcher.comic(nil)
                comic = latest
                if mode == .random, latest.num > 1 {
                    var pick = Int.random(in: 1...latest.num)
                    if pick == 404 { pick = 405 }           // There is no comic 404.
                    comic = (try? await WidgetFetcher.comic(pick)) ?? latest
                }
            }
            let maxPixel = family == .systemSmall ? 500 : 1100
            let image = await WidgetFetcher.image(comic.img, maxPixel: maxPixel)
            var night: UIImage?
            if SharedSettings.invertInDarkMode, let cgImage = image?.cgImage,
               // A widget has little memory, so the dark-mode decision is made on a smaller copy.
               let result = NightComic.render(cgImage, comic: comic.num, analysisPixels: 500_000),
               result.treatment != .photo {
                night = UIImage(cgImage: result.image)
            }
            return ComicEntry(date: .now, num: comic.num, title: comic.displayTitle, image: image, nightImage: night,
                              message: image == nil ? "Open the app to see this one." : nil)
        } catch {
            return ComicEntry(date: .now, num: nil, title: "xkcd", image: nil,
                              message: "Can't reach xkcd.com right now.")
        }
    }
}

private struct WidgetComic: Decodable {
    let num: Int
    let title: String
    let safeTitle: String?
    let img: String

    enum CodingKeys: String, CodingKey {
        case num, title, img
        case safeTitle = "safe_title"
    }

    var displayTitle: String { (safeTitle?.isEmpty == false ? safeTitle : nil) ?? title }
}

private enum WidgetFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "xkcd-reader-ios-widget"]
        return URLSession(configuration: config)
    }()

    static func comic(_ num: Int?) async throws -> WidgetComic {
        let path = num.map { "\($0)/" } ?? ""
        let (data, response) = try await session.data(from: URL(string: "https://xkcd.com/\(path)info.0.json")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(WidgetComic.self, from: data)
    }

    /// Widgets have a small memory budget, so the image is decoded straight to display size.
    static func image(_ urlString: String, maxPixel: Int) async -> UIImage? {
        guard urlString.hasPrefix("http"), !urlString.hasSuffix("/"), let url = URL(string: urlString) else { return nil }
        // Most comics also have a double-resolution copy (name_2x.png); use it when it exists.
        if !url.pathExtension.isEmpty {
            let name = url.deletingPathExtension().lastPathComponent + "_2x." + url.pathExtension
            let highRes = url.deletingLastPathComponent().appendingPathComponent(name)
            if let image = await decode(highRes, maxPixel: maxPixel) { return image }
        }
        return await decode(url, maxPixel: maxPixel)
    }

    private static func decode(_ url: URL, maxPixel: Int) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct ComicWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: ComicEntry

    /// In dark mode the widget shows the redrawn comic on the app's dark page, if there is one.
    private var isNight: Bool { colorScheme == .dark && entry.nightImage != nil }

    var body: some View {
        VStack(spacing: 4) {
            if let image = isNight ? entry.nightImage : entry.image {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                    if let message = entry.message {
                        Text(message)
                            .font(.custom("xkcd-Regular", size: 13, relativeTo: .caption2))
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 4) {
                Text(entry.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let num = entry.num, family != .systemSmall {
                    Text("#\(String(num))")
                }
            }
            .font(.custom("xkcd-Regular", size: 14, relativeTo: .caption2))
            .foregroundStyle(isNight ? Color.white.opacity(0.75) : Color.black.opacity(0.7))
        }
        // Comics are drawn for a white page; the dark-mode redraw sits on the app's dark page.
        .containerBackground(isNight ? Color(white: NightComic.paper) : Color.white, for: .widget)
        .widgetURL(entry.num.flatMap { URL(string: "xkcdreader://comic/\($0)") })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.num.map { "xkcd comic \($0), \(entry.title)" } ?? "xkcd")
    }
}
