import CoreGraphics
import Foundation

/// Fixed workload for comparing enlarging methods (Debug Mode only): the same twelve comics, each
/// enlarged 3x, five times, with one method. Since the work is identical each run, duration and
/// energy use can be compared between methods.
enum EnlargeBenchmark {
    /// Recent black-and-white comics of assorted shapes.
    static let comics = [3322, 3321, 3320, 3319, 3318, 3317, 3316, 3315, 3314, 3313, 3311, 3309]
    static let rounds = 5
    static let factor = 3.0
    /// Time to start a recording after tapping, before the work begins.
    static let leadIn: Duration = .seconds(8)

    /// Runs the benchmark with `method` and returns a one-line result.
    static func run(_ method: ComicUpscaler.Method, store: ComicStore) async -> String {
        var images: [CGImage] = []
        for num in comics {
            guard let comic = await store.comic(num) else { continue }
            var image: CGImage?
            if let url = comic.highResImageURL { image = await ImageLoader.shared.image(for: url, maxPixel: nil)?.cgImage }
            if image == nil, let url = comic.imageURL { image = await ImageLoader.shared.image(for: url, maxPixel: nil)?.cgImage }
            if let image { images.append(image) }
        }
        guard !images.isEmpty else { return "Couldn't load the benchmark comics." }

        try? await Task.sleep(for: leadIn)
        let (count, seconds) = await Task.detached(priority: .userInitiated) { () -> (Int, Double) in
            let started = Date()
            var done = 0
            for _ in 0..<rounds {
                for image in images where ComicUpscaler.enlargeForBenchmark(image, by: factor, method: method) != nil {
                    done += 1
                }
            }
            return (done, Date().timeIntervalSince(started))
        }.value
        return "\(method.label): \(count) enlargements in \(String(format: "%.2f", seconds)) s (\(Int(seconds / Double(max(count, 1)) * 1000)) ms each)"
    }
}
