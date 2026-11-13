import SwiftUI

/// Full-size comics, one per page, drawn as a layer over the grid. Swipe to move through them in
/// the grid's order, pinch or double-tap to zoom, tap to hide the buttons, drag down to send the
/// comic back to its card. Modelled on Photos: the comic grows out of its card, and during a drag
/// only the comic follows the finger while the backdrop and buttons fade.
struct ComicViewer: View {
    @Environment(ComicStore.self) private var store
    @Environment(UserState.self) private var userState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AppStorage(ImageLoader.invertSettingKey) private var invertInDarkMode = true
    /// Debug Mode switch between the trained enlarger and the hand-written one.
    @AppStorage(ComicUpscaler.methodKey) private var enlargeMethod = ComicUpscaler.Method.standard.rawValue
    /// Debug Mode read-out of the last enlargement (method, sizes, milliseconds).
    @State private var enlargeReport = ""
    @AppStorage(DebugMode.key) private var debugModeSwitch = false
    private var debugMode: Bool { DebugMode.isAvailable && debugModeSwitch }

    private let start: Int
    /// Open straight into the interactive player (`xkcdreader://play/N`).
    private let startPlaying: Bool
    /// Comics to swipe through, in the grid's current order and filter.
    private let comics: [Comic]
    /// Follows the comic on screen so the grid can hide and scroll to its card.
    @Binding private var current: Int?
    private let onClose: () -> Void

    /// Number of the comic on screen.
    @State private var position: Int?
    @State private var barsHidden = false
    /// How far the alt text panel is pulled up, 0 to 1.
    @State private var altShown: CGFloat = 0
    @State private var altHeight: CGFloat = 280
    /// The panel shows the explanation instead of the alt text.
    @State private var explaining = false
    private enum DragKind { case putBack, alt }
    @State private var dragKind: DragKind?
    @State private var pageSize: CGSize = .zero
    /// Interactive comic playing in the app, if any.
    @State private var playing: Comic?
    /// 0 while the comic sits on its card, 1 when it fills the screen.
    @State private var opened: CGFloat = 0
    /// Drag offset of the comic.
    @State private var drag: CGSize = .zero
    @State private var isSettled = false
    /// For comics far down the list the pager takes a moment to find its page. Until then a single
    /// copy of the comic stands in for it so nothing jumps.
    @State private var pagerReady = false
    @State private var actions = PagerActions()
    /// Looked up once per screen size, not per frame.
    @State private var screenInsets: EdgeInsets?
    /// Width of an iPad window's close and resize controls in the top-left corner.
    @State private var windowControls: CGFloat = 0
    /// The alt panel's contents are built after the opening animation. Building them during it
    /// dropped a frame or two.
    @State private var altBuilt = false

    init(startingAt num: Int, among comics: [Comic], playing: Bool = false, current: Binding<Int?>, onClose: @escaping () -> Void) {
        start = num
        startPlaying = playing
        self.comics = comics
        _current = current
        self.onClose = onClose
        _position = State(initialValue: num)
    }

    private var num: Int { position ?? start }

