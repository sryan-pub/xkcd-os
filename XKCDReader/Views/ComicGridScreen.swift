import SwiftUI
import WidgetKit

enum ComicFilter: String, CaseIterable, Identifiable {
    case all = "All Comics"
    case unread = "Unread"
    case favorites = "Favorites"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .unread: "circle"
        case .favorites: "heart"
        }
    }
}

/// Home screen. Every comic as a mosaic of cards shaped like the comics.
struct ComicGridScreen: View {
    @Environment(ComicStore.self) private var store
    @Environment(UserState.self) private var userState
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(ImageLoader.invertSettingKey) private var invertInDarkMode = true
    @AppStorage(NewComicNotifier.enabledKey) private var alertsEnabled = false

    @State private var filter: ComicFilter = .all
    @State private var searchText = ""
    /// Which comic is open full screen, if any. Kept outside this view's state, see `ViewerFocus`.
    @State private var focus = ViewerFocus()
    @State private var confirmClearCache = false
    @State private var showIconPicker = false
    @State private var showAbout = false
    /// Debug Mode switch from the Settings app (Settings > xkcd > Debug Mode).
    @AppStorage(DebugMode.key) private var debugModeSwitch = false
    private var debugMode: Bool { DebugMode.isAvailable && debugModeSwitch }
    @State private var randomFillsWidget = SharedSettings.randomFillsWidget
    @State private var notice: String?

    /// A comic requested before it can be shown, either because an alert or widget launched the app
    /// before comics loaded or because the comic is newer than anything loaded.
    @State private var waiting: (num: Int, playing: Bool, refreshed: Bool)?

    /// Opens the waiting comic once it exists, fetching new comics once if it doesn't.
    private func openWaitingComic() {
        guard let request = waiting, store.isLoaded else { return }
        if store.comic(request.num) != nil {
            waiting = nil
            open(request.num, playing: request.playing)
        } else if !store.isRefreshing {
            if request.refreshed {
                waiting = nil
                notice = "Comic #\(request.num) couldn't be loaded. Check your connection and try again."
            } else {
                waiting?.refreshed = true
                Task {
                    await store.refresh()
                    openWaitingComic()
                }
            }
        }
    }

    private func open(_ num: Int, playing: Bool = false) {
        guard store.comic(num) != nil else {
            waiting = (num, playing, false)
            openWaitingComic()
            return
        }
        // Opened from search with the keyboard up. Dismiss it so it doesn't cover the comic.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let shown = visibleComics
        focus.comic = num
        // Comics opened from a widget, an alert or the dice can be outside the current filter.
        focus.opened = ViewerFocus.Opened(num: num, comics: shown.contains { $0.num == num } ? shown : store.comics, playing: playing)
    }

    /// Debug: opens the comics listed at launch one at a time like the dice does, returning to the
    /// grid in between (see `DebugMode.pagerCheckComics`). The check script screenshots each one.
    private func runPagerCheck() async {
        if DebugMode.isTakingScreenshots, UserDefaults.standard.string(forKey: "screenshot") == "about" {
            try? await Task.sleep(for: .seconds(1))
            showAbout = true
            return
        }
        if let scene = DebugMode.screenshotScene, store.isLoaded {
            try? await Task.sleep(for: .seconds(1))
            open(scene.num)
            return
        }
        let nums = DebugMode.pagerCheckComics
        guard store.isLoaded, !nums.isEmpty else { return }
        try? await Task.sleep(for: .seconds(1))
        for num in nums {
            open(num)
            NSLog("PagerCheck opened %d", num)
            try? await Task.sleep(for: .seconds(DebugMode.pagerCheckHold))
            focus.opened = nil
            focus.comic = nil
            try? await Task.sleep(for: .seconds(1))
        }
        NSLog("PagerCheck done")
    }

