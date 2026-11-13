import Foundation
import Observation

/// All known comics: the seed bundled with the app, plus anything newer fetched from xkcd.com
/// and kept in a small cache file.
@MainActor
@Observable
final class ComicStore {
    /// Newest first.
    private(set) var comics: [Comic] = []
    private(set) var isLoaded = false
    private(set) var isRefreshing = false
    private(set) var lastRefreshFailed = false

    private var byNum: [Int: Comic] = [:]
    @ObservationIgnored private(set) var seedMax = 0
    @ObservationIgnored private var started = false

    var latestNum: Int { comics.first?.num ?? 0 }

    func comic(_ num: Int) -> Comic? { byNum[num] }

    func start() async {
        guard !started else { return }
        started = true

        let cacheURL = Self.cacheURL
        let loaded = await Task.detached(priority: .userInitiated) { () -> (seed: [Comic], cached: [Comic]) in
            (Self.decodeComics(at: Bundle.main.url(forResource: "comics-seed", withExtension: "json")),
             Self.decodeComics(at: cacheURL))
        }.value

        seedMax = loaded.seed.map(\.num).max() ?? 0
        merge(loaded.seed + loaded.cached)
        isLoaded = true
        NewComicNotifier.markSeen(latestNum)
        await refresh()
    }

    /// Fetches anything newer from xkcd.com. Offline, the seed and cache still work.
    func refresh() async {
        guard isLoaded, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newer = try await XKCDClient.fetchNewer(after: latestNum)
            lastRefreshFailed = false
            guard !newer.isEmpty else { return }
            merge(newer)
            saveCache()
            NewComicNotifier.markSeen(latestNum)    // Seen in the app, so no alert is needed for it.
        } catch {
            lastRefreshFailed = true
        }
    }

    /// The next comic in the given direction that actually exists (skips #404).
    func neighbor(of num: Int, newer: Bool) -> Comic? {
        var candidate = num + (newer ? 1 : -1)
        while candidate >= 1 && candidate <= latestNum {
            if let comic = byNum[candidate] { return comic }
            candidate += newer ? 1 : -1
        }
        return nil
    }

    func random(excluding num: Int? = nil) -> Comic? {
        guard comics.count > 1 else { return comics.first }
        while true {
            if let pick = comics.randomElement(), pick.num != num { return pick }
        }
    }

    private func merge(_ incoming: [Comic]) {
        for comic in incoming { byNum[comic.num] = comic }
        comics = byNum.values.sorted { $0.num > $1.num }
    }

    private func saveCache() {
        let extra = comics.filter { $0.num > seedMax }
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(extra) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static var cacheURL: URL {
        URL.applicationSupportDirectory.appending(path: "fetched-comics.json")
    }

    private nonisolated static func decodeComics(at url: URL?) -> [Comic] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Comic].self, from: data)) ?? []
    }
}
