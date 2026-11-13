import Foundation

/// The "Explanation" section of a comic's explainxkcd.com page as plain text blocks for the app to
/// lay out. Fetched from the wiki's API on request, nothing is bundled.
struct Explanation {
    enum Kind { case paragraph, heading, bullet }
    struct Block: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }
    let blocks: [Block]
}

actor ExplanationClient {
    static let shared = ExplanationClient()
    /// Finished explanations, readable synchronously so a view can start with cached text in place.
    private static let cache = Cache()
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Int: Explanation] = [:]
        subscript(num: Int) -> Explanation? {
            get { lock.lock(); defer { lock.unlock() }; return items[num] }
            set { lock.lock(); defer { lock.unlock() }; items[num] = newValue }
        }
    }
    private var inFlight: [Int: Task<Explanation, Error>] = [:]

    /// The explanation, if already fetched.
    nonisolated static func cached(_ num: Int) -> Explanation? { cache[num] }
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["User-Agent": "xkcd-reader-ios"]
        return URLSession(configuration: config)
    }()

    private struct Sections: Decodable {
        struct Parse: Decodable {
            struct Section: Decodable { let index: String; let line: String }
            let sections: [Section]
        }
        let parse: Parse
    }

    private struct Page: Decodable {
        struct Parse: Decodable {
            struct Text: Decodable {
                let html: String
                enum CodingKeys: String, CodingKey { case html = "*" }
            }
            let text: Text
        }
        let parse: Parse
    }

    func explanation(for num: Int) async throws -> Explanation {
        if let hit = Self.cache[num] { return hit }
        // One request per comic no matter how many callers are waiting.
        if let running = inFlight[num] { return try await running.value }
        let task = Task { try await self.fetchExplanation(for: num) }
        inFlight[num] = task
        defer { inFlight[num] = nil }
        return try await task.value
    }

    private func fetchExplanation(for num: Int) async throws -> Explanation {
        // The wiki files each comic under its number, which redirects to "<number>: <title>".
        let base = "https://www.explainxkcd.com/wiki/api.php?action=parse&page=\(num)&redirects=1&format=json"
        let text = "&prop=text&disableeditsection=1&disabletoc=1&section="
        // The explanation is nearly always section 1, so ask for that directly. The wiki can be slow
        // and one request is half the wait of two.
        var page = try await fetch(Page.self, base + text + "1")
        if !page.parse.text.html.contains("id=\"Explanation\"") {
            let sections = try await fetch(Sections.self, base + "&prop=sections")
            guard let index = sections.parse.sections.first(where: { $0.line == "Explanation" })?.index else {
                throw URLError(.resourceUnavailable)
            }
            page = try await fetch(Page.self, base + text + index)
        }
        let result = Explanation(blocks: Self.blocks(fromHTML: page.parse.text.html))
        guard !result.blocks.isEmpty else { throw URLError(.cannotParseResponse) }
        Self.cache[num] = result
        return result
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ address: String) async throws -> T {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: HTML to text

    /// Converts the wiki's rendered HTML into paragraphs, sub-headings and bullets. Notice boxes,
    /// tables, pictures and footnote markers are dropped.
    static func blocks(fromHTML html: String) -> [Explanation.Block] {
        var text = html
        for pattern in ["<table[\\s\\S]*?</table>", "<style[\\s\\S]*?</style>", "<script[\\s\\S]*?</script>",
                        "<h2[\\s\\S]*?</h2>", "<sup[\\s\\S]*?</sup>", "<figure[\\s\\S]*?</figure>", "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // Mark where blocks start, then drop every remaining tag.
        text = text.replacingOccurrences(of: "<h[3-6][^>]*>", with: "\u{1}H", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<(li|dd)[^>]*>", with: "\u{1}B", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<(p|dt)[^>]*>", with: "\u{1}P", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(h[3-6]|li|dd|p|dt|ul|ol|dl)>", with: "\u{1}P", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)

        var blocks: [Explanation.Block] = []
        for piece in text.components(separatedBy: "\u{1}") {
            guard let marker = piece.first else { continue }
            let body = piece.dropFirst()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            let kind: Explanation.Kind = marker == "H" ? .heading : (marker == "B" ? .bullet : .paragraph)
            blocks.append(.init(id: blocks.count, kind: kind, text: body))
        }
        return blocks
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, character) in ["&nbsp;": " ", "&#160;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'"] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        // Numbered entities such as &#8212; and &#x2014;.
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let isHex = match.range(at: 1).length > 0
                if let code = UInt32(ns.substring(with: match.range(at: 2)), radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