    var body: some View {
        NavigationStack {
            content
                .background(gridBackground)
                .navigationTitle(filter == .all ? "xkcd" : filter.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Title, number or text")
                .onOpenURL { url in
                    // Widgets open the app with xkcdreader://comic/<number>.
                    // xkcdreader://play/<number> opens an interactive comic straight into its player.
                    guard url.scheme == "xkcdreader", url.host == "comic" || url.host == "play",
                          let num = Int(url.lastPathComponent) else { return }
                    open(num, playing: url.host == "play")
                }
                .onReceive(NotificationCenter.default.publisher(for: ComicLink.openComic)) { _ in
                    if let num = ComicLink.takePending() { open(num) }
                }
                .onAppear {
                    if let num = ComicLink.takePending() { open(num) }
                }
                .onChange(of: store.isLoaded) { openWaitingComic() }
                .task(id: store.isLoaded) { await runPagerCheck() }
                .onChange(of: store.isRefreshing) { openWaitingComic() }
                .toolbar { toolbar }
                // Widgets use the same dark mode setting, read from the shared store.
                .onChange(of: invertInDarkMode, initial: true) { _, invert in
                    guard SharedSettings.invertInDarkMode != invert else { return }
                    SharedSettings.invertInDarkMode = invert
                    WidgetCenter.shared.reloadAllTimelines()
                }
                .onChange(of: randomFillsWidget) { _, fill in
                    SharedSettings.randomFillsWidget = fill
                    WidgetCenter.shared.reloadTimelines(ofKind: "RandomComic")
                }
                .confirmationDialog("Remove downloaded comic images?", isPresented: $confirmClearCache, titleVisibility: .visible) {
                    Button("Clear Image Cache", role: .destructive) {
                        Task { await ImageLoader.shared.clear() }
                    }
                } message: {
                    Text("Favorites and read history are kept. Images download again as you browse.")
                }
                .sheet(isPresented: $showIconPicker) {
                    AppIconPicker()
                }
                .sheet(isPresented: $showAbout) {
                    AboutScreen()
                }
                .alert("xkcd", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                    Button("OK") {}
                } message: {
                    Text(notice ?? "")
                }
        }
        .overlay { ViewerLayer(focus: focus) }
    }

    private var gridBackground: Color { Color.xkcdSlate.opacity(0.55) }

    /// Comics are inverted only when the setting is on and the device is in dark mode.
    private var invertComics: Bool { invertInDarkMode && colorScheme == .dark }

    @ViewBuilder
    private var content: some View {
        let visible = visibleComics
        if !store.isLoaded {
            ProgressView("Loading comics…")
                .font(.xkcd(size: 20, relativeTo: .body))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            emptyState
        } else {
            GeometryReader { proxy in
                let columnCount = max(2, Int(proxy.size.width / 190))
                ScrollViewReader { scroller in
                    ScrollView {
                        MosaicGrid(comics: visible, columnCount: columnCount) { comic in
                            // Favorites are nearly all read, so they aren't dimmed there.
                            ComicCard(comic: comic, dimWhenRead: filter != .favorites, invert: invertComics,
                                      focus: focus) { open(comic.num) }
                                .onAppear { prefetch(after: comic, in: visible) }
                        }
                        .padding(6)
                    }
                    .refreshable { await store.refresh() }
                    .background {
                        FocusFollower(focus: focus) { num in
                            // Keep the open comic's card on screen so it can return to it.
                            let screen = proxy.frame(in: .global)
                            if let card = CardFrames.shared.frame(for: num), screen.contains(card) { return }
                            scroller.scrollTo(num, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// Preloads the comics just below the one that scrolled into view.
    private func prefetch(after comic: Comic, in comics: [Comic]) {
        guard let index = comics.firstIndex(where: { $0.num == comic.num }) else { return }
        let upcoming = comics[(index + 1)...].prefix(20).compactMap { comic in comic.imageURL.map { (num: comic.num, url: $0) } }
        guard !upcoming.isEmpty else { return }
        let invert = invertComics
        // Only the newest request is kept and it waits briefly before starting. Without this a long
        // fast scroll queued about twenty downloads per card and the visible cards waited behind
        // hundreds already scrolled past.
        Prefetching.current?.cancel()
        Prefetching.current = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await ImageLoader.shared.prefetch(upcoming, maxPixel: 700, invert: invert)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            EmptyStateView(title: "No Results", systemImage: "magnifyingglass",
                           message: "Nothing matches \u{201C}\(searchText)\u{201D}.")
        } else if filter == .favorites {
            EmptyStateView(title: "No Favorites Yet", systemImage: "heart",
                           message: "Tap the heart on a comic to keep it here.")
        } else if filter == .unread {
            EmptyStateView(title: "All Caught Up", systemImage: "checkmark.circle",
                           message: "You have read every comic.")
        } else {
            EmptyStateView(title: "No Comics", systemImage: "wifi.slash",
                           message: "Pull down to try again.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // Narrow iPad windows only have room for the short name.
            ViewThatFits(in: .horizontal) {
                Text(filter == .all ? "xkcd: Open Source" : filter.rawValue)
                Text(filter == .all ? "xkcd" : filter.rawValue)
                    .minimumScaleFactor(0.7)
            }
            .font(.xkcd(size: 23, relativeTo: .headline))
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                if let comic = store.random() { open(comic.num) }
            } label: {
                ToolbarIcon(systemName: "dice")
            }
            // Plain style, like the viewer's buttons. The toolbar style on iOS 18 fades the whole label
            // while pressed, including the white face and shadow.
            .buttonStyle(.plain)
            .accessibilityLabel("Random Comic")
            .disabled(!store.isLoaded)
        }
        .solidBackground()
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(ComicFilter.allCases) { option in
                        Label(option.rawValue, systemImage: option.icon).tag(option)
                    }
                }
                Divider()
                Toggle("New Comic Alerts", systemImage: "bell", isOn: alertsBinding)
                Toggle("Invert Comics in Dark Mode", systemImage: "circle.lefthalf.filled", isOn: $invertInDarkMode)
                Toggle("Random Widget Fits Its Shape", systemImage: "rectangle.inset.filled", isOn: $randomFillsWidget)
                Button("App Icon…", systemImage: "app.badge") {
                    showIconPicker = true
                }
                Button("About…", systemImage: "info.circle") {
                    showAbout = true
                }
                // Testing tools, only in Debug Mode.
                if debugMode {
                Menu("Enlarging Benchmark", systemImage: "stopwatch") {
                    ForEach(ComicUpscaler.Method.allCases, id: \.self) { method in
                        Button("Run with \(method.label) (starts in 8 s)") {
                            Task { notice = await EnlargeBenchmark.run(method, store: store) }
                        }
                    }
                }
                Menu("Test Alerts", systemImage: "bell.badge") {
                    Button("Send a Test Alert in 6 Seconds", systemImage: "timer") {
                        Task {
                            notice = await NewComicNotifier.sendTestAlert()
                                ? "A test alert arrives in 6 seconds. Leave the app or lock the phone to see it as a banner; tap it to open the comic."
                                : "Couldn't schedule the alert. Check that notifications are allowed for this app in Settings."
                        }
                    }
                    Button("Arm a Real Background Check", systemImage: "moon.zzz") {
                        Task {
                            notice = await NewComicNotifier.armBackgroundTest()
                                ? "Armed. The newest comic now counts as unseen until iOS next wakes the app in the background, which can take hours. Turn on New Comic Alerts, then leave the app closed; you should get an alert for the newest comic."
                                : "Couldn't reach xkcd.com to arm the test."
                        }
                    }
                }
                }
                Divider()
                Button("Clear Image Cache…", systemImage: "trash", role: .destructive) {
                    confirmClearCache = true
                }
            } label: {
                ToolbarIcon(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("Menu")
        }
        .solidBackground()
    }

    /// Turning alerts on asks iOS for permission first and stays off if denied.
    private var alertsBinding: Binding<Bool> {
        Binding {
            alertsEnabled
        } set: { wantsAlerts in
            guard wantsAlerts else {
                alertsEnabled = false
                NewComicNotifier.schedule()
                return
            }
            Task {
                if await NewComicNotifier.requestPermission() {
                    alertsEnabled = true
                    NewComicNotifier.markSeen(store.latestNum)
                    NewComicNotifier.schedule()
                    notice = "You'll get an alert when a new comic is out. iOS chooses when to check, so it can arrive a few hours after the comic does."
                } else {
                    alertsEnabled = false
                    notice = "Notifications are turned off for this app. You can allow them in Settings."
                }
            }
        }
    }

    private var visibleComics: [Comic] {
        var result = store.comics
        switch filter {
        case .all: break
        case .unread: result = result.filter { !userState.isViewed($0.num) }
        case .favorites: result = result.filter { userState.isFavorite($0.num) }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }
        if Int(query) != nil {
            return result.filter { String($0.num).hasPrefix(query) }
        }
        return result.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.alt.localizedCaseInsensitiveContains(query)
                || $0.transcript.localizedCaseInsensitiveContains(query)
        }
    }
}

/// Lays comics out in columns, always adding the next one to the shortest column, so cards of
/// very different shapes pack tightly in roughly newest-first order.
struct MosaicGrid<Cell: View>: View {
    let comics: [Comic]
    let columnCount: Int
    @ViewBuilder let cell: (Comic) -> Cell

    private let spacing: CGFloat = 6

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @ViewBuilder
    var body: some View {
        if voiceOver {
            // VoiceOver reads a layout in build order, and packed columns read one column at a time. With
            // VoiceOver on, comics are laid out in rows so they read newest to oldest.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columnCount),
                      spacing: spacing) {
                ForEach(comics) { comic in cell(comic) }
            }
        } else {
            packed
        }
    }

    private var packed: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                LazyVStack(spacing: spacing) {
                    ForEach(column) { comic in
                        cell(comic)
                    }
                }
            }
        }
    }

    private var columns: [[Comic]] {
        // This walks every comic and the grid's body runs often, so the last result is cached for the
        // same comics and column count.
        var key = Hasher()
        key.combine(columnCount)
        for comic in comics { key.combine(comic.num) }
        let signature = key.finalize()
        if let cached = MosaicColumnsCache.last, cached.signature == signature { return cached.columns }
        let fresh = computeColumns()
        MosaicColumnsCache.last = (signature, fresh)
        return fresh
    }

    private func computeColumns() -> [[Comic]] {
        var columns = Array(repeating: [Comic](), count: columnCount)
        var heights = Array(repeating: 0.0, count: columnCount)
        for comic in comics {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(comic)
            heights[shortest] += 1 / comic.tileAspectRatio + 0.12   // Card height in column widths, plus padding.
        }
        return columns
    }
}

/// The single allowed preload of upcoming cards.
@MainActor
private enum Prefetching {
    static var current: Task<Void, Never>?
}

@MainActor
private enum MosaicColumnsCache {
    static var last: (signature: Int, columns: [[Comic]])?
}

/// Which comic is open full screen. Kept in its own observable object read only by the small views
/// that need it (the viewer layer, each card, the scroll follower). As state on the grid screen,
/// every open, close and swipe re-evaluated the whole grid, which stuttered on iPhone when a
/// comic was closed.
@Observable
final class ViewerFocus {
    struct Opened {
        let num: Int
        /// What the grid was showing when the comic was opened. Swiping stays within it.
        let comics: [Comic]
        var playing = false
        let id = UUID()
    }

