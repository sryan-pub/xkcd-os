import SwiftUI
import UIKit

/// Full comic with pinch and double-tap zoom, using a wrapped UIScrollView since it handles this
/// much better than a SwiftUI gesture.
struct ZoomableComicImage: View {
    let url: URL?
    /// Sharper copy to try first. Falls back to `url` if it doesn't exist.
    var highResURL: URL?
    /// Request the dark mode redraw (ignored for photographs).
    var invert = false
    /// Comic number, for the few with a hand-set dark mode treatment.
    var comicNumber: Int?
    /// Called on a single tap (a double tap zooms).
    var onTap: () -> Void = {}
    /// Downward drag on the unzoomed comic, reporting the movement so far and then calling
    /// `onDragEnd` with the final movement and speed. Used to send the comic back to the grid.
    var onDrag: (CGSize) -> Void = { _ in }
    var onDragEnd: (CGSize, CGPoint) -> Void = { _, _ in }

    @Environment(\.displayScale) private var displayScale
    /// Switching enlarging methods redraws the comic on screen.
    @AppStorage(ComicUpscaler.methodKey) private var enlargeMethod = ComicUpscaler.Method.standard.rawValue
    @State private var loaded: ComicImage?
    @State private var failed = false
    /// Sharper copy made after zooming in, and the zoom it was made for.
    @State private var sharper: ComicImage?
    @State private var sharpenedFor: CGFloat = 1
    @State private var sharpening: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Always present, comic or not, because it takes the taps and the pull back to the grid.
                // Otherwise a comic that was still loading or failed had nothing to tap, and hidden buttons
                // couldn't be brought back.
                let shown = sharper ?? loaded
                ZoomScrollViewRepresentable(image: shown?.image,
                                            paper: shown?.isInverted == true ? ImageLoader.nightPaper : .white,
                                            onTap: onTap, onDrag: onDrag, onDragEnd: onDragEnd,
                                            onZoomSettled: { zoom in sharpen(for: zoom, fitting: proxy.size) })
                if loaded == nil {
                    Group {
                        if failed || url == nil {
                            EmptyStateView(title: "Image Unavailable", systemImage: "photo",
                                           message: "Check your connection and try again.")
                        } else {
                            ProgressView()
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: "\(url?.absoluteString ?? "")|\(invert)|\(Int(proxy.size.width))x\(Int(proxy.size.height))|\(enlargeMethod)") {
                dropSharper()
                await load(fitting: proxy.size)
            }
            .onDisappear { dropSharper() }
        }
    }

    private func dropSharper() {
        sharpening?.cancel()
        sharpening = nil
        sharper = nil
        sharpenedFor = 1
    }

    /// After a zoom settles, enlarge the comic again for that zoom so a long strip read at screen
    /// width is as sharp as a comic that fits. Zoom levels go in doublings and the picture is only
    /// ever replaced by a sharper one.
    private func sharpen(for zoom: CGFloat, fitting size: CGSize) {
        guard let loaded, let shown = (sharper ?? loaded).image.cgImage, zoom > 1.2 else { return }
        // A bit more than the zoom asks for, since the page fills slightly more of the screen than the
        // fitted size and scaling down to the screen is sharper than stretching.
        let step: CGFloat = [1.5, 2, 3, 4, 6, 8, 12, 16].first { $0 >= zoom * 1.15 } ?? 16
        guard step > sharpenedFor else { return }
        // Width of the comic on screen at that zoom, in pixels.
        let base = CGSize(width: (size.width - 28) * displayScale, height: (size.height - 28) * displayScale)
        let fit = min(base.width / CGFloat(shown.width), base.height / CGFloat(shown.height))
        sharpenedFor = step
        guard fit * step > 1.15 else { return }   // already has the pixels
        sharpening?.cancel()
        sharpening = Task {
            let result = await Self.preload(url: url, highResURL: highResURL, invert: invert, comicNumber: comicNumber,
                                            fitting: size, displayScale: displayScale, zoom: step)
            guard !Task.isCancelled, let result, let made = result.image.cgImage,
                  made.width > shown.width, result.isInverted == loaded.isInverted else { return }
            sharper = result
        }
    }

    private func load(fitting size: CGSize) async {
        guard let url, size.width > 40, size.height > 40 else { return }
        // Start with the card's picture so the comic is visible from the first frame as it grows out of
        // the grid. The sharp full-size image replaces it when ready.
        if loaded == nil, let card = await ImageLoader.shared.cardImage(for: url, invert: invert) {
            loaded = card
            // The card's picture is standing in, so let the opening animation finish before decoding the
            // full-size image. Doing both at once made transitions stutter.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }
        let result = await Self.preload(url: url, highResURL: highResURL, invert: invert, comicNumber: comicNumber,
                                        fitting: size, displayScale: displayScale)
        guard !Task.isCancelled else { return }
        loaded = result
        failed = result == nil
    }

    /// Prepares the comic exactly as this view shows it at `size`. `ImageLoader` caches the result,
    /// so calling this ahead of time makes the page appear immediately.
    @discardableResult
    static func preload(url: URL?, highResURL: URL?, invert: Bool, comicNumber: Int?,
                        fitting size: CGSize, displayScale: CGFloat, zoom: CGFloat = 1) async -> ComicImage? {
        guard let url, size.width > 40, size.height > 40 else { return nil }
        // The page takes some of the space. Target the remaining area, in pixels.
        let target = CGSize(width: (size.width - 28) * displayScale * zoom, height: (size.height - 28) * displayScale * zoom)
        var result: ComicImage?
        if let highResURL {
            result = await ImageLoader.shared.displayImage(for: highResURL, standardURL: url, invert: invert, targetPixels: target, comic: comicNumber)
        }
        if result == nil, !Task.isCancelled {
            result = await ImageLoader.shared.displayImage(for: url, invert: invert, targetPixels: target, comic: comicNumber)
        }
        return result
    }
}

private struct ZoomScrollViewRepresentable: UIViewRepresentable {
    let image: UIImage?
    let paper: UIColor
    let onTap: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnd: (CGSize, CGPoint) -> Void
    let onZoomSettled: (CGFloat) -> Void

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.paper = paper
        view.image = image
        view.onSingleTap = onTap
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.onZoomSettled = onZoomSettled
    }
}

