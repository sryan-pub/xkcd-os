import Foundation
import ImageIO

/// Talks to xkcd.com directly, no server in between.
enum XKCDClient {
    private static let maxConcurrent = 4
    private static let imageHeaderBytes = 65_536

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = maxConcurrent
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "xkcd-reader-ios"]
        return URLSession(configuration: config)
    }()

    enum ClientError: Error { case badStatus(Int) }

    /// Every comic newer than `known`, oldest first. If a fetch fails, only comics below the failure
    /// are returned so the gap is retried next time instead of skipped.
    static func fetchNewer(after known: Int) async throws -> [Comic] {
        let latest = try await fetchComic(nil)
        guard latest.num > known else { return [] }

        let numbers = ((known + 1)...latest.num).filter { $0 != 404 }   // There is no comic 404.
        var fetched: [Int: Comic] = [latest.num: latest]
        var firstFailure = Int.max

        for start in stride(from: 0, to: numbers.count, by: maxConcurrent) {
            let chunk = numbers[start..<min(start + maxConcurrent, numbers.count)]
            await withTaskGroup(of: (Int, Comic?).self) { group in
                for num in chunk where num != latest.num {
                    group.addTask { (num, try? await fetchComic(num)) }
                }
                for await (num, comic) in group {
                    if let comic { fetched[num] = comic } else { firstFailure = min(firstFailure, num) }
                }
            }
            if firstFailure != Int.max { break }
        }

        return fetched.values.filter { $0.num < firstFailure }.sorted { $0.num < $1.num }
    }

    /// One comic with its aspect ratio filled in. `nil` means the latest.
    static func fetchComic(_ num: Int?) async throws -> Comic {
        let path = num.map { "\($0)/" } ?? ""
        let url = URL(string: "https://xkcd.com/\(path)info.0.json")!
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClientError.badStatus(status) }

        var comic = try JSONDecoder().decode(Comic.self, from: data)
        comic.aspectRatio = await aspectRatio(of: comic.imageURL)
        return comic
    }

    /// Reads only the start of the image, enough for ImageIO to report its size.
    private static func aspectRatio(of url: URL?) async -> Double {
        guard let url else { return 1 }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(imageHeaderBytes - 1)", forHTTPHeaderField: "Range")

        guard let (data, _) = try? await session.data(for: request), !data.isEmpty else { return 1 }

        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, data.count < imageHeaderBytes)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return 1 }

        return width / height
    }
}