    /// Where the viewer starts. A new value restarts the viewer.
    var opened: Opened?
    /// Comic the viewer is showing now. Its card is hidden while it's out of the grid.
    var comic: Int?
}

/// Full-screen viewer, when a comic is open.
private struct ViewerLayer: View {
    let focus: ViewerFocus

    var body: some View {
        if let opened = focus.opened {
            ComicViewer(startingAt: opened.num, among: opened.comics, playing: opened.playing,
                        current: Binding(get: { focus.comic }, set: { focus.comic = $0 })) {
                focus.opened = nil
                focus.comic = nil
            }
            .id(opened.id)
            // The viewer ignores the keyboard. When opened from search the keyboard is on its way down, and
            // following it resized the pages mid-animation and left the comic slightly off its page.
            .ignoresSafeArea(.keyboard)
        }
    }
}

/// Tells the grid when the viewer moves to another comic.
private struct FocusFollower: View {
    let focus: ViewerFocus
    let moved: (Int) -> Void

    var body: some View {
        Color.clear
            // Scrolling a far-off card into view makes the grid build many cards at once, which stalled a
            // swipe when done immediately. Wait until the reader stops on a comic.
            .task(id: focus.comic) {
                guard let num = focus.comic, focus.opened != nil else { return }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, focus.comic == num, focus.opened != nil else { return }
                moved(num)
            }
    }
}

/// A card is empty while its comic is open, like Photos. This is a separate modifier so that when
/// the open comic changes each card only re-checks this; if the card read `focus` itself, every
/// visible card would rebuild its whole body.
private struct EmptyWhileOut: ViewModifier {
    let num: Int
    let focus: ViewerFocus

