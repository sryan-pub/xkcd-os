import SwiftUI

/// One card in the mosaic grid: the comic on its page, its number in a badge, a heart if it is
/// a favorite, and dimmed once it has been read.
struct ComicTile: View, Equatable {
    let comic: Comic
    let isViewed: Bool
    let isFavorite: Bool
    /// Ask for the inverted "night" version (colour comics ignore this).
    var invert = false

    /// A card only needs rebuilding when one of these four values changes. Declaring that lets
    /// SwiftUI skip it when neighbouring cards change (a comic read, a favorite toggled), which
    /// otherwise rebuilt every visible card.
    static func == (a: ComicTile, b: ComicTile) -> Bool {
        a.comic.num == b.comic.num && a.isViewed == b.isViewed && a.isFavorite == b.isFavorite && a.invert == b.invert
    }

    /// Whether the loaded image is the dark-mode version. Unknown until it arrives.
    @State private var isInverted: Bool?

    /// While loading, assume the dark page if that is what was asked for, so tiles don't flash white.
    private var onDarkPage: Bool { isInverted ?? invert }

    var body: some View {
        RemoteImage(url: comic.imageURL, maxPixel: 700, invert: invert, comicNumber: comic.num) { isInverted = $0 }
            .aspectRatio(comic.tileAspectRatio, contentMode: .fit)
            // A setting change means the page colour is unknown until the new picture arrives.
            .onChange(of: invert) { isInverted = nil }
            .opacity(isViewed ? 0.4 : 1)
            .padding(8)
            .background(onDarkPage ? Color(ImageLoader.nightPaper) : .white)
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(onDarkPage ? Color.white.opacity(0.3) : Color.black.opacity(0.85), lineWidth: 1.5)
            }
            .overlay(alignment: .bottomTrailing) {
                Text(String(comic.num))
                    .font(.xkcd(size: 16, relativeTo: .caption))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isViewed ? Color.gray : Color.xkcdSlate, in: .capsule)
                    .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                        .padding(8)
                }
            }
            .contentShape(.rect(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Comic \(comic.num), \(comic.displayTitle)")
            .accessibilityValue([isFavorite ? "Favorite" : nil, isViewed ? "Read" : "Unread"].compactMap { $0 }.joined(separator: ", "))
    }
}
