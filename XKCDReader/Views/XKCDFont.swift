import SwiftUI
import CoreText

/// The hand-drawn xkcd font (ipython/xkcd-font, CC BY-NC 3.0), bundled as `xkcd.otf`.
enum XKCDFont {
    /// PostScript name of the bundled font, registered on first use. `nil` if it can't be loaded.
    static let name: String? = {
        guard let url = Bundle.main.url(forResource: "xkcd", withExtension: "otf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String
    }()
}

extension Font {
    /// The hand-drawn font at `size`, scaling with Dynamic Type like `style` does.
    /// Falls back to the rounded system font if the font file is missing.
    static func xkcd(size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        guard let name = XKCDFont.name else { return .system(style, design: .rounded) }
        return .custom(name, size: size, relativeTo: style)
    }
}

/// "Nothing here" screens, lettered in the hand-drawn font like the rest of the app.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).font(.xkcd(size: 28, relativeTo: .title2))
            } icon: {
                Image(systemName: systemImage)
            }
        } description: {
            Text(message).font(.xkcd(size: 19, relativeTo: .body))
        }
    }
}

extension Color {
    /// The app's slate blue: grid background, number badges and controls. Set in code so it
    /// never falls back to the system blue.
    static let xkcdSlate = Color(red: 0.431, green: 0.482, blue: 0.569)
}

/// Toolbar button with a solid fill, like the original app's: white in light mode and the dark
/// page colour in dark mode. Otherwise iOS 26 draws toolbar buttons as glass that picks up
/// whatever is behind them.
struct ToolbarIcon: View {
    var systemName: String?
    var text: String?
    var tint: Color = .primary

    init(systemName: String, tint: Color = .primary) {
        self.systemName = systemName
        self.tint = tint
    }

    init(text: String) {
        self.text = text
    }

    static let fill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? ImageLoader.nightPaper : .white
    })

    var body: some View {
        Group {
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40)
            } else {
                Text(text ?? "")
                    .font(.xkcd(size: 19, relativeTo: .body))
                    .padding(.horizontal, 14)
                    .frame(height: 40)
            }
        }
        .foregroundStyle(tint)
        .background(Self.fill, in: .capsule)
        // Thin outline so a dark button still reads as a button over a dark comic.
        .overlay { Capsule().strokeBorder(.primary.opacity(0.22), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

extension ToolbarContent {
    /// Removes iOS 26's shared glass backing so `ToolbarIcon`'s own fill is what shows.
    @ToolbarContentBuilder
    func solidBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