    func body(content: Content) -> some View {
        content.opacity(focus.comic == num ? 0 : 1)
    }
}

/// One card in the grid. Reads its own read and favorite state and whether its comic is open, so
/// the grid doesn't have to.
private struct ComicCard: View {
    let comic: Comic
    let dimWhenRead: Bool
    let invert: Bool
    let focus: ViewerFocus
    let open: () -> Void
    @Environment(UserState.self) private var userState

    var body: some View {
        let isFavorite = userState.isFavorite(comic.num)
        let isViewed = userState.isViewed(comic.num)
        Button(action: open) {
            ComicTile(comic: comic, isViewed: dimWhenRead && isViewed, isFavorite: isFavorite, invert: invert)
                .equatable()
                .background(CardAnchor(num: comic.num))
        }
        .buttonStyle(.plain)
        .modifier(EmptyWhileOut(num: comic.num, focus: focus))
        .contextMenu {
            Button(isFavorite ? "Remove Favorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart") {
                userState.toggleFavorite(comic.num)
            }
            Button(isViewed ? "Mark as Unread" : "Mark as Read", systemImage: isViewed ? "circle" : "checkmark.circle") {
                userState.setViewed(comic.num, !isViewed)
            }
            ShareLink(item: comic.pageURL)
        }
    }
}