private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    /// The paper behind the comic. Slightly larger than the comic so its rounded corners never cut
    /// into the drawing.
    private let pageView = UIView()
    private let imageView = UIImageView()
    private var laidOutSize: CGSize = .zero
    private let margin: CGFloat = 6
    private let pagePadding: CGFloat = 8

    var image: UIImage? {
        didSet {
            guard image !== oldValue else { return }
            imageView.image = image
            pageView.isHidden = image == nil
            // Swap in a sharper copy of the same comic without changing the zoom.
            if let new = image?.size, let old = oldValue?.size, old.height > 0, new.height > 0,
               abs(new.width / new.height - old.width / old.height) < 0.01 * (old.width / old.height) { return }
            laidOutSize = .zero
            setNeedsLayout()
        }
    }

    var onSingleTap: (() -> Void)?
    var onDrag: ((CGSize) -> Void)?
    var onDragEnd: ((CGSize, CGPoint) -> Void)?
    var onZoomSettled: ((CGFloat) -> Void)?
    /// Zoom at which the comic fills the screen in one direction (its width, for a tall strip).
    private var fillZoom: CGFloat = 1
    private lazy var pullDown = UIPanGestureRecognizer(target: self, action: #selector(handlePull))

    /// Colour behind the drawing: white, or the dark page for redrawn comics.
    var paper: UIColor = .white {
        didSet { pageView.backgroundColor = paper }
    }

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 6
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear

        pageView.backgroundColor = paper
        pageView.layer.cornerRadius = 8
        pageView.layer.cornerCurve = .continuous
        pageView.isHidden = true
        addSubview(pageView)

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        pageView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        pullDown.maximumNumberOfTouches = 1
        pullDown.delegate = self
        addGestureRecognizer(pullDown)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize, bounds.width > 0, bounds.height > 0 else {
            keepCentredWhenUnzoomed()
            return
        }
        laidOutSize = bounds.size
        zoomScale = 1

        // Fit the comic in the view with room for the page around it, and centre the page.
        let inset = margin + pagePadding
        let available = CGSize(width: max(1, bounds.width - inset * 2), height: max(1, bounds.height - inset * 2))
        var fitted = available
        if let size = image?.size, size.width > 0, size.height > 0 {
            let scale = min(available.width / size.width, available.height / size.height)
            fitted = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let pageSize = CGSize(width: fitted.width + pagePadding * 2, height: fitted.height + pagePadding * 2)
        pageView.frame = CGRect(origin: .zero, size: pageSize)
        imageView.frame = CGRect(x: pagePadding, y: pagePadding, width: fitted.width, height: fitted.height)
        contentSize = pageSize
        fillZoom = max(bounds.width / pageSize.width, bounds.height / pageSize.height)
        // Long strips need more zoom than most comics just to be readable.
        maximumZoomScale = max(6, fillZoom * 2.5)
        centerPage()
        // Start from the centred position. Insets alone don't move a view already scrolled for a page of
        // a different size, which left the comic off to one side.
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    /// Unzoomed, the comic fits the view and can't scroll, so it should sit exactly centred. Anything
    /// that nudges it (seen as a small jump on iOS 18) is undone on the next layout.
    private func keepCentredWhenUnzoomed() {
        guard zoomScale <= minimumZoomScale + 0.001, !isTracking, !isDecelerating, !isZooming else { return }
        let centred = CGPoint(x: -contentInset.left, y: -contentInset.top)
        if abs(contentOffset.x - centred.x) > 0.5 || abs(contentOffset.y - centred.y) > 0.5 {
            contentOffset = centred
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoomSettled?(scale)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerPage() }

    private func centerPage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    @objc private func handleSingleTap() { onSingleTap?() }

    @objc private func handlePull(_ gesture: UIPanGestureRecognizer) {
        let move = gesture.translation(in: window)
        let size = CGSize(width: move.x, height: move.y)
        switch gesture.state {
        case .began, .changed: onDrag?(size)
        case .ended: onDragEnd?(size, gesture.velocity(in: window))
        case .cancelled, .failed: onDragEnd?(.zero, .zero)
        default: break
        }
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === pullDown
    }

    /// The pull only starts on the unzoomed comic, for a drag that's mostly down (back to the grid)
    /// or up (alt text). Anything else is zooming, panning or paging.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pullDown else { return super.gestureRecognizerShouldBegin(gesture) }
        let speed = pullDown.velocity(in: self)
        return zoomScale <= 1.01 && abs(speed.y) > abs(speed.x) * 1.2
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: pageView)
            // A comic with room to spare at its sides (or top and bottom) zooms to fill the screen so it can
            // be read by scrolling. Anything else zooms 2.5x.
            let fills = fillZoom >= 1.25
            let target = fills ? fillZoom : 2.5
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            var corner = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            if fills {
                if pageView.bounds.height > pageView.bounds.width { corner.x = (pageView.bounds.width - size.width) / 2 }
                else { corner.y = (pageView.bounds.height - size.height) / 2 }
            }
            zoom(to: CGRect(origin: corner, size: size), animated: true)
        }
    }
}
