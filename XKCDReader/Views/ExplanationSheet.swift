import SwiftUI

/// The comic's explanation from explainxkcd.com in the app's style, shown in the same panel as
/// the alt text, which grows to hold it.
struct ExplanationContent: View {
    /// Source, authors, licence and changes; links underlined (see `AttributedString.linked`).
    private static let credit = AttributedString.linked("The \"Explanation\" section of this comic's page on [explain xkcd](https://www.explainxkcd.com), by its contributors, under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/). Reformatted for the app; tables and pictures left out.")

    let comic: Comic
    /// Returns to the alt text.
    let onBack: () -> Void
    @State private var explanation: Explanation?
    @State private var failed = false
    @State private var showFullPage = false

    init(comic: Comic, onBack: @escaping () -> Void) {
        self.comic = comic
        self.onBack = onBack
        // Already fetched (fetching starts when the alt text opens), so start with the text in place
        // and the panel grows straight into it.
        _explanation = State(initialValue: ExplanationClient.cached(comic.num))
    }

    private static let placeholder = String(repeating: "Explanation text loading. ", count: 9)

    private func load() {
        guard explanation == nil else { return }
        failed = false
        let num = comic.num
        Task {
            do {
                let fetched = try await ExplanationClient.shared.explanation(for: num)
                // Ease late-arriving text in instead of snapping.
                withAnimation(.easeOut(duration: 0.3)) { explanation = fetched }
            } catch {
                withAnimation(.easeOut(duration: 0.3)) { failed = true }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(comic.displayTitle)
                        .font(.xkcd(size: 24, relativeTo: .headline))
                        .lineLimit(2)
                    Text("Explanation")
                        .font(.xkcd(size: 18, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onBack) { ToolbarIcon(text: "Alt") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to alt text")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let explanation {
                        Group {
                        ForEach(explanation.blocks) { block in
                            switch block.kind {
                            case .heading:
                                Text(block.text)
                                    .font(.xkcd(size: 22, relativeTo: .headline))
                                    .padding(.top, 6)
                                    .accessibilityAddTraits(.isHeader)
                            case .bullet:
                                // Body text uses the system font since paragraphs in capitals are tiring to read.
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").accessibilityHidden(true)
                                    Text(block.text)
                                }
                                .font(.body)
                                .lineSpacing(4)
                            case .paragraph:
                                Text(block.text)
                                    .font(.body)
                                    .lineSpacing(4)
                            }
                        }
                        }
                        .transition(.opacity)
                    } else if failed {
                        Text("The explanation didn't load. explainxkcd.com can be slow; try again, or open the full page.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Button { load() } label: { ToolbarIcon(text: "Try Again") }
                            .buttonStyle(.plain)
                    } else {
                        // While loading, the panel shows grey placeholder lines where the paragraphs will be, and the
                        // text fades in over them.
                        Group {
                            ForEach(0..<3, id: \.self) { _ in
                                Text(Self.placeholder)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .redacted(reason: .placeholder)
                                    .opacity(0.45)
                            }
                        }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                        Text("Loading from explainxkcd.com…")
                            .font(.xkcd(size: 15, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                    }

                    // explainxkcd.com is CC BY-SA 3.0, which requires the source, authors, licence and a note of
                    // changes. "Open Full Page" links the source page.
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Self.credit)
                            .tint(.secondary)
                            .font(.xkcd(size: 15, relativeTo: .footnote))
                            .foregroundStyle(.secondary)
                        Button { showFullPage = true } label: { ToolbarIcon(text: "Open Full Page") }
                            .buttonStyle(.plain)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear { load() }
        .fullScreenCover(isPresented: $showFullPage) {
            SafariView(url: comic.explainURL)
                .ignoresSafeArea()
        }
    }
}
