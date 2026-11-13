import Foundation

/// What the Random Comic widget needs to pick a comic that fits its shape: every comic's shape,
/// plus favorites and read comics. The app writes it to the shared container and the widget
/// only reads it.
struct WidgetPool: Codable {
    /// Comic numbers and their width-to-height ratios, in step with each other.
    var nums: [Int]
    var aspects: [Double]
    var favorites: [Int]
    var viewed: [Int]

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedSettings.appGroup)?
            .appending(path: "widget-pool.json")
    }

    static func load() -> WidgetPool? {
        guard let url, let data = try? Data(contentsOf: url),
              let pool = try? JSONDecoder().decode(WidgetPool.self, from: data),
              pool.nums.count == pool.aspects.count, !pool.nums.isEmpty else { return nil }
        return pool
    }

    func save() {
        guard let url = Self.url, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A comic about as wide-for-its-height as `target`. Unread comics come first, with a
    /// favorite about one time in four.
    func pick(aspect target: Double) -> Int? {
        guard target > 0 else { return nil }
        // Start strict and loosen until there is a real choice.
        var fitting: [Int] = []
        for tolerance in [1.12, 1.25, 1.5] {
            fitting = zip(nums, aspects).compactMap { num, aspect in
                aspect > 0 && max(aspect / target, target / aspect) <= tolerance ? num : nil
            }
            if fitting.count >= 12 { break }
        }
        guard !fitting.isEmpty else { return nil }

        let favoriteSet = Set(favorites), viewedSet = Set(viewed)
        let favoritesThatFit = fitting.filter(favoriteSet.contains)
        let unread = fitting.filter { !viewedSet.contains($0) }
        if !favoritesThatFit.isEmpty, unread.isEmpty || Int.random(in: 0..<4) == 0 {
            return favoritesThatFit.randomElement()
        }
        return unread.randomElement() ?? fitting.randomElement()
    }
}
