import SafariServices
import SwiftUI
import WebKit

/// A web page shown inside the app with Safari's own viewer (reader mode, share, Done).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// An interactive comic, played inside the app. It loads the comic's page from xkcd.com and
/// strips away everything but the comic itself, so it behaves like part of the app.
struct InteractiveComicPlayer: View {
    let comic: Comic
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var isLoading = true
    @State private var failed = false
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            ComicWebView(url: comic.pageURL, reloadToken: reloadToken, isLoading: $isLoading, failed: $failed)
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if failed {
                        // Interactive comics run from xkcd.com, so they need a connection.
                        VStack(spacing: 14) {
                            EmptyStateView(title: "Couldn't Load", systemImage: "wifi.slash",
                                           message: "This comic runs from xkcd.com and needs a connection.")
                            Button { reloadToken += 1 } label: { ToolbarIcon(text: "Try Again") }
                                .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(colorScheme == .dark ? Color.black : Color.white)
                    } else if isLoading {
                        ProgressView()
                    }
                }
                .background(colorScheme == .dark ? Color.black : Color.white)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Text(comic.displayTitle)
                            .font(.xkcd(size: 22, relativeTo: .headline))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { ToolbarIcon(systemName: "xmark") }
                            .accessibilityLabel("Close")
                    }
                    .solidBackground()
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Menu {
                            Button("Start Over", systemImage: "arrow.counterclockwise") { reloadToken += 1 }
                            Button("Open in Safari", systemImage: "safari") { openURL(comic.pageURL) }
                        } label: {
                            ToolbarIcon(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More")
                    }
                    .solidBackground()
                }
        }
    }
}

private struct ComicWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    @Binding var isLoading: Bool
    @Binding var failed: Bool

    /// Hides the site around the comic, sizes the page to the comic's column, and in dark mode
    /// flips the page's lightness (the site has no dark version of its own).
    private static let isolateComic = """
    (function () {
        var style = document.createElement('style');
        style.textContent =
            'html, body { background: #fff !important; padding: 0 !important; }' +
            'html { margin: 0 !important; }' +
            'body { position: relative !important; left: 0 !important; width: 780px !important; margin: 0 auto !important; }' +
            '#topContainer, #bottom, #ctitle, .comicNav, #transcript, #middleContainer > br, #middleContainer > a { display: none !important; }' +
            '#middleContainer { font-size: 0 !important; border: none !important; box-shadow: none !important;' +
            '  left: 0 !important; margin: 0 auto !important; padding: 8px 0 !important; width: 780px !important; }' +
            '#comic { font-size: 16px; }' +
            (window.matchMedia('(prefers-color-scheme: dark)').matches
                ? 'html { filter: invert(1) hue-rotate(180deg); }' : '');
        document.documentElement.appendChild(style);
        var viewport = document.createElement('meta');
        viewport.name = 'viewport';
        viewport.content = 'width=796';
        document.head.appendChild(viewport);
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.isolateComic, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // Clear until the page paints, so the screen behind (black or white to match) shows.
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.load(URLRequest(url: url))
        context.coordinator.token = reloadToken
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.token != reloadToken else { return }
        context.coordinator.token = reloadToken
        view.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: ComicWebView
        var token = 0

        init(_ parent: ComicWebView) { self.parent = parent }

        /// The player is for xkcd's own pages, not general browsing. Links the reader taps to other sites
        /// open in Safari. Loads inside the comic (frames, scripts) are allowed so interactive comics that
        /// use other hosts still work.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame ?? true,
                  let url = action.request.url, let host = url.host()?.lowercased(),
                  host != "xkcd.com", !host.hasSuffix(".xkcd.com") else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.failed = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.failed = true
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.failed = true
        }
    }
}
