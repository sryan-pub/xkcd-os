import SwiftUI
import WidgetKit

@main
struct XKCDWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LatestComicWidget()
        RandomComicWidget()
    }
}

/// The newest comic. Checks xkcd.com every couple of hours.
struct LatestComicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LatestComic", provider: ComicProvider(mode: .latest)) { entry in
            ComicWidgetView(entry: entry)
        }
        .configurationDisplayName("Latest Comic")
        .description("The newest xkcd comic.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

/// A different comic from the archive a few times a day.
struct RandomComicWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RandomComic", provider: ComicProvider(mode: .random)) { entry in
            ComicWidgetView(entry: entry)
        }
        .configurationDisplayName("Random Comic")
        .description("A surprise from the xkcd archive, changed a few times a day.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
