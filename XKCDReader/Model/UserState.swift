import Foundation
import Observation

/// Favorites and read comics. Stored in a small JSON file and mirrored through iCloud's key-value
/// store so an iPhone and iPad stay in sync.
///
/// Each comic's favorite and read flags carry the time they last changed. When two devices
/// disagree the newer change wins, so un-favoriting and marking unread sync too.
@MainActor
@Observable
final class UserState {
    private(set) var favorites: Set<Int> = []
    private(set) var viewed: Set<Int> = []

    struct Mark: Codable, Equatable {
        var on: Bool
        /// Seconds since 1970 of the last change. 0 for marks imported without a time.
        var t: Int
    }

    private struct Snapshot: Codable {
        var favoriteMarks: [Int: Mark] = [:]
        var viewedMarks: [Int: Mark] = [:]
        /// Imported from the original app's data. Not shown anymore, kept so nothing recovered is lost.
        var bookmark: Int?

        enum CodingKeys: String, CodingKey {
            case favoriteMarks, viewedMarks, bookmark
            case favorites, viewed          // the first file format: plain lists of comic numbers
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            favoriteMarks = try c.decodeIfPresent([Int: Mark].self, forKey: .favoriteMarks) ?? [:]
            viewedMarks = try c.decodeIfPresent([Int: Mark].self, forKey: .viewedMarks) ?? [:]
            bookmark = try c.decodeIfPresent(Int.self, forKey: .bookmark)
            for num in try c.decodeIfPresent([Int].self, forKey: .favorites) ?? [] where favoriteMarks[num] == nil {
                favoriteMarks[num] = Mark(on: true, t: 0)
            }
            for num in try c.decodeIfPresent([Int].self, forKey: .viewed) ?? [] where viewedMarks[num] == nil {
                viewedMarks[num] = Mark(on: true, t: 0)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(favoriteMarks, forKey: .favoriteMarks)
            try c.encode(viewedMarks, forKey: .viewedMarks)
            try c.encodeIfPresent(bookmark, forKey: .bookmark)
        }
    }

    @ObservationIgnored private var snapshot = Snapshot()
    @ObservationIgnored private let cloud = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private var cloudObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingPush: Task<Void, Never>?

    private static let cloudKey = "reading-state"

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = saved
        }
        rebuildSets()

        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mergeFromCloud() }
        }
        cloud.synchronize()
        mergeFromCloud()
    }

    func isFavorite(_ num: Int) -> Bool { favorites.contains(num) }
    func isViewed(_ num: Int) -> Bool { viewed.contains(num) }

    func toggleFavorite(_ num: Int) {
        let nowOn = !favorites.contains(num)
        snapshot.favoriteMarks[num] = Mark(on: nowOn, t: Self.now)
        if nowOn { favorites.insert(num) } else { favorites.remove(num) }
        changed()
    }

    func markViewed(_ num: Int) {
        guard !viewed.contains(num) else { return }
        setViewed(num, true)
    }

    func setViewed(_ num: Int, _ isViewed: Bool) {
        snapshot.viewedMarks[num] = Mark(on: isViewed, t: Self.now)
        if isViewed { viewed.insert(num) } else { viewed.remove(num) }
        changed()
    }

    // MARK: - Storage

    private static var now: Int { Int(Date().timeIntervalSince1970) }

    private func rebuildSets() {
        favorites = Set(snapshot.favoriteMarks.filter { $0.value.on }.keys)
        viewed = Set(snapshot.viewedMarks.filter { $0.value.on }.keys)
    }

    private func changed() {
        saveLocal()
        // Reading through comics changes state many times a minute, so batch the update.
        pendingPush?.cancel()
        pendingPush = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pushToCloud()
        }
    }

    private func saveLocal() {
        let snapshot = snapshot
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func pushToCloud() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        cloud.set(data, forKey: Self.cloudKey)
    }

    /// Merges what another device saved. Newer changes win on both sides.
    private func mergeFromCloud() {
        guard let data = cloud.data(forKey: Self.cloudKey),
              let remote = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            // Nothing in iCloud yet, so upload what this device has.
            if !snapshot.favoriteMarks.isEmpty || !snapshot.viewedMarks.isEmpty { pushToCloud() }
            return
        }

        let favoritesChanged = Self.merge(&snapshot.favoriteMarks, with: remote.favoriteMarks)
        let viewedChanged = Self.merge(&snapshot.viewedMarks, with: remote.viewedMarks)
        if snapshot.bookmark == nil { snapshot.bookmark = remote.bookmark }

        if favoritesChanged || viewedChanged {
            rebuildSets()
            saveLocal()
        }
        // If this device has changes iCloud doesn't, send the merged result back.
        if snapshot.favoriteMarks != remote.favoriteMarks || snapshot.viewedMarks != remote.viewedMarks {
            pushToCloud()
        }
    }

    /// Merges another device's marks into this one's. Returns true if anything changed. Internal so
    /// `scripts/checks` can test it.
    static func merge(_ local: inout [Int: Mark], with remote: [Int: Mark]) -> Bool {
        var changed = false
        for (num, theirs) in remote {
            if let ours = local[num] {
                // Same timestamp on both sides (two imports, say): prefer "on" so nothing is lost.
                guard theirs.t > ours.t || (theirs.t == ours.t && theirs.on && !ours.on) else { continue }
            }
            local[num] = theirs
            changed = true
        }
        return changed
    }

    private nonisolated static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "user-state.json")
    }
}