    var body: some View {
        // The outer reader knows the safe area. The inner one covers the whole screen.
        GeometryReader { outer in
        GeometryReader { proxy in
            let insets = screenInsets ?? outer.safeAreaInsets
            let screen = proxy.frame(in: .global)
            let pageFrame = CGRect(x: screen.minX + insets.leading, y: screen.minY + insets.top,
                                   width: screen.width - insets.leading - insets.trailing,
                                   height: screen.height - insets.top - insets.bottom)
            let home = cardPlacement(in: pageFrame)
            let pull = hypot(drag.width, drag.height)
            let lift = opened * (1 - min(0.12, pull / 2400))

            ZStack {
                Color(.systemBackground)
                    .opacity(opened * max(0, 1 - pull / 200))

                // The page row always spans the full screen width and each comic is inset inside its own page.
                // Insetting the row instead left it between two comics after rotating to landscape.
                Group {
                    pager(pageSize: CGSize(width: screen.width, height: pageFrame.height),
                          leading: insets.leading, trailing: insets.trailing)
                        .opacity(pagerReady ? 1 : 0)
                    if !pagerReady, let comic = store.comic(num) {
                        ComicPage(comic: comic, invert: invertInDarkMode && colorScheme == .dark,
                                  onTap: { barsHidden.toggle() }, onDrag: moveDrag, onDragEnd: endDrag)
                            .padding(.leading, insets.leading)
                            .padding(.trailing, insets.trailing)
                    }
                }
                .scaleEffect(home.scale + (1 - home.scale) * lift)
                .offset(x: home.offset.width * (1 - opened) + drag.width,
                        y: home.offset.height * (1 - opened) + drag.height)
                // No card on screen to go back to, so just fade.
                .opacity(home.hasCard ? 1 : min(1, opened * 1.5))
                // With the alt text up, VoiceOver only sees the panel.
                .accessibilityHidden(altOpen)
                .frame(width: screen.width, height: pageFrame.height)
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom)

                bars
                    .padding(insets)
                    .opacity(buttonsAway ? 0 : opened * max(0, 1 - pull / 90))
                    .accessibilityHidden(altOpen)

                // Dim the comic behind the panel.
                Color.black.opacity(0.3 * altShown)
                    .allowsHitTesting(false)

                if altShown > 0.99, dragKind == nil {
                    // Tap outside the panel to close it.
                    Color.black.opacity(0.001)
                        .onTapGesture { setAlt(shown: false) }
                        // VoiceOver closes the panel from inside it. A full-screen button behind the panel would eat
                        // every touch meant for the text.
                        .accessibilityHidden(true)
                }
                altPanel(maxHeight: pageFrame.height * (explaining ? 0.8 : 0.6))
                    .padding(.bottom, insets.bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .offset(y: (1 - altShown) * (altHeight + insets.bottom + 40))
            }
            .onChange(of: pageFrame.size, initial: true) { _, size in
                let first = pageSize == .zero
                pageSize = size
                if !first {
                    // Rotation or window resize. The page row is rebuilt at the new size and the stand-in comic
                    // covers that moment. Buttons that would now overlap the comic are hidden.
                    pagerReady = false
                    if barsWouldCover(num) { barsHidden = true }
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        pagerReady = true
                    }
                }
                // A comic the buttons would overlap opens without them and a tap brings them in. After that
                // they keep their state while swiping.
                if first { barsHidden = barsWouldCover(num) }
            }
        }
        .ignoresSafeArea()
        .onChange(of: outer.size, initial: true) {
            screenInsets = Self.screenInsets(fallback: outer.safeAreaInsets)
            windowControls = Self.windowControlsWidth()
            // Right after a rotation the window still reports the old edges (the iPhone notch moves from
            // top to side), so ask again once the rotation is done.
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                screenInsets = Self.screenInsets(fallback: outer.safeAreaInsets)
                windowControls = Self.windowControlsWidth()
            windowControls = Self.windowControlsWidth()
                try? await Task.sleep(for: .milliseconds(400))
                screenInsets = Self.screenInsets(fallback: outer.safeAreaInsets)
                windowControls = Self.windowControlsWidth()
            windowControls = Self.windowControlsWidth()
            }
        }
        .onChange(of: outer.safeAreaInsets) {
            screenInsets = Self.screenInsets(fallback: outer.safeAreaInsets)
            windowControls = Self.windowControlsWidth()
        }
        }
        // The status bar stays. Hiding it with the buttons resizes the usable area on iPad, which
        // shifts the comic and the grid behind it.
        .animation(.easeInOut(duration: 0.25), value: barsHidden)
        .onAppear {
            current = num
            userState.markViewed(num)
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) {
                opened = 1
            } completion: {
                isSettled = true
                if startPlaying, let comic = store.comic(start), comic.isPlayable { playing = comic }
                preloadNeighbours(of: num)
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    pagerReady = true
                    try? await Task.sleep(for: .milliseconds(700))
                    altBuilt = true
                    // Debug: open the alt text or explanation for App Store screenshots.
                    if let scene = DebugMode.screenshotScene, scene.num == num, scene.kind != "comic" {
                        try? await Task.sleep(for: .milliseconds(500))
                        setAlt(shown: true)
                        if scene.kind == "explain" {
                            try? await Task.sleep(for: .milliseconds(600))
                            showExplanation(for: num)
                        }
                    }
                }
            }
        }
        .onChange(of: position) { _, newValue in
            guard let newValue else { return }
            altShown = 0
            explaining = false
            current = newValue
            userState.markViewed(newValue)
            // Announce where a swipe or the dice landed.
            if voiceOver, let comic = store.comic(newValue) {
                UIAccessibility.post(notification: .pageScrolled, argument: "Comic \(comic.num), \(comic.displayTitle)")
            }
            preloadNeighbours(of: newValue)
        }
        // Two-finger scrub closes the alt text first, then the comic.
        .accessibilityAction(.escape) { if altShown > 0.5 { setAlt(shown: false) } else { close() } }
        // The grid underneath can't be reached while a comic is open.
        .accessibilityAddTraits(.isModal)
        .onReceive(NotificationCenter.default.publisher(for: ComicUpscaler.didEnlarge).receive(on: DispatchQueue.main)) { note in
            if debugMode, let report = note.object as? String { enlargeReport = report }
        }
        .fullScreenCover(item: $playing) { InteractiveComicPlayer(comic: $0) }
    }

    /// Area to keep clear (status bar, home indicator, corners). Read from the window because SwiftUI
    /// reports no insets inside this layer on iPad.
    private static func screenInsets(fallback: EdgeInsets) -> EdgeInsets {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return fallback }
        let area = window.safeAreaInsets
        return EdgeInsets(top: area.top, leading: area.left, bottom: area.bottom, trailing: area.right)
    }

    /// Space to leave for an iPad window's controls in the top-left corner, where the back button
    /// goes. 0 in full screen.
    private static func windowControlsWidth() -> CGFloat {
        guard #available(iOS 26.0, *) else { return 0 }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return 0 }
        return max(0, window.edgeInsets(for: .safeArea(cornerAdaptation: .horizontal)).left - window.safeAreaInsets.left)
    }

    /// Whether the top and bottom buttons would overlap this comic at full size.
    private func barsWouldCover(_ num: Int) -> Bool {
        guard let comic = store.comic(num), pageSize.height > 60 else { return false }
        // Interactive comics always keep their buttons since Play is one of them.
        guard !comic.isPlayable else { return false }
        let full = fitted(aspect: comic.aspectRatio, in: CGSize(width: pageSize.width - 28, height: pageSize.height - 28))
        return (pageSize.height - full.height) / 2 < 60
    }

    /// Prepare the neighbouring comics so a swipe lands on a finished page.
    private func preloadNeighbours(of num: Int) {
        guard pageSize.width > 60, let index = comics.firstIndex(where: { $0.num == num }) else { return }
        let invert = invertInDarkMode && colorScheme == .dark
        let size = pageSize
        let neighbours = [index + 1, index - 1, index + 2].filter { comics.indices.contains($0) }.map { comics[$0] }
        Task(priority: .utility) {
            // Not while a transition may still be running.
            try? await Task.sleep(for: .milliseconds(900))
            guard self.num == num else { return }
            for comic in neighbours {
                await ZoomableComicImage.preload(url: comic.imageURL, highResURL: comic.highResImageURL, invert: invert,
                                                 comicNumber: comic.num, fitting: size, displayScale: displayScale)
            }
        }
    }

    // MARK: Alt text panel

    /// Grow the panel into the explanation. If the text hasn't arrived yet, wait up to 600 ms for it
    /// so the panel opens with the text in place instead of the text popping in afterwards.
    private func showExplanation(for num: Int) {
        Task {
            if ExplanationClient.cached(num) == nil {
                let fetch = Task { _ = try? await ExplanationClient.shared.explanation(for: num) }
                let patience = Task { try? await Task.sleep(for: .milliseconds(600)) }
                // Whichever comes first.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await fetch.value }
                    group.addTask { await patience.value }
                    await group.next()
                    group.cancelAll()
                }
                patience.cancel()
            }
            guard self.num == num, altShown > 0 else { return }
            withAnimation(.spring(duration: 0.35, bounce: 0.1)) { explaining = true }
        }
    }

    /// Start fetching the explanation while the alt text is open, only for comics whose alt text
    /// was opened.
    private func warmExplanation() {
        let num = num
        guard ExplanationClient.cached(num) == nil else { return }
        Task(priority: .utility) { _ = try? await ExplanationClient.shared.explanation(for: num) }
    }

    private func setAlt(shown: Bool) {
        if shown { warmExplanation() }
        withAnimation(.spring(duration: 0.32, bounce: 0.1)) {
            altShown = shown ? 1 : 0
        } completion: {
            // Open on the alt text next time.
            if !shown { explaining = false }
            // Move VoiceOver into the panel when it opens and back to the comic when it closes.
            if voiceOver { UIAccessibility.post(notification: .screenChanged, argument: nil) }
        }
    }

    /// Alt text panel that slides up from the bottom, opened with the Alt button or by swiping up on
    /// the comic.
    private func altPanel(maxHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                // The handle is also VoiceOver's close button, with a usable touch area.
                .overlay {
                    Color.clear
                        .frame(width: 220, height: 28)
                        .contentShape(.rect)
                        .accessibilityElement()
                        .accessibilityLabel("Close alt text")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { setAlt(shown: false) }
                }
            if altBuilt || altShown > 0, let comic = store.comic(num) {
                if explaining {
                    // The same panel grows to hold the explanation.
                    ExplanationContent(comic: comic) {
                        withAnimation(.spring(duration: 0.35, bounce: 0.1)) { explaining = false }
                    }
                    .frame(height: maxHeight - 24)
                    .transition(.opacity)
                } else {
                    let explain = { showExplanation(for: comic.num) }
                    ViewThatFits(in: .vertical) {
                        AltTextContent(comic: comic, onExplain: explain)
                        ScrollView { AltTextContent(comic: comic, onExplain: explain) }
                    }
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: 640)
        .frame(maxHeight: maxHeight, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        // Frosted with a thin outline so it reads as a sheet over the comic. A dark panel on a dark
        // comic blended together.
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        // Clip scrolling text to the panel's rounded edge.
        .clipShape(.rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.18), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 18, y: 4)
        .padding(.horizontal, 10)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { altHeight = $0 }
        .gesture(
            // Measured in screen space because the panel moves under the finger. Measuring against the
            // moving view caused feedback and flicker.
            DragGesture(coordinateSpace: .global)
                .onChanged { value in altShown = min(1, max(0, 1 - value.translation.height / max(altHeight, 1))) }
                .onEnded { value in setAlt(shown: value.translation.height < 60 && value.predictedEndTranslation.height < 160) }
        )
        .accessibilityHidden(altShown == 0)
        .accessibilityAction(.escape) { setAlt(shown: false) }
        .onChange(of: explaining) {
            guard voiceOver else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
    }

    // MARK: Opening and closing

    /// Where the comic sits on its card: scale relative to full screen and offset from the page
    /// centre.
    private func cardPlacement(in page: CGRect) -> (scale: CGFloat, offset: CGSize, hasCard: Bool) {
        guard let comic = store.comic(num), let card = CardFrames.shared.frame(for: num),
              page.width > 60, page.height > 60, card.intersects(page.insetBy(dx: 0, dy: -200)) else {
            return (0.9, .zero, false)
        }
        // Full-screen frame (see ZoomScrollView's layout) and card frame (see ComicTile).
        let full = fitted(aspect: comic.aspectRatio, in: page.insetBy(dx: 14, dy: 14).size)
        let small = fitted(aspect: comic.tileAspectRatio, in: card.insetBy(dx: 8, dy: 8).size)
        return (small.width / max(full.width, 1),
                CGSize(width: card.midX - page.midX, height: card.midY - page.midY), true)
    }

    private func fitted(aspect: Double, in size: CGSize) -> CGSize {
        let width = min(size.width, size.height * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    private func close() {
        isSettled = false
        withAnimation(.spring(duration: 0.34, bounce: 0.1)) {
            opened = 0
            drag = .zero
        } completion: {
            onClose()
        }
    }

    private func moveDrag(_ move: CGSize) {
        // A drag that starts upward opens the alt text. One that starts downward sends the comic back
        // to the grid.
        if dragKind == nil {
            // Wait for real movement before picking a direction.
            guard abs(move.height) > 6 else { return }
            dragKind = move.height < 0 ? .alt : .putBack
        }
        if dragKind == .alt {
            altShown = min(1, max(0, -move.height / max(altHeight, 1)))
        } else {
            isSettled = false
            drag = move
        }
    }

    private func endDrag(_ move: CGSize, speed: CGPoint) {
        defer { dragKind = nil }
        if dragKind == .alt {
            setAlt(shown: -move.height > 50 || speed.y < -500)
            return
        }
        if move.height > 90 || speed.y > 700 {
            close()
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                drag = .zero
            } completion: {
                isSettled = true
            }
        }
    }

    // MARK: Pages

    private func pager(pageSize: CGSize, leading: CGFloat, trailing: CGFloat) -> some View {
        ComicPager(comics: comics, invert: invertInDarkMode && colorScheme == .dark, pageSize: pageSize,
                   leading: leading, trailing: trailing,
                   current: num, showNeighbours: isSettled,
                   // No paging while the comic or the alt text is being dragged.
                   locked: !isSettled || dragKind != nil,
                   position: $position, actions: actions)
            .equatable()
            .id("\(Int(pageSize.width))x\(Int(pageSize.height))")
            .onAppear {
                actions.onTap = { barsHidden.toggle() }
                actions.onDrag = moveDrag
                actions.onDragEnd = endDrag
            }
    }

    // MARK: Buttons

    /// With VoiceOver the buttons always stay visible so they can be found.
    private var buttonsAway: Bool { barsHidden && !voiceOver }

    private var altOpen: Bool { altShown > 0.5 }

    private var bars: some View {
        VStack(spacing: 0) {
            ZStack {
                // The title uses the same plate as the buttons so it stays readable over tall comics.
                Text(store.comic(num)?.displayTitle ?? "")
                    .font(.xkcd(size: 21, relativeTo: .headline))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(ToolbarIcon.fill, in: .capsule)
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.22), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .padding(.leading, 60 + windowControls)
                    .padding(.trailing, debugMode ? 118 : 60)
                    .accessibilityAddTraits(.isHeader)
                HStack {
                    Button { close() } label: { ToolbarIcon(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                        .padding(.leading, windowControls)
                    Spacer()
                    if debugMode {
                        // Trained enlarger or hand-written one, for comparison.
                        Button {
                            // Cycles Neural Engine tiles, whole picture on the GPU, hand-written.
                            let all = ComicUpscaler.Method.allCases
                            let now = ComicUpscaler.Method(rawValue: enlargeMethod) ?? .standard
                            enlargeMethod = all[(all.firstIndex(of: now)! + 1) % all.count].rawValue
                        } label: {
                            ToolbarIcon(text: (ComicUpscaler.Method(rawValue: enlargeMethod) ?? .standard).label)
                        }
                        .accessibilityLabel("Enlarging method")
                    }
                    if let comic = store.comic(num) {
                        ShareLink(item: comic.pageURL) { ToolbarIcon(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            if debugMode, !enlargeReport.isEmpty {
                Text(enlargeReport)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 6)
                    .onTapGesture { UIPasteboard.general.string = enlargeReport }
            }

            Spacer(minLength: 0)

            if let comic = store.comic(num), comic.isPlayable {
                // Interactive comics run in the app from xkcd.com.
                Button { playing = comic } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.xkcd(size: 20, relativeTo: .body))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 42)
                        .background(Color.xkcdSlate, in: .capsule)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                }
                .accessibilityLabel("Play interactive comic")
                .padding(.bottom, 14)
            }

            // Favorite, alt text and random each get a third of the width, centred.
            HStack(spacing: 0) {
                let isFavorite = userState.isFavorite(num)
                Button {
                    userState.toggleFavorite(num)
                } label: {
                    ToolbarIcon(systemName: isFavorite ? "heart.fill" : "heart", tint: isFavorite ? .red : .primary)
                }
                .accessibilityLabel(isFavorite ? "Remove Favorite" : "Favorite")
                .frame(maxWidth: .infinity)

                Button { setAlt(shown: altShown < 0.5) } label: { ToolbarIcon(text: "Alt") }
                    .accessibilityLabel("Alt text")
                    .frame(maxWidth: .infinity)

                Button {
                    // Jump without animating, which would scroll past hundreds of pages.
                    if let pick = comics.filter({ $0.num != num }).randomElement() { position = pick.num }
                } label: {
                    ToolbarIcon(systemName: "dice")
                }
                .accessibilityLabel("Random Comic")
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!buttonsAway)
    }
}

/// What the pages report back. A reference type so passing it to the pager never counts as a change.
private final class PagerActions {
    var onTap: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: (CGSize, CGPoint) -> Void = { _, _ in }
}

/// The page row as its own Equatable view. Dragging a comic or the alt text changes offsets and
/// opacities every frame, and without this SwiftUI re-evaluated the whole comic list each time,
/// which stuttered.
private struct ComicPager: View, Equatable {
    let comics: [Comic]
    let invert: Bool
    let pageSize: CGSize
    let leading: CGFloat
    let trailing: CGFloat
    let current: Int
    let showNeighbours: Bool
    let locked: Bool
    @Binding var position: Int?
    let actions: PagerActions

    static func == (a: ComicPager, b: ComicPager) -> Bool {
        a.invert == b.invert && a.pageSize == b.pageSize && a.leading == b.leading && a.trailing == b.trailing
            && a.current == b.current
            && a.showNeighbours == b.showNeighbours && a.locked == b.locked
            && a.comics.count == b.comics.count && a.comics.first?.num == b.comics.first?.num
            && a.comics.last?.num == b.comics.last?.num
    }

    /// Scroll position, kept in a plain object instead of state so scrolling doesn't redraw the row.
    @State private var offset = PagerOffset()

    var body: some View {
        ScrollViewReader { proxy in
            row
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in
                    offset.x = x
                    // Moves with no finger down (the row being built as a comic opens, a relayout) are checked once
                    // the row has been still for 150 ms.
                    offset.settle?.cancel()
                    guard offset.phase == .idle else { return }
                    offset.settle = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, offset.phase == .idle else { return }
                        realign(proxy)
                    }
                }
                // A row resting between two comics is moved back onto one. Seen on iOS 18 devices, both a full
                // page off and a few points off after opening a comic.
                .onScrollPhaseChange { _, phase in
                    offset.phase = phase
                    if phase == .idle { realign(proxy) } else { offset.settle?.cancel() }
                }
                .onChange(of: locked) { _, isLocked in
                    if !isLocked { realign(proxy) }
                }
                .onAppear {
                    offset.settle?.cancel()
                    offset.settle = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        realign(proxy)
                    }
                }
        }
    }

    private func realign(_ proxy: ScrollViewProxy) {
        let width = pageSize.width
        guard width > 1, !locked, !comics.isEmpty else { return }
        let page = offset.x / width
        let nearest = min(max(Int(page.rounded()), 0), comics.count - 1)
        let off = abs(page - Double(nearest)) * width
        guard off > 1 else { return }
        // Small offsets are fixed instantly since a tiny animation looks like a wobble. Larger ones
        // slide back.
        if off < 30 {
            proxy.scrollTo(comics[nearest].num, anchor: .leading)
        } else {
            withAnimation(.snappy(duration: 0.25)) {
                proxy.scrollTo(comics[nearest].num, anchor: .leading)
            }
        }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(comics) { comic in
                    ComicPage(comic: comic, invert: invert,
                              onTap: { actions.onTap() },
                              onDrag: { actions.onDrag($0) },
                              onDragEnd: { actions.onDragEnd($0, $1) })
                        .padding(.leading, leading)
                        .padding(.trailing, trailing)
                        // Explicit size. Asking for the container's size returned the whole iPad screen, status bar
                        // and corners included.
                        .frame(width: pageSize.width, height: pageSize.height)
                        // Hide neighbouring pages while this one moves.
                        .opacity(showNeighbours || comic.num == current ? 1 : 0)
                        // VoiceOver only sees the comic being read. Otherwise a one-finger swipe moved onto the next
                        // page and dragged the row with it. Comics change with a three-finger swipe.
                        .accessibilityHidden(comic.num != current)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        .scrollIndicators(.hidden)
        .scrollDisabled(locked)
        // No horizontal safe-area insets, each page handles the notch and edges itself. On iOS 18 (not
        // 26) the row's scale animation ends with its edges a fraction of a point inside the screen,
        // and the scroll view then got fractional side insets and shifted its offset by about 1e-4 of
        // the offset (10 pt at page 263, 96 pt at page 2496), leaving old comics off-centre. Top and
        // bottom keep their insets. Test with scripts/check_pager_alignment.py on an iOS 18 Simulator.
        .ignoresSafeArea(edges: .horizontal)
    }
}

private final class PagerOffset {
    var x: CGFloat = 0
    var phase: ScrollPhase = .idle
    var settle: Task<Void, Never>?
}

/// One comic filling the page.
private struct ComicPage: View {
    let comic: Comic
    let invert: Bool
    let onTap: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: (CGSize, CGPoint) -> Void

    var body: some View {
        ZoomableComicImage(url: comic.imageURL, highResURL: comic.highResImageURL, invert: invert,
                           comicNumber: comic.num, onTap: onTap, onDrag: onDrag, onDragEnd: onDragEnd)
            // For VoiceOver the comic is one image, described by xkcd's transcript where there is one,
            // plus the alt text.
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel("Comic \(comic.num), \(comic.displayTitle)")
            .accessibilityValue(spokenDescription)
    }

    private var spokenDescription: String {
        let transcript = comic.transcript
            .replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            .replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Most transcripts end with the alt text ("Title text: ..."). Add it where one doesn't.
        let alt = comic.alt.isEmpty ? "" : "Alt text: \(comic.alt)"
        if transcript.isEmpty { return alt }
        if alt.isEmpty || transcript.localizedCaseInsensitiveContains("title text") || transcript.localizedCaseInsensitiveContains("alt text") { return transcript }
        return transcript + "\n" + alt
    }
}

/// Card positions on screen, so the viewer can grow out of a card and shrink back into it.
@MainActor
final class CardFrames {
    static let shared = CardFrames()
    private final class Weak { weak var view: UIView?; init(_ view: UIView) { self.view = view } }
    private var cards: [Int: Weak] = [:]

    func register(_ view: UIView, for num: Int) { cards[num] = Weak(view) }

    /// The card's frame in the window, or nil if it isn't in the grid.
    func frame(for num: Int) -> CGRect? {
        guard let view = cards[num]?.view, view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
}

/// Placed behind a card to record its position.
struct CardAnchor: UIViewRepresentable {
    let num: Int

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        CardFrames.shared.register(view, for: num)
    }
}

/// Alt text, plus the comic's number, date and a link to its explanation.
private struct AltTextContent: View {
    let comic: Comic
    let onExplain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(String(comic.num))")
                        .font(.xkcd(size: 24, relativeTo: .headline))
                    Text(comic.dateText)
                        .font(.xkcd(size: 18, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onExplain) { ToolbarIcon(text: "Explain") }
                    .buttonStyle(.plain)
            }
            Text(comic.alt.isEmpty ? "This comic has no alt text." : comic.alt)
                .font(.xkcd(size: 21, relativeTo: .body))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
    }
}
