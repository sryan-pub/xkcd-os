import SwiftUI

/// Who made what and under which licences. The comics, font and classic icon are under
/// licences that require this credit.
struct AboutScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var version: String {
        let info = Bundle.main.infoDictionary
        let number = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? number : "\(number) (\(build))"
    }

    /// The app's App Store ID. The review button is hidden while this is empty.
    private static let appStoreID = "6833707708"
    private static var reviewURL: URL? {
        appStoreID.isEmpty ? nil : URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("xkcd: Open Source")
                            .font(.xkcd(size: 30, relativeTo: .title))
                        Text("Version \(version)")
                            .font(.xkcd(size: 17, relativeTo: .subheadline))
                            .foregroundStyle(.secondary)
                        Text(.linked("""
                            Hi!  My name is Shane.  I really like xkcd.

                            My favorite reader became abandonware so I revived it with a modern touch.  Enjoy!
                            """))
                            .font(.body)
                            .padding(.top, 6)
                    }

                    credit("Comics", """
                        Authored by Randall Munroe on [xkcd.com](https://xkcd.com), shared under \
                        [Creative Commons Attribution-NonCommercial 2.5](https://xkcd.com/license.html).
                        """)
                    credit("Lettering", """
                        Fonts are from the [xkcd-font project](https://github.com/ipython/xkcd-font), \
                        shared under [Creative Commons Attribution-NonCommercial 3.0](https://creativecommons.org/licenses/by-nc/3.0/).
                        """)
                    credit("Explanations", """
                        Written by the contributors to [explain xkcd](https://www.explainxkcd.com), under \
                        [Creative Commons Attribution-ShareAlike 3.0](https://creativecommons.org/licenses/by-sa/3.0/).
                        """)
                    credit("Original App", """
                        This is a modern revival of Mike Amaral\u{2019}s [\u{201C}xkcd: Open Source\u{201D}](https://github.com/mamaral/xkcd-Open-Source), which was \
                        my favorite xkcd reader for years until it was abandoned and pulled from the App Store.
                        """)
                    credit("Sharper comics",
                           "Small comics are enlarged by a tiny neural network running on your device, trained only on xkcd images.")
                    credit("Privacy", """
                        No accounts!  No analytics!  No server!
                        Favorites and read comics stay on your device and sync through iCloud if you use it.
                        """)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Thank you")
                            .font(.xkcd(size: 21, relativeTo: .headline))
                            .accessibilityAddTraits(.isHeader)
                        Text("Hopefully this enhances your xkcd experience! Feedback and reviews welcome.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        if let url = Self.reviewURL {
                            Button { openURL(url) } label: { ToolbarIcon(text: "Review on the App Store") }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("About")
                        .font(.xkcd(size: 22, relativeTo: .headline))
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { ToolbarIcon(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
                .solidBackground()
            }
        }
    }

    private func credit(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.xkcd(size: 21, relativeTo: .headline))
                .accessibilityAddTraits(.isHeader)
            Text(.linked(text))
                .font(.body)
                .foregroundStyle(.secondary)
                .tint(.primary)
        }
    }
}

extension AttributedString {
    /// Markdown with line breaks kept and links underlined so they stand out in grey body text.
    static func linked(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
        for run in text.runs where run.link != nil { text[run.range].underlineStyle = .single }
        return text
    }
}
