import CoreText
import HerdrKit
import SwiftUI
import UIKit

/// Draws a `ScreenFrame` cell by cell and turns touches and keys into terminal input.
final class TerminalCanvasView: UIView, UITextInput {
    var model: TerminalScreenModel? {
        didSet {
            guard model !== oldValue else { return }
            oldValue?.setScrollActive(false)
            cancelScrolling()
            // A new model (after a reconnect) needs the grid size to attach.
            lastGrid = nil
            setNeedsLayout()
            contentView.setNeedsDisplay()
        }
    }
    var screen: ScreenFrame = .empty {
        didSet {
            // What shows before (and around) the drawn cells: the screen's own background.
            if screen.background != oldValue.background { backgroundColor = UIColor(screen.background) }
            synchronizeScrolling()
            presentRemoteShift(from: oldValue)
            invalidate(from: oldValue)
            layoutContent()
            #if DEBUG
            TerminalScrollTrace.shared?.record("canvas", offset: CGFloat(screen.scrollbar?.offset ?? 0))
            #endif
        }
    }
    var fontSize: CGFloat = 13 {
        didSet {
            guard fontSize != oldValue else { return }
            cancelScrolling()
            fonts = Fonts(size: fontSize, family: fontFamily)
            // At once: until the new grid reaches the emulator, the old columns don't fit the
            // new font and `geometry()` would shrink it back, which looks like a jump.
            reportGridSize(force: true, immediately: true)
            redrawContent()
        }
    }
    var fontFamily: TerminalFont = .jetBrainsMono {
        didSet {
            guard fontFamily != oldValue else { return }
            cancelScrolling()
            fonts = Fonts(size: fontSize, family: fontFamily)
            scaledFonts = nil
            reportGridSize(force: true, immediately: true)
            redrawContent()
        }
    }
    /// Cells that fit at the current font size; reported when they change.
    var onGridSize: ((Int, Int) -> Void)?
    var onFontSize: ((CGFloat) -> Void)?

    private var fonts = Fonts(size: 13)
    /// Smaller fonts for when another viewer's larger size must fit; rebuilt only when the scale changes.
    private var scaledFonts: Fonts?
    // Text only: selection, backgrounds and cursor remain live overlays. Content keys let
    // unchanged rows survive scrolling even though Ghostty conservatively dirties every row.
    private struct TextRow {
        var image: UIImage
        var bytes: Int
        var used: UInt64
    }
    private var textRows: [TextRowKey: TextRow] = [:]
    private(set) var textRowBytes = 0
    #if DEBUG
    /// Lab diagnostics: CPU rasterizations, not presented frames.
    private(set) var textRowRasterizations = 0
    var didDrawForTesting: (() -> Void)?
    #endif
    private var textRowUse: UInt64 = 0
    private var textRowConfiguration: TextRowConfiguration?

    private struct TextRowConfiguration: Equatable {
        var size: CGFloat
        var family: TerminalFont
        var scale: CGFloat
        var foreground: RGB
        var background: RGB
    }

    private final class TextRowKey: NSObject {
        let cells: [ScreenCell]
        private let fingerprint: Int
        init(_ cells: [ScreenCell]) {
            self.cells = cells
            fingerprint = cells.hashValue
        }
        override var hash: Int { fingerprint }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? TextRowKey else { return false }
            return fingerprint == other.fingerprint && cells == other.cells
        }
    }
    /// Where the current hold of the space bar's trackpad began (see `ArrowStick`).
    private var stickOrigin: CGPoint?
    /// The arrow key the trackpad points to; nil inside the dead zone.
    private var stickKey: TerminalKey?
    private var stickSpeed: ArrowStick.Speed = .slow
    /// Whether the key repeats yet (it waits `ArrowStick.repeatDelay` after the first).
    private var stickRepeating = false
    private var stickTimer: Timer?
    /// Keys sent during this hold, to move the arrow pad's lit chevrons along.
    private var stickSent = 0
    private lazy var arrowPad = ArrowPadView()
    /// Text an input method is still composing (see `setMarkedText`); typed once it's done.
    fileprivate var markedText: String?
    fileprivate weak var textInputDelegate: UITextInputDelegate?
    fileprivate lazy var stringTokenizer = UITextInputStringTokenizer(textInput: self)
    /// A tiny tap per arrow key, and a firmer one when the direction or speed changes.
    private let keyTap = UIImpactFeedbackGenerator(style: .light)
    private let stageTap = UIImpactFeedbackGenerator(style: .medium)
    /// The link a tap landed on, for the edit menu.
    private var menuLink: URL?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var lastGrid: (cols: Int, rows: Int)?
    // UIKit owns gesture tracking and time-based deceleration. The canvas stays fixed;
    // only a viewport of cells (plus one real overscan row) is ever materialized.
    let scrollView = UIScrollView()
    /// The painted rows (see `TerminalContentView`). A fractional scroll moves them with a layer
    /// transform of `contentClip`: no CPU repaint of unchanged rows, and no UIView geometry change.
    let contentView = TerminalContentView()
    private let contentClip = UIView()
    private let remoteClip = UIView()
    private let remoteContent = TerminalContentView()
    private(set) var remoteRegion: Swift.Range<Int>?
    private(set) var remoteStrip: [[ScreenCell]] = []
    private(set) var remoteOffset: CGFloat = 0
    private var remoteDirection = 0
    private var lastWheelSign = 0
    private var lastWheelTimes: [Int: CFTimeInterval] = [:]
    private var remoteDrain = RemoteScrollDrain()
    private var remoteLink: CADisplayLink?
    private var remoteTickTime: CFTimeInterval = 0
    private let scrollThumb = UIView()
    private(set) var scrollFraction: CGFloat = 0 {
        didSet { if scrollFraction != oldValue { layoutContent() } }
    }
    private var applyingScroll = false
    // History indices can rebase while output prunes. UIKit's in-flight coordinate and
    // velocity stay untouched; this origin maps them to the current terminal history.
    private var historyOrigin: CGFloat = 0
    private var configuredRoute = TerminalScreenModel.ScrollRoute.disabled
    private var configuredGeneration = -1
    private var configuredCellHeight: CGFloat = 0
    private var configuredSize = CGSize.zero
    private var motionGeneration: Int?
    private var remoteRow = 0
    private var remoteCell = (x: 0, y: 0)
    private var suppressTap = false
    private var wasDecelerating = false
    private static let remoteScrollOrigin: CGFloat = 100_000
    private var pinchStartSize: CGFloat = 13
    /// While pinching, the screen as it was, scaled; nothing is re-laid-out until the fingers lift.
    private var pinchSnapshot: UIView?
    private var pinchSize: CGFloat = 13
    private var pinching = false
    /// Whether the screen was live (not scrolled back) when the current pan began.
    private var panStartedLive = true
    private lazy var pinchLabel: UILabel = {
        let label = PaddedLabel()
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.textAlignment = .center
        return label
    }()
    private let ticks = UISelectionFeedbackGenerator()
    private var pan: UIPanGestureRecognizer?
    private var pinch: UIPinchGestureRecognizer?
    /// Off while watching: the screen is shrunk to the other viewer's size, so a new font
    /// size would change nothing visible.
    var pinchEnabled = true {
        didSet { pinch?.isEnabled = pinchEnabled }
    }
    /// Watching: the terminal's size is another viewer's. It's fitted to the view as a whole
    /// (larger or smaller than our font).
    var watching = false {
        didSet {
            if watching != oldValue {
                if remoteOffset != 0 { snapRemoteShift() }
                redrawContent()
            }
        }
    }
    /// For a quick look (the list's long-press preview): the font as set, never shrunk to fit;
    /// what doesn't fit is cut off on the right and above the cursor row.
    var cropped = false {
        didSet {
            if cropped != oldValue {
                if remoteOffset != 0 { snapRemoteShift() }
                redrawContent()
            }
        }
    }
    /// A sideways swipe that starts in our left part, for showing or hiding the lists beside us
    /// (see `onEdgeSwipe`). Not a `UIScreenEdgePanGestureRecognizer`: with the lists showing, our
    /// left edge is the column border, not the screen's, and a thin strip there was hard to hit.
    private lazy var edgeSwipe: UIPanGestureRecognizer = {
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(edgeSwiped(_:)))
        swipe.maximumNumberOfTouches = 1
        swipe.delegate = self
        swipe.isEnabled = false
        return swipe
    }()
    /// How far from our left edge an edge swipe may start: the left third. Sideways swipes do
    /// nothing else here (scrolling is vertical), but the rest stays free for other gestures.
    private var edgeWidth: CGFloat { bounds.width / 3 }
    /// Where the current touch went down, to tell whether it started at the edge.
    private var edgeTouchStart: CGPoint?
    /// Whether the current edge swipe has called `onEdgeSwipe` already.
    private var edgeSwipeFired = false
    /// Set while a swipe from the left edge should do something: called with `true` for a swipe
    /// to the right, `false` for one to the left. The edge then isn't used for scrolling.
    var onEdgeSwipe: ((_ toRight: Bool) -> Void)? {
        didSet { edgeSwipe.isEnabled = onEdgeSwipe != nil }
    }
    static let fontRange: ClosedRange<CGFloat> = 7...28
    static let padding: CGFloat = 10
    private var padding: CGFloat { Self.padding }
    /// How much of our bottom the keyboard (and key bar) covers. We handle the keyboard
    /// ourselves instead of letting SwiftUI animate our frame: an animated frame made the
    /// screen slide down and back up every time the keyboard opened or closed.
    private var keyboardInset: CGFloat = 0

    /// The area cells may use: inside the padding, above the keyboard.
    private var usableRect: CGRect {
        var rect = bounds.insetBy(dx: padding, dy: padding)
        rect.size.height = max(rect.height - keyboardInset, 0)
        return rect
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        clipsToBounds = true
        backgroundColor = UIColor(screen.background)
        // Never scale the drawn screen: when the keyboard or a fold animates our frame,
        // Core Animation would stretch the old bitmap to the new size until the redraw
        // lands, which looks like the font jumping. Pin it to the top-left.
        contentView.canvas = self
        contentView.isOpaque = true
        contentView.contentMode = .topLeft
        contentView.layer.contentsGravity = .topLeft
        contentView.isUserInteractionEnabled = false
        contentClip.isUserInteractionEnabled = false
        contentClip.addSubview(contentView)
        addSubview(contentClip)
        remoteContent.canvas = self
        remoteContent.isRemoteBand = true
        remoteContent.isOpaque = true
        remoteContent.contentMode = .topLeft
        remoteContent.layer.contentsGravity = .topLeft
        remoteContent.isUserInteractionEnabled = false
        remoteClip.isUserInteractionEnabled = false
        remoteClip.clipsToBounds = true
        remoteClip.isHidden = true
        remoteClip.addSubview(remoteContent)
        addSubview(remoteClip)
        scrollThumb.isUserInteractionEnabled = false
        scrollThumb.isHidden = true
        addSubview(scrollThumb)
        // For UI tests and VoiceOver users: the terminal as one element.
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityIdentifier = "terminal-screen"
        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.keyboardDismissMode = .none
        scrollView.delaysContentTouches = false
        scrollView.delegate = self
        addSubview(scrollView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        self.pinch = pinch
        let pan = scrollView.panGestureRecognizer
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(panned))
        self.pan = pan
        addGestureRecognizer(edgeSwipe)
        addInteraction(editMenu)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The keyboard's final frame is known when its animation starts: apply it at once,
    /// without animation, and send the final size straight away (no need to wait for it to settle).
    @objc private func keyboardWillChange(_ note: Notification) {
        var inset: CGFloat = 0
        if note.name != UIResponder.keyboardWillHideNotification,
           let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
           let window
        {
            // The keyboard frame is in screen coordinates; how much of us does it cover?
            let keyboard = convert(window.convert(end, from: window.screen.coordinateSpace), from: window)
            inset = max(0, bounds.intersection(keyboard).height)
        }
        guard inset != keyboardInset else { return }
        cancelScrolling()
        keyboardInset = inset
        synchronizeScrolling()
        redrawContent()
        reportGridSize(force: false, immediately: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        #if DEBUG
        TerminalScrollTrace.shared?.attach(self)
        TerminalScrollTrace.shared?.record("layout")
        #endif
        synchronizeScrolling()
        reportGridSize(force: false)
        // Repaints only when the painted area changes size (`layoutContent`), never per layout pass.
        layoutContent()
    }

    /// UIKit gives a view that draws (the content view) its screen's scale; the canvas itself
    /// no longer draws, so its scale is the content's. Setting it (tests) sets both.
    override var contentScaleFactor: CGFloat {
        get { contentView.contentScaleFactor }
        set {
            super.contentScaleFactor = newValue
            contentView.contentScaleFactor = newValue
            remoteContent.contentScaleFactor = newValue
        }
    }

    private func redrawContent() {
        layoutContent()
        contentView.setNeedsDisplay()
    }

    /// Places the painted rows: a pure fraction moves them, it never repaints them. The rows'
    /// window (and its real overscan row below) is clipped only while history shows one.
    /// The rows' clip keeps its bounds while scrolling: changing them (or a subview layer's
    /// transform) makes UIKit lay out the canvas again on every native callback. The fraction is
    /// the clip layer's `sublayerTransform` instead; the scrollbar's frame origin is harmless.
    private func layoutContent() {
        let g = geometry()
        let window = CGRect(x: 0, y: g.origin.y, width: bounds.width, height: CGFloat(screen.rows) * g.cellHeight)
        let thumb = scrollbarThumb(screen.scrollbar)
        // Keyboard notifications and SwiftUI updates can arrive inside animation blocks.
        UIView.performWithoutAnimation {
            if contentClip.frame != window { contentClip.frame = window }
            let origin = CGPoint(x: 0, y: window.minY)
            if contentClip.bounds.origin != origin { contentClip.bounds.origin = origin }
            if contentClip.clipsToBounds != (screen.lineBelow != nil) { contentClip.clipsToBounds = screen.lineBelow != nil }
            let size = CGSize(width: bounds.width, height: bounds.height + g.cellHeight)
            if contentView.frame != CGRect(origin: .zero, size: size) {
                contentView.frame = CGRect(origin: .zero, size: size)
                contentView.setNeedsDisplay()
            }
            if scrollThumb.isHidden != (thumb == nil || pinchSnapshot != nil) {
                scrollThumb.isHidden = thumb == nil || pinchSnapshot != nil
            }
            if let thumb {
                // Its frame, not a transform: a UIView layer's transform lays out the canvas again.
                if scrollThumb.frame != thumb {
                    scrollThumb.frame = thumb
                    scrollThumb.layer.cornerRadius = thumb.width / 2
                }
                let color = UIColor(screen.foreground).withAlphaComponent(0.45)
                if scrollThumb.backgroundColor != color { scrollThumb.backgroundColor = color }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shift = CATransform3DMakeTranslation(0, -scrollFraction, 0)
        if !CATransform3DEqualToTransform(contentClip.layer.sublayerTransform, shift) {
            contentClip.layer.sublayerTransform = shift
        }
        if let region = remoteRegion {
            let top = g.origin.y + CGFloat(region.lowerBound) * g.cellHeight
            let band = CGRect(x: 0, y: top, width: bounds.width, height: CGFloat(region.count) * g.cellHeight)
            if remoteClip.frame != band { remoteClip.frame = band }
            let leaving = remoteDirection > 0 ? remoteStrip.count - region.count : 0
            let strip = CGRect(x: 0, y: -CGFloat(leaving) * g.cellHeight,
                               width: bounds.width, height: CGFloat(remoteStrip.count) * g.cellHeight)
            if remoteContent.frame != strip { remoteContent.frame = strip }
            remoteClip.layer.sublayerTransform = CATransform3DMakeTranslation(0, remoteOffset, 0)
        }
        CATransaction.commit()
        #if DEBUG
        if presentedFraction != scrollFraction || presentedRow != screen.scrollbar?.offset {
            presentedFraction = scrollFraction
            presentedRow = screen.scrollbar?.offset
            contentMoves += 1
            TerminalScrollTrace.shared?.record("present", state: scrollView.isDecelerating ? 4 : 0,
                offset: CGFloat(screen.scrollbar?.offset ?? 0) * g.cellHeight + scrollFraction, height: g.cellHeight)
        }
        #endif
    }

    #if DEBUG
    private var presentedFraction: CGFloat = 0
    private var presentedRow: Int?
    /// Lab diagnostics: position changes of the painted rows (movement, not CPU drawing).
    private(set) var contentMoves = 0
    /// Lab diagnostics: CPU draws of the painted rows.
    private(set) var contentDraws = 0

    /// The CPU drawing path alone, into the current context (benchmarks, cache labs).
    func drawForTesting(_ rect: CGRect) { drawContent(rect) }

    /// What the screen shows: the composited layers, after any pending paint (all rows again
    /// with `repaint`, e.g. to compare a cache hit with a fresh canvas).
    func renderForTesting(in context: CGContext, repaint: Bool = true) {
        layoutIfNeeded()
        if repaint { contentView.setNeedsDisplay() }
        contentView.layer.displayIfNeeded()
        remoteContent.layer.displayIfNeeded()
        layer.render(in: context)
    }
    #endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelScrolling() }
    }

    private var pendingGridReport: DispatchWorkItem?

    /// Reports how many cells fit. The first report goes out at once (to attach);
    /// later ones wait until the size settles, so a keyboard or fold animation
    /// sends one resize instead of one per frame (each makes the program redraw).
    private func reportGridSize(force: Bool, immediately: Bool = false) {
        let usable = usableRect
        guard usable.width > 0, usable.height > 0 else { return }
        let cols = max(Int(usable.width / fonts.cellWidth), 10)
        let rows = max(Int(usable.height / fonts.cellHeight), 3)
        guard force || lastGrid.map({ $0.cols != cols || $0.rows != rows }) ?? true else { return }
        let first = lastGrid == nil
        lastGrid = (cols, rows)
        let scale = window?.screen.scale ?? traitCollection.displayScale
        model?.cellPixels = (Int((fonts.cellWidth * scale).rounded()), Int((fonts.cellHeight * scale).rounded()))
        pendingGridReport?.cancel()
        if first || immediately {
            onGridSize?(cols, rows)
            return
        }
        let report = DispatchWorkItem { [weak self] in
            guard let self, let grid = self.lastGrid else { return }
            self.onGridSize?(grid.cols, grid.rows)
        }
        pendingGridReport = report
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: report)
    }

    // MARK: Drawing

    private struct Geometry {
        var origin: CGPoint
        var fonts: Fonts
        var cellWidth: CGFloat { fonts.cellWidth }
        var cellHeight: CGFloat { fonts.cellHeight }
    }

    /// Where cells go.
    ///
    /// Too wide (another viewer sets more columns): shrink the font to fit. Too tall
    /// (the keyboard just came up and our resize hasn't landed yet): keep the font,
    /// and shift up only as far as needed to keep the cursor row in view. Changing the
    /// font for a height change made the screen jump while the keyboard animated.
    /// Watching, the whole terminal fits instead: shrunk, or enlarged up to the largest font.
    private func geometry() -> Geometry {
        let usable = usableRect
        var origin = CGPoint(x: padding, y: padding)
        guard screen.cols > 0, screen.rows > 0, usable.width > 0, usable.height > 0 else {
            return Geometry(origin: origin, fonts: fonts)
        }
        var drawFonts = fonts
        var scale = usable.width / (CGFloat(screen.cols) * fonts.cellWidth)
        if watching {
            scale = min(scale, usable.height / (CGFloat(screen.rows) * fonts.cellHeight), Self.fontRange.upperBound / fontSize)
        }
        if cropped {
            scale = 1
        }
        if scale < 1 || (watching && scale > 1) {
            let size = (fontSize * scale * 4).rounded(.down) / 4
            if scaledFonts?.size != size { scaledFonts = Fonts(size: size, family: fontFamily) }
            drawFonts = scaledFonts!
        }
        let visibleRows = Int(usable.height / drawFonts.cellHeight)
        // The cursor's row even when hidden (spinners, coding agents).
        if screen.scrollbar?.atBottom != false, screen.rows > visibleRows,
           let row = screen.cursor?.y ?? screen.cursorRow, row >= visibleRows {
            origin.y -= CGFloat(row - visibleRows + 1) * drawFonts.cellHeight
        }
        // Rows are painted without the scroll fraction; `layoutContent` moves them by it.
        return Geometry(origin: origin, fonts: drawFonts)
    }

    /// The cell under a point, including the real partially visible row below the viewport.
    func cell(at point: CGPoint) -> (x: Int, y: Int) {
        let g = geometry()
        let x = Int((point.x - g.origin.x) / g.cellWidth)
        let y = Int(floor((point.y + scrollFraction - g.origin.y) / g.cellHeight))
        let lastRow = screen.rows - 1 + (scrollFraction > 0 && screen.lineBelow != nil ? 1 : 0)
        return (min(max(x, 0), max(screen.cols - 1, 0)), min(max(y, 0), max(lastRow, 0)))
    }

    private func lineRect(_ y: Int, _ g: Geometry) -> CGRect {
        CGRect(x: 0, y: g.origin.y + CGFloat(y) * g.cellHeight, width: bounds.width, height: g.cellHeight)
            .insetBy(dx: 0, dy: -1)
    }

    /// Redraws only lines whose cells, selection or cursor changed (the scrollbar is a view).
    private func invalidate(from old: ScreenFrame) {
        guard old.cols == screen.cols, old.rows == screen.rows, old.lines.count == screen.lines.count,
              old.background == screen.background, old.foreground == screen.foreground
        else {
            contentView.setNeedsDisplay()
            return
        }
        let g = geometry()
        if old.lineBelow != screen.lineBelow || old.selectionBelow != screen.selectionBelow {
            contentView.setNeedsDisplay(lineRect(screen.rows, g))
        }
        for y in screen.lines.indices
        where old.lines[y] != screen.lines[y]
            || (old.selection.indices.contains(y) ? old.selection[y] : nil)
                != (screen.selection.indices.contains(y) ? screen.selection[y] : nil)
        {
            contentView.setNeedsDisplay(lineRect(y, g))
        }
        if old.cursor != screen.cursor {
            if let y = old.cursor?.y { contentView.setNeedsDisplay(lineRect(y, g)) }
            if let y = screen.cursor?.y { contentView.setNeedsDisplay(lineRect(y, g)) }
        }
    }

    /// Paints rows in content coordinates (the canvas's, before the scroll fraction), including
    /// the real overscan row below whenever history has one, so a fraction never needs it drawn.
    fileprivate func drawContent(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #if DEBUG
        contentDraws += 1
        TerminalScrollTrace.shared?.record("draw-start", state: scrollView.isDecelerating ? 4 : 0,
            offset: CGFloat(screen.scrollbar?.offset ?? 0) * geometry().cellHeight + scrollFraction)
        defer {
            didDrawForTesting?()
            TerminalScrollTrace.shared?.content("draw-content", frame: screen)
            TerminalScrollTrace.shared?.record("draw", offset: CGFloat(screen.scrollbar?.offset ?? 0) * geometry().cellHeight + scrollFraction, height: geometry().cellHeight)
        }
        #endif
        UIColor(screen.background).setFill()
        context.fill(rect)
        // While pinching, the scaled snapshot shows the screen; drawing under it would show at its edges.
        guard pinchSnapshot == nil, screen.cols > 0, !screen.lines.isEmpty else { return }

        let g = geometry()
        context.saveGState()
        let rowCount = screen.lines.count + (screen.lineBelow != nil ? 1 : 0)
        for y in 0..<rowCount {
            let line = y < screen.lines.count ? screen.lines[y] : screen.lineBelow!
            let top = g.origin.y + CGFloat(y) * g.cellHeight
            guard top < rect.maxY, top + g.cellHeight > rect.minY else { continue }
            let selection = y < screen.selection.count ? screen.selection[y] : screen.selectionBelow
            drawRow(line, selection: selection, top: top, geometry: g, in: context)
        }
        if let cursor = screen.cursor, cursor.y < rowCount {
            drawCursor(cursor, origin: g.origin, cellWidth: g.cellWidth, cellHeight: g.cellHeight, fonts: g.fonts, in: context)
        }
        context.restoreGState()
    }

    /// Both the authoritative viewport and retained strip use this painter and text cache.
    private func drawRow(_ line: [ScreenCell], selection: ClosedRange<Int>?, top: CGFloat,
                         geometry g: Geometry, in context: CGContext) {
        drawBackgrounds(line, top: top, origin: g.origin, cellWidth: g.cellWidth, cellHeight: g.cellHeight, in: context)
        if let selected = selection {
            UIColor.tintColor.withAlphaComponent(0.4).setFill()
            context.fill(CGRect(x: g.origin.x + CGFloat(selected.lowerBound) * g.cellWidth, y: top,
                                width: CGFloat(selected.count) * g.cellWidth, height: g.cellHeight))
        }
        drawCachedText(line, top: top, geometry: g)
    }

    fileprivate func drawRemoteBand(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor(screen.background).setFill()
        context.fill(rect)
        let g = geometry()
        for (y, line) in remoteStrip.enumerated() {
            let top = CGFloat(y) * g.cellHeight
            guard top < rect.maxY, top + g.cellHeight > rect.minY else { continue }
            drawRow(line, selection: nil, top: top, geometry: g, in: context)
        }
    }

    private func presentRemoteShift(from old: ScreenFrame) {
        guard configuredRoute == .remote, !watching, !cropped,
              old.cols == screen.cols, old.rows == screen.rows,
              old.lines.count == screen.lines.count,
              old.foreground == screen.foreground, old.background == screen.background
        else { snapRemoteShift(reason: "presentation"); return }
        if let region = remoteRegion {
            let unchanged = region.allSatisfy { y in
                screen.rowLooksEqual(y, to: old, y)
                    && (old.selection.indices.contains(y) ? old.selection[y] : nil)
                        == (screen.selection.indices.contains(y) ? screen.selection[y] : nil)
            }
            let cursorInside = [old.cursor, screen.cursor].contains { $0.map { region.contains($0.y) } ?? false }
            if unchanged && !cursorInside { return }
        }
        let now = CACurrentMediaTime()
        var detected = screen.shift(from: old, wheelSign: lastWheelSign,
                                    wheelAge: now - (lastWheelTimes[lastWheelSign] ?? 0))
        // Replies from before a reversal can still be in flight. Try that input's sign
        // once, under the same age/evidence rules; never predict a response.
        if detected == nil, let previous = lastWheelTimes[-lastWheelSign] {
            detected = screen.shift(from: old, wheelSign: -lastWheelSign, wheelAge: now - previous)
        }
        guard let shift = detected else {
            if let trimmed = remoteBandTrimmedPastChangedEdges(from: old) {
                let leaving = remoteLeavingRows(for: trimmed, rows: 0, direction: remoteDirection, from: old)
                let band = Array(screen.lines[trimmed])
                remoteStrip = remoteDirection > 0 ? leaving + band : band + leaving
                remoteRegion = trimmed
                remoteContent.setNeedsDisplay()
                return
            }
            snapRemoteShift(reason: "unverified-frame")
            return
        }
        let direction = shift.rows > 0 ? 1 : -1
        var target = shift.region
        if let region = remoteRegion {
            let edgeDelta = abs(region.lowerBound - shift.region.lowerBound)
                + abs(region.upperBound - shift.region.upperBound)
            if direction == remoteDirection, shift.region.lowerBound >= region.lowerBound,
               shift.region.upperBound <= region.upperBound, keepsRemoteBand(region, rows: shift.rows, from: old) {
                // Bunched rows can make blank edge rows look unchanged; the established band
                // still follows this shift row by row, so keep it rather than restart.
                target = region
            } else if direction != remoteDirection || edgeDelta > 2 {
                snapRemoteShift(reason: direction != remoteDirection ? "direction-change" : "band-change")
            }
        }
        let height = geometry().cellHeight
        remoteDrain.arrived(rows: shift.rows, cellHeight: height, time: now)
        let offset = remoteOffset + CGFloat(shift.rows) * height
        guard abs(offset) <= CGFloat(min(12, target.count / 2)) * height else {
            snapRemoteShift(reason: "backlog-limit")
            return
        }
        let leaving = remoteLeavingRows(for: target, rows: shift.rows, direction: direction, from: old)
        let band = Array(screen.lines[target])
        remoteStrip = direction > 0 ? leaving + band : band + leaving
        // Retain only rows that can still be exposed by the residual, plus two for a band
        // edge that moves next frame. This bounds memory across a long fling.
        let count = target.count + Int(ceil(abs(offset) / height)) + 2
        if remoteStrip.count > count {
            remoteStrip = direction > 0 ? Array(remoteStrip.suffix(count)) : Array(remoteStrip.prefix(count))
        }
        remoteRegion = target
        remoteDirection = direction
        remoteOffset = offset
        // Rows the strip cannot supply show the terminal background, never the frame below.
        remoteClip.backgroundColor = UIColor(screen.background)
        remoteClip.isHidden = false
        remoteContent.setNeedsDisplay()
        if remoteLink == nil {
            let tick = TerminalRemoteTick()
            tick.fire = { [weak self] link in
                guard let self else { link.invalidate(); return }
                let dt = max(0, link.timestamp - self.remoteTickTime)
                self.remoteTickTime = link.timestamp
                self.advanceRemoteShift(by: dt)
            }
            let link = CADisplayLink(target: tick, selector: #selector(TerminalRemoteTick.step(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            remoteTickTime = CACurrentMediaTime()
            remoteLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    /// The rows leaving the new band, taken from one continuous column: the retained
    /// leaving rows plus the band as it stood in `old`. A row's content position is kept,
    /// so a band edge that moves (Codex's sticky header joining or leaving) never splices
    /// a fixed row into the transcript or leaves a gap. `rows` is this frame's shift.
    private func remoteLeavingRows(for band: Swift.Range<Int>, rows: Int, direction: Int,
                                   from old: ScreenFrame) -> [[ScreenCell]] {
        let region = remoteRegion ?? band
        let retained = remoteRegion == nil ? 0 : max(0, remoteStrip.count - region.count)
        if direction > 0 {
            let column = Array(remoteStrip.prefix(retained)) + Array(old.lines[region])
            let count = retained + band.lowerBound - region.lowerBound + rows
            return Array(column.prefix(min(max(0, count), column.count)))
        }
        let column = Array(old.lines[region]) + Array(remoteStrip.suffix(retained))
        let count = retained + region.upperBound - band.upperBound - rows
        return Array(column.suffix(min(max(0, count), column.count)))
    }

    /// Whether every row of the established band still follows a `rows` shift (entering
    /// rows excepted), with no cursor or selection in it.
    private func keepsRemoteBand(_ region: Swift.Range<Int>, rows: Int, from old: ScreenFrame) -> Bool {
        for y in region where region.contains(y + rows) {
            if !screen.rowLooksEqual(y, to: old, y + rows) { return false }
        }
        for frame in [old, screen] {
            if let cursor = frame.cursor, region.contains(cursor.y) { return false }
            if region.contains(where: { frame.selection.indices.contains($0) && frame.selection[$0] != nil }) { return false }
        }
        return true
    }

    /// A header-only repaint has no translation to detect. Keep only the unchanged
    /// interior: never animate a changed edge row or a cursor/selection in the band.
    private func remoteBandTrimmedPastChangedEdges(from old: ScreenFrame) -> Swift.Range<Int>? {
        guard let region = remoteRegion else { return nil }
        let changed = region.filter { !screen.rowLooksEqual($0, to: old, $0) }
        guard !changed.isEmpty else { return nil }
        let lower = (changed.last { $0 < region.lowerBound + 2 }).map { $0 + 1 } ?? region.lowerBound
        let upper = changed.first { $0 >= region.upperBound - 2 } ?? region.upperBound
        guard upper - lower >= 8,
              lower - region.lowerBound + region.upperBound - upper <= 2 else { return nil }
        let trimmed = lower..<upper
        guard changed.allSatisfy({ !trimmed.contains($0) }) else { return nil }
        for frame in [old, screen] {
            if let cursor = frame.cursor, trimmed.contains(cursor.y) { return nil }
            if trimmed.contains(where: { frame.selection.indices.contains($0) && frame.selection[$0] != nil }) { return nil }
        }
        return trimmed
    }

    /// Transform commits only: no row invalidation or text rasterization during the drain.
    func advanceRemoteShift(by dt: TimeInterval) {
        guard remoteOffset != 0 else { return }
        remoteOffset = remoteDrain.remaining(offset: remoteOffset, cellHeight: geometry().cellHeight,
                                            time: CACurrentMediaTime(), dt: dt)
        if abs(remoteOffset) * max(contentScaleFactor, 1) < 1 { snapRemoteShift(reason: "settled") }
        else { layoutContent() }
    }

    private func snapRemoteShift(reason: String = "cancel") {
        #if DEBUG
        if reason != "settled", configuredRoute == .remote {
            TerminalScrollTrace.shared?.remoteSnap(reason: reason, offset: remoteOffset)
        }
        #endif
        remoteLink?.invalidate()
        remoteLink = nil
        remoteOffset = 0
        remoteRegion = nil
        remoteStrip.removeAll(keepingCapacity: true)
        remoteClip.isHidden = true
        remoteClip.layer.sublayerTransform = CATransform3DIdentity
    }

    /// Inverse-map the displayed band before cancellation. Retained rows beyond the current
    /// frame have no remote target: consume those taps rather than clamping onto fixed chrome.
    private func remoteTapCell(at point: CGPoint) -> (x: Int, y: Int)? {
        let physical = cell(at: point)
        let g = geometry()
        // The unclamped row: padding outside the grid is never part of the moving band.
        let row = Int(floor((point.y - g.origin.y) / g.cellHeight))
        guard let region = remoteRegion, region.contains(row) else { return physical }
        let y = Int(floor((point.y - g.origin.y - remoteOffset) / g.cellHeight))
        guard region.contains(y) else { return nil }
        return (physical.x, y)
    }

    private func drawCachedText(_ line: [ScreenCell], top: CGFloat, geometry g: Geometry) {
        let scale = max(contentScaleFactor, 1)
        let configuration = TextRowConfiguration(size: g.fonts.size, family: g.fonts.family,
            scale: scale, foreground: screen.foreground, background: screen.background)
        if textRowConfiguration != configuration {
            textRows.removeAll(keepingCapacity: true)
            textRowBytes = 0
            textRowConfiguration = configuration
        }
        let key = TextRowKey(line)
        textRowUse &+= 1
        let image: UIImage
        if var cached = textRows[key] {
            cached.used = textRowUse
            textRows[key] = cached
            image = cached.image
        } else {
            #if DEBUG
            textRowRasterizations += 1
            #endif
            // One point of bleed retains italic edges and descenders. The bitmap is transparent
            // so a selection changing underneath it never requires shaping the text again.
            let size = CGSize(width: ceil(CGFloat(line.count) * g.cellWidth) + 2, height: g.cellHeight + 2)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.preferredRange = .standard
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                drawText(line, top: 1, origin: CGPoint(x: 1, y: 0),
                    cellWidth: g.cellWidth, cellHeight: g.cellHeight, fonts: g.fonts)
            }
            if let bitmap = image.cgImage {
                let bytes = bitmap.bytesPerRow * bitmap.height
                // A strict budget and LRU eviction avoid NSCache's advisory limits and bulk
                // purges, which caused measurable frame-time spikes during repeated edits.
                // A 12 MiB budget cannot hold even one 100×60 iPad viewport at @2:
                // sequential LRU eviction then rasterizes every row on every draw. Keep
                // enough for the largest iPad viewport plus a little scroll reuse, bounded
                // both by bytes and row count (never by the terminal's history length).
                let budget = 32 * 1024 * 1024
                if bytes <= budget {
                    // Comic Mono at 7 pt fits 169 rows on a full 13-inch iPad;
                    // the row bound must fit that viewport too, not just its bitmap bytes.
                    while textRowBytes + bytes > budget || textRows.count >= 192 {
                        guard let oldest = textRows.min(by: { $0.value.used < $1.value.used }) else { break }
                        textRowBytes -= oldest.value.bytes
                        textRows.removeValue(forKey: oldest.key)
                    }
                    textRows[key] = TextRow(image: image, bytes: bytes, used: textRowUse)
                    textRowBytes += bytes
                }
            }
        }
        image.draw(at: CGPoint(x: g.origin.x - 1, y: top - 1))
    }

    /// Shown only while scrolled back; the live bottom needs no indicator.
    private func scrollbarThumb(_ bar: Scrollbar?) -> CGRect? {
        guard let bar, !bar.atBottom, bar.total > bar.visible, bar.total > 0 else { return nil }
        // Above the keyboard, like the cells.
        let track = CGRect(x: 0, y: 4, width: bounds.width, height: max(bounds.height - keyboardInset - 8, 0))
        let height = max(track.height * CGFloat(bar.visible) / CGFloat(bar.total), 28)
        let progress = (CGFloat(bar.offset) + scrollFraction / geometry().cellHeight) / CGFloat(bar.total - bar.visible)
        return CGRect(x: bounds.maxX - 6, y: track.minY + (track.height - height) * progress, width: 4, height: height)
    }

    private func colors(_ style: CellStyle) -> (fg: RGB, bg: RGB?) {
        var fg = style.foreground ?? screen.foreground
        var bg = style.background
        if style.inverse {
            let oldBg = bg ?? screen.background
            bg = fg
            fg = oldBg
        }
        return (fg, bg)
    }

    private func drawBackgrounds(
        _ line: [ScreenCell], top: CGFloat, origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat,
        in context: CGContext
    ) {
        var x = 0
        while x < line.count {
            guard let bg = colors(line[x].style).bg else {
                x += 1
                continue
            }
            var end = x + 1
            while end < line.count, colors(line[end].style).bg == bg { end += 1 }
            UIColor(bg).setFill()
            context.fill(pixelAligned(CGRect(
                x: origin.x + CGFloat(x) * cellWidth, y: top,
                width: CGFloat(end - x) * cellWidth, height: cellHeight)))
            x = end
        }
    }

    private func pixelAligned(_ rect: CGRect) -> CGRect {
        let scale = max(contentScaleFactor, 1)
        let x = (rect.minX * scale).rounded() / scale
        let y = (rect.minY * scale).rounded() / scale
        return CGRect(x: x, y: y, width: (rect.maxX * scale).rounded() / scale - x,
            height: (rect.maxY * scale).rounded() / scale - y)
    }

    /// Groups plain single-width cells of one style into runs; wide or complex
    /// graphemes are drawn on their own so the grid stays aligned.
    private func drawText(
        _ line: [ScreenCell], top: CGFloat, origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, fonts: Fonts
    ) {
        var linked = IndexSet()
        for link in LinkDetector.links(in: line) { linked.insert(integersIn: link.columns) }
        for (column, cell) in line.enumerated() where cell.hyperlink { linked.insert(column) }
        var x = 0
        while x < line.count {
            let cell = line[x]
            if cell.width == 0 || cell.text.isEmpty || cell.text == " " || cell.style.invisible {
                x += 1
                continue
            }
            let simple = cell.width == 1 && cell.text.unicodeScalars.count == 1 && cell.text.unicodeScalars.first!.isASCII
            var text = cell.text
            var end = x + 1
            if simple {
                while end < line.count {
                    let next = line[end]
                    guard next.style == cell.style, next.width == 1, linked.contains(end) == linked.contains(x) else {
                        break
                    }
                    if next.text.isEmpty {
                        text += " "
                    } else if next.text.unicodeScalars.count == 1, next.text.unicodeScalars.first!.isASCII {
                        text += next.text
                    } else {
                        break
                    }
                    end += 1
                }
            }
            if !simple, cell.width == 1, cell.text.unicodeScalars.count == 1,
               let dots = Self.braille(cell.text.unicodeScalars.first!)
            {
                let box = CGRect(x: origin.x + CGFloat(x) * cellWidth, y: top, width: cellWidth, height: cellHeight)
                drawBraille(dots, in: box, style: cell.style)
                x = end
                continue
            }
            // One cell wide but emoji-capable (Claude Code's ⏺, ⏸, ☑…): ask for the text form, or
            // iOS falls back to Apple Color Emoji for glyphs the terminal font lacks.
            if !simple, cell.width == 1, let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1,
               scalar.properties.isEmoji, !scalar.isASCII
            {
                text.unicodeScalars.append("\u{FE0E}")
            }
            var style = cell.style
            if linked.contains(x) { style.underline = true }
            drawGlyph(text, style: style, fonts: fonts, box: CGRect(
                x: origin.x + CGFloat(x) * cellWidth, y: top,
                width: CGFloat(max(Int(cell.width), 1)) * cellWidth, height: cellHeight))
            x = end
        }
    }

    /// Private-use symbols must never fall through to an unrelated emoji or spill over the
    /// next cell. Ordinary graphemes keep UIKit's shaping/fallback (CJK, combining, color emoji).
    private func drawGlyph(_ text: String, style: CellStyle, fonts: Fonts, box: CGRect, color: RGB? = nil) {
        guard !style.invisible else { return }
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1,
              scalar.properties.generalCategory == .privateUse,
              let context = UIGraphicsGetCurrentContext()
        else {
            NSAttributedString(string: text, attributes: attributes(style, fonts: fonts, color: color)).draw(at: box.origin)
            return
        }
        let fg = UIColor(color ?? colors(style).fg).withAlphaComponent(style.faint ? 0.6 : 1)
        let box = pixelAligned(box)
        context.saveGState()
        defer {
            context.restoreGState()
            if style.underline || style.strikethrough {
                context.saveGState()
                fg.setFill()
                let thickness = 1 / max(contentScaleFactor, 1)
                if style.underline { context.fill(CGRect(x: box.minX, y: box.maxY - 2, width: box.width, height: thickness)) }
                if style.strikethrough { context.fill(CGRect(x: box.minX, y: box.midY, width: box.width, height: thickness)) }
                context.restoreGState()
            }
        }
        context.clip(to: box)
        fg.setFill()
        fg.setStroke()
        if (0xE0B0...0xE0B3).contains(scalar.value) {
            // Exact cell geometry avoids font-dependent gaps at segment boundaries.
            let right = scalar.value < 0xE0B2
            let edge = right ? box.minX : box.maxX
            let tip = right ? box.maxX : box.minX
            let path = CGMutablePath()
            path.move(to: CGPoint(x: edge, y: box.minY))
            path.addLine(to: CGPoint(x: tip, y: box.midY))
            path.addLine(to: CGPoint(x: edge, y: box.maxY))
            if scalar.value % 2 == 0 {
                path.closeSubpath()
                context.addPath(path)
                context.fillPath()
            } else {
                context.addPath(path)
                context.setLineWidth(max(1 / contentScaleFactor, box.width / 12))
                context.strokePath()
            }
            return
        }
        let font = fonts.symbols
        let ctFont = font as CTFont
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.font: font, .foregroundColor: fg]))
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        // Missing PUA is a quiet empty box, not LastResort text or an emoji. Ask the bundled
        // face directly; CoreText lines can otherwise silently fall back while shaping.
        let utf16 = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(ctFont, utf16, &glyphs, utf16.count),
              ink.width > 0, ink.height > 0 else {
            context.stroke(box.insetBy(dx: box.width * 0.25, dy: box.height * 0.25), width: 1 / contentScaleFactor)
            return
        }
        let fit = min(1, box.width / ink.width, box.height / ink.height)
        let x = box.midX - (ink.midX * fit)
        // Share the selected text face's baseline unless the symbol would leave its cell.
        let baseline = min(max(fonts.regular.ascender, ink.maxY * fit), box.height + ink.minY * fit)
        context.translateBy(x: x, y: box.minY + baseline)
        context.scaleBy(x: fit, y: -fit)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
    }

    /// The dots of a braille pattern (U+2800–U+28FF), nil for anything else.
    private static func braille(_ scalar: Unicode.Scalar) -> UInt8? {
        (0x2800...0x28FF).contains(scalar.value) ? UInt8(scalar.value - 0x2800) : nil
    }

    /// Braille spread over the whole cell, as Ghostty draws it: from the font, the dots sit in
    /// the glyph's box, and graphs (btop) show gaps between rows and columns.
    private func drawBraille(_ dots: UInt8, in box: CGRect, style: CellStyle) {
        guard dots != 0, let context = UIGraphicsGetCurrentContext() else { return }
        var color = UIColor(colors(style).fg)
        if style.faint { color = color.withAlphaComponent(0.6) }
        color.setFill()
        // Bits 0–2 and 6 are the left column top to bottom, 3–5 and 7 the right one.
        let positions: [(column: Int, row: Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        let spacingX = box.width / 2, spacingY = box.height / 4
        let size = max(min(spacingX, spacingY) * 0.6, 1)
        for (bit, position) in positions.enumerated() where dots & (1 << bit) != 0 {
            let center = CGPoint(
                x: box.minX + (CGFloat(position.column) + 0.5) * spacingX,
                y: box.minY + (CGFloat(position.row) + 0.5) * spacingY)
            context.fill(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        }
    }

    private func attributes(_ style: CellStyle, fonts: Fonts, color: RGB? = nil) -> [NSAttributedString.Key: Any] {
        var fg = UIColor(color ?? colors(style).fg)
        if style.faint { fg = fg.withAlphaComponent(0.6) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: fonts.font(bold: style.bold, italic: style.italic),
            .foregroundColor: fg,
        ]
        if style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }

    private func drawCursor(
        _ cursor: ScreenCursor, origin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat, fonts: Fonts,
        in context: CGContext
    ) {
        let line = cursor.y < screen.lines.count ? screen.lines[cursor.y] : screen.lineBelow ?? []
        let cell = line.indices.contains(cursor.x) ? line[cursor.x] : nil
        let width = CGFloat(max(Int(cell?.width ?? 1), 1)) * cellWidth
        let box = CGRect(
            x: origin.x + CGFloat(cursor.x) * cellWidth, y: origin.y + CGFloat(cursor.y) * cellHeight,
            width: width, height: cellHeight)
        let color = UIColor(screen.cursorColor ?? screen.foreground)
        color.setFill()
        color.setStroke()
        let focused = isFirstResponder
        switch cursor.shape {
        case .bar: context.fill(CGRect(x: box.minX, y: box.minY, width: 2, height: box.height))
        case .underline: context.fill(CGRect(x: box.minX, y: box.maxY - 2, width: box.width, height: 2))
        case .hollowBlock: context.stroke(box.insetBy(dx: 0.5, dy: 0.5), width: 1)
        case .block:
            guard focused else {
                context.stroke(box.insetBy(dx: 0.5, dy: 0.5), width: 1)
                return
            }
            context.fill(box)
            if let cell, !cell.text.isEmpty {
                drawGlyph(cell.text, style: cell.style, fonts: fonts, box: box, color: screen.background)
            }
        }
    }

    // MARK: Gestures

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard !suppressTap else { return }
        handleTap(at: tap.location(in: self))
    }

    /// Shared by touch input and focused interaction tests.
    func handleTap(at point: CGPoint) {
        guard !suppressTap, let model else { return }
        let target = remoteTapCell(at: point)
        cancelScrolling(resetFraction: false)
        guard let target else { return }
        editMenu.dismissMenu()
        switch model.tap(at: target) {
        case .link(let url):
            menuLink = url
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        case .unhandled, .handled:
            // Mouse-reporting TUIs still need local text focus after the click. Tapping
            // while watching deliberately takes over, just like Show Keyboard / typing.
            if !isFirstResponder { _ = becomeFirstResponder() }
        }
    }

    /// Starts a hold of the space bar's trackpad at a point.
    private func beginStick(at point: CGPoint) {
        editMenu.dismissMenu()
        stickTimer?.invalidate()
        stickOrigin = point
        stickKey = nil
        stickSent = 0
        stickRepeating = false
        arrowPad.mode = .idle
        arrowPad.dark = darkKeyboard
        let usable = usableRect
        arrowPad.frame.origin = CGPoint(x: usable.maxX - ArrowPadView.size, y: usable.minY)
        addSubview(arrowPad)
        keyTap.prepare()
        stageTap.prepare()
    }

    private func moveStick(to point: CGPoint) {
        guard let origin = stickOrigin else { return }
        guard let reading = ArrowStick.reading(dx: point.x - origin.x, dy: point.y - origin.y, current: stickKey)
        else {
            // Back in the dead zone: stop.
            stickTimer?.invalidate()
            stickKey = nil
            stickRepeating = false
            arrowPad.mode = .idle
            return
        }
        if reading.key != stickKey {
            stickKey = reading.key
            stickSpeed = reading.speed
            stickRepeating = false
            stageTap.impactOccurred(intensity: 0.8)
            sendStickKey(tap: false)
            stickTimer?.invalidate()
            stickTimer = Timer.scheduledTimer(withTimeInterval: ArrowStick.repeatDelay, repeats: false) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stickRepeating = true
                    self?.repeatStick()
                }
            }
        } else if reading.speed != stickSpeed {
            stickSpeed = reading.speed
            stageTap.impactOccurred(intensity: 0.8)
            if stickRepeating { repeatStick() } else { updateArrowPad() }
        }
    }

    /// Sends the key now and then again at the current speed's pace.
    private func repeatStick() {
        sendStickKey()
        stickTimer?.invalidate()
        stickTimer = Timer.scheduledTimer(withTimeInterval: ArrowStick.interval(stickSpeed), repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.sendStickKey() }
        }
    }

    private func sendStickKey(tap: Bool = true) {
        guard let key = stickKey, let model else { return }
        model.press(key)
        if tap { keyTap.impactOccurred(intensity: 0.6) }
        stickSent += 1
        updateArrowPad()
    }

    private func updateArrowPad() {
        guard let key = stickKey else { return arrowPad.mode = .idle }
        arrowPad.mode =
            stickRepeating ? .repeating(key, stickSpeed, step: stickSent) : .press(key)
    }

    private func endStick() {
        stickTimer?.invalidate()
        stickTimer = nil
        stickOrigin = nil
        stickKey = nil
        stickRepeating = false
        arrowPad.removeFromSuperview()
    }

    /// Zooms in two steps, so pinching stays smooth: while the fingers move, only a snapshot of
    /// the screen scales (no new fonts, no redraw, no resize, no reflow of the scrollback); when
    /// they lift, the font changes once and one resize goes out.
    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            cancelScrolling()
            pinching = true
            pinchStartSize = fontSize
            pinchSize = fontSize
            // A pinch often starts as a one-finger pan: undo the scrolling it did, and stop it.
            if let pan, pan.state == .began || pan.state == .changed {
                if panStartedLive { model?.scroll(toBottom: true) }
                pan.isEnabled = false
                pan.isEnabled = true
            }
            addSubview(pinchLabel)
            ticks.prepare()
            updatePinch(size: fontSize)
            guard let snapshot = snapshotView(afterScreenUpdates: false) else { return }
            snapshot.frame = bounds
            // Scale from where text starts, so the snapshot lines up with the result.
            snapshot.layer.anchorPoint = CGPoint(x: padding / max(bounds.width, 1), y: padding / max(bounds.height, 1))
            snapshot.layer.position = CGPoint(x: padding, y: padding)
            insertSubview(snapshot, belowSubview: pinchLabel)
            pinchSnapshot = snapshot
            redrawContent()
        case .changed:
            guard pinching else { return }
            let raw = pinchStartSize * pinch.scale
            let size = min(max(raw, Self.fontRange.lowerBound), Self.fontRange.upperBound)
            pinchSnapshot?.transform = CGAffineTransform(scaleX: size / pinchStartSize, y: size / pinchStartSize)
            let step = (size * 2).rounded() / 2
            if step != pinchSize {
                if step.rounded() == step || step == Self.fontRange.lowerBound || step == Self.fontRange.upperBound {
                    ticks.selectionChanged()
                }
                updatePinch(size: step)
            }
        case .ended:
            finishPinch(apply: true)
        default:
            finishPinch(apply: false)
        }
    }

    /// The size the pinch would land on, and how many cells that gives.
    private func updatePinch(size: CGFloat) {
        pinchSize = size
        let preview = Fonts(size: size, family: fontFamily)
        let usable = usableRect
        let cols = max(Int(usable.width / preview.cellWidth), 10)
        let rows = max(Int(usable.height / preview.cellHeight), 3)
        let pointText = size.rounded() == size ? "\(Int(size))" : String(format: "%.1f", size)
        pinchLabel.text = "\(pointText) pt · \(cols) × \(rows)"
        pinchLabel.sizeToFit()
        pinchLabel.center = CGPoint(x: bounds.midX, y: usable.minY + 40)
    }

    private func finishPinch(apply: Bool) {
        guard pinching else { return }
        pinching = false
        let snapshot = pinchSnapshot
        pinchSnapshot = nil
        pinchLabel.removeFromSuperview()
        if apply, pinchSize != fontSize {
            fontSize = pinchSize
            onFontSize?(pinchSize)
        }
        redrawContent()
        guard let snapshot else { return }
        // Let the real screen draw underneath, then fade the snapshot away.
        UIView.animate(withDuration: 0.18, delay: 0.05, options: [.curveEaseOut]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
    }

    /// Fires once the finger has come far enough in, so the sidebar follows the swipe.
    @objc private func edgeSwiped(_ swipe: UIPanGestureRecognizer) {
        switch swipe.state {
        case .began:
            edgeSwipeFired = false
        case .changed, .ended:
            let x = swipe.translation(in: self).x
            let flick = swipe.state == .ended ? swipe.velocity(in: self).x : 0
            if !edgeSwipeFired, abs(x) > 40 || abs(flick) > 300 {
                edgeSwipeFired = true
                onEdgeSwipe?(abs(x) > 40 ? x > 0 : flick > 0)
            }
        default:
            break
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began {
            panStartedLive = !(model?.scrolledBack ?? false)
            remoteCell = cell(at: pan.location(in: self))
        }
        if pan.state == .changed { remoteCell = cell(at: pan.location(in: self)) }
        #if DEBUG
        TerminalScrollTrace.shared?.record("pan", state: pan.state.rawValue, touch: pan.location(in: window).y,
                                           offset: scrollView.contentOffset.y, height: geometry().cellHeight)
        #endif
    }

    /// Also called when SwiftUI removes this view. Stops native motion before changing its
    /// model, grid, font, route or channel; programmatic synchronization must never emit input.
    func cancelScrolling(resetFraction: Bool = true) {
        #if DEBUG
        TerminalScrollTrace.shared?.record("cancel", state: scrollView.isDecelerating ? 4 : 0, offset: scrollView.contentOffset.y)
        #endif
        snapRemoteShift()
        lastWheelSign = 0
        lastWheelTimes.removeAll(keepingCapacity: true)
        remoteDrain = RemoteScrollDrain()
        motionGeneration = nil
        model?.setScrollActive(false)
        wasDecelerating = false
        let applying = applyingScroll
        applyingScroll = true
        scrollView.stopScrollingAndZooming()
        applyingScroll = applying
        if resetFraction { scrollFraction = 0 }
        if historyOrigin != 0 { synchronizeScrolling() }
    }

    /// A touch that arrests inertia is consumed, before it can click or take over.
    func prepareForTouch() {
        suppressTap = wasDecelerating || scrollView.isDecelerating
        if suppressTap { cancelScrolling(resetFraction: false) }
    }

    private func synchronizeScrolling() {
        guard !applyingScroll else { return }
        applyingScroll = true
        defer { applyingScroll = false }
        let route = cropped ? .disabled : model?.scrollRoute ?? .disabled
        let generation = model?.scrollGeneration ?? -1
        let height = geometry().cellHeight
        let size = CGSize(width: bounds.width, height: max(0, bounds.height - keyboardInset))
        let changed = route != configuredRoute || generation != configuredGeneration
            || height != configuredCellHeight || size != configuredSize
        if changed { cancelScrolling() }
        configuredRoute = route
        configuredGeneration = generation
        configuredCellHeight = height
        configuredSize = size
        #if DEBUG
        TerminalScrollTrace.shared?.record("sync-start", state: scrollView.isDecelerating ? 4 : 0,
            touch: changed ? 1 : 0, offset: scrollView.contentOffset.y, height: CGFloat(screen.scrollbar?.offset ?? 0))
        #endif
        scrollView.frame = CGRect(origin: .zero, size: size)
        scrollView.isScrollEnabled = route != .disabled && !pinching
        var offset: CGFloat = 0
        var extent: CGFloat = 0
        switch route {
        case .history:
            if let bar = screen.scrollbar {
                extent = CGFloat(max(0, bar.total - bar.visible)) * height
                if screen.lineBelow == nil { scrollFraction = 0 }
                offset = min(extent, CGFloat(bar.offset) * height + scrollFraction)
                if !changed, motionGeneration != nil {
                    let native = scrollView.contentOffset.y
                    let row = Int(floor((native + historyOrigin) / height))
                    historyOrigin += CGFloat(bar.offset - row) * height
                    offset = native
                    extent -= historyOrigin
                } else {
                    let position = scrollView.contentOffset.y + historyOrigin
                    historyOrigin = 0
                    // Canonicalize the raw coordinate, never the rounded draw fraction:
                    // a fraction rounded up to one row must not advance the next gesture.
                    if !changed, Int(floor(position / height)) == bar.offset {
                        offset = position
                    }
                }
            }
        case .remote:
            historyOrigin = 0
            extent = Self.remoteScrollOrigin * 2
            offset = changed ? Self.remoteScrollOrigin : scrollView.contentOffset.y
        case .disabled: historyOrigin = 0
        }
        #if DEBUG
        TerminalScrollTrace.shared?.record("history-origin", state: scrollView.isDecelerating ? 4 : 0,
            offset: historyOrigin, height: extent)
        #endif
        // Adjust both real bounds in the native coordinate system. On pruning the
        // extent stays continuous instead of contentSize clamping an in-flight offset.
        if scrollView.contentInset.top != historyOrigin { scrollView.contentInset.top = historyOrigin }
        #if DEBUG
        TerminalScrollTrace.shared?.record("sync-size", state: scrollView.isDecelerating ? 4 : 0,
            touch: scrollView.contentSize.height, offset: scrollView.contentOffset.y, height: size.height + extent)
        #endif
        let contentSize = CGSize(width: size.width, height: size.height + extent)
        if scrollView.contentSize != contentSize { scrollView.contentSize = contentSize }
        if scrollView.contentOffset.y != offset {
            #if DEBUG
            TerminalScrollTrace.shared?.record("sync-offset", state: scrollView.isDecelerating ? 4 : 0,
                touch: scrollView.contentOffset.y, offset: offset)
            #endif
            scrollView.contentOffset = CGPoint(x: 0, y: offset)
        }
        #if DEBUG
        TerminalScrollTrace.shared?.record("sync-end", state: scrollView.isDecelerating ? 4 : 0, offset: scrollView.contentOffset.y)
        #endif
        if route == .remote { remoteRow = Int(floor(offset / height)) }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            model?.wantsKeyboard = true
            model?.focusChanged(true)
            contentView.setNeedsDisplay()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            model?.wantsKeyboard = false
            model?.focusChanged(false)
            contentView.setNeedsDisplay()
        }
        return resigned
    }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // Picking a candidate in an input method ends the marked text with the text it chose.
        markedText = nil
        model?.type(text)
    }

    func deleteBackward() {
        model?.press(.backspace)
    }

    // No autocorrect, capitals or smart punctuation in a terminal.
    var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
    var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
    var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
    var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
    var smartDashesType: UITextSmartDashesType { get { .no } set {} }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }
    var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
    /// Follows the terminal theme's brightness.
    var darkKeyboard = true {
        didSet {
            guard darkKeyboard != oldValue else { return }
            if isFirstResponder { reloadInputViews() }
        }
    }
    var keyboardAppearance: UIKeyboardAppearance { get { darkKeyboard ? .dark : .light } set {} }
    var returnKeyType: UIReturnKeyType { get { .default } set {} }

    private lazy var keyBar = KeyBar(target: self)
    override var inputAccessoryView: UIView? { keyBar }

    /// Hardware keyboard: special keys and Ctrl/Alt combinations go through the encoder;
    /// plain typing falls through to `insertText`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let model, handle(key, model: model) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    private func handle(_ key: UIKey, model: TerminalScreenModel) -> Bool {
        var modifiers: KeyModifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.alt) }
        // Command shortcuts belong to iOS (paste, app switching).
        if key.modifierFlags.contains(.command) { return false }

        if let special = Self.specialKeys[key.keyCode] {
            model.press(special, modifiers: modifiers)
            return true
        }
        if modifiers.contains(.control) || modifiers.contains(.alt) {
            let base = key.charactersIgnoringModifiers
            if base.count == 1, let c = base.first {
                if c.isLetter {
                    model.press(.letter(c), modifiers: modifiers, text: modifiers.contains(.alt) ? base : nil)
                    return true
                }
                if let digit = c.wholeNumberValue {
                    model.press(.digit(digit), modifiers: modifiers)
                    return true
                }
            }
        }
        return false
    }

    private static let specialKeys: [UIKeyboardHIDUsage: TerminalKey] = {
        var keys: [UIKeyboardHIDUsage: TerminalKey] = [
            .keyboardReturnOrEnter: .enter, .keypadEnter: .enter, .keyboardTab: .tab,
            .keyboardDeleteOrBackspace: .backspace, .keyboardEscape: .escape,
            .keyboardDeleteForward: .delete, .keyboardInsert: .insert,
            .keyboardUpArrow: .up, .keyboardDownArrow: .down,
            .keyboardLeftArrow: .left, .keyboardRightArrow: .right,
            .keyboardHome: .home, .keyboardEnd: .end,
            .keyboardPageUp: .pageUp, .keyboardPageDown: .pageDown,
        ]
        let functionKeys: [UIKeyboardHIDUsage] = [
            .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
            .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12,
        ]
        for (index, usage) in functionKeys.enumerated() { keys[usage] = .function(index + 1) }
        return keys
    }()

    // MARK: Paste

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { model?.paste(text) }
    }

    // Key bar actions.
    func keyBarPressed(_ key: TerminalKey, modifiers: KeyModifiers = []) {
        model?.press(key, modifiers: modifiers)
    }

    func keyBarToggleControl() {
        model?.controlLatched.toggle()
        keyBar.controlOn = model?.controlLatched ?? false
    }

    func refreshKeyBar() {
        keyBar.controlOn = model?.controlLatched ?? false
    }
}

extension TerminalCanvasView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if let url = menuLink {
            menuLink = nil
            var actions: [UIMenuElement] = []
            if ["http", "https"].contains(url.scheme?.lowercased()) {
                actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { _ in
                    UIApplication.shared.open(url)
                })
            }
            actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = url
            })
            return UIMenu(title: url.absoluteString, children: actions)
        }
        // No link: UIKit presents the menu itself on a pointer's secondary click.
        guard UIPasteboard.general.hasStrings else { return nil }
        return UIMenu(children: [
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                if let text = UIPasteboard.general.string { self?.model?.paste(text) }
            },
        ])
    }
}

/// The terminal fonts to choose from in Settings.
enum TerminalFont: String, CaseIterable, Identifiable {
    /// Bundled in `hirte/Fonts` (SIL OFL 1.1).
    case jetBrainsMono
    /// The system's monospaced font.
    case sfMono
    case menlo
    /// Bundled (MIT); regular and bold only, so italic text shows upright.
    case comicMono

    var id: Self { self }

    var title: String {
        switch self {
        case .jetBrainsMono: "JetBrains Mono"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .comicMono: "Comic Mono"
        }
    }

    /// PostScript names: regular, bold, italic, bold italic. Nil: the system font.
    fileprivate var names: [String?] {
        switch self {
        case .jetBrainsMono: ["JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic", "JetBrainsMono-BoldItalic"]
        case .sfMono: [nil, nil, nil, nil]
        case .menlo: ["Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"]
        case .comicMono: ["ComicMono", "ComicMono-Bold", nil, nil]
        }
    }

    static let storageKey = "terminal.font"
    static let sizeKey = "terminal.fontSize"
    static let defaultSize = 13.0
}

/// Monospaced fonts and the cell size they imply.
struct Fonts {
    let size: CGFloat
    let family: TerminalFont
    let regular: UIFont
    let bold: UIFont
    let italic: UIFont
    let boldItalic: UIFont
    let symbols: UIFont
    let cellWidth: CGFloat
    let cellHeight: CGFloat

    init(size: CGFloat, family: TerminalFont = .jetBrainsMono) {
        self.size = size
        self.family = family
        let names = family.names
        let base = names[0].flatMap { Self.mono($0, size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let symbols = Self.mono("SymbolsNFM", size) ?? base
        self.symbols = symbols
        func cascade(_ font: UIFont) -> UIFont {
            UIFont(descriptor: font.fontDescriptor.addingAttributes([.cascadeList: [symbols.fontDescriptor]]), size: size)
        }
        regular = cascade(base)
        bold = cascade(names[1].flatMap { Self.mono($0, size) } ?? .monospacedSystemFont(ofSize: size, weight: .bold))
        func italicized(_ font: UIFont) -> UIFont {
            font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic))
                .map { UIFont(descriptor: $0, size: size) } ?? font
        }
        italic = cascade(names[2].flatMap { Self.mono($0, size) } ?? italicized(regular))
        boldItalic = cascade(names[3].flatMap { Self.mono($0, size) } ?? italicized(bold))
        cellWidth = ("M" as NSString).size(withAttributes: [.font: regular]).width
        cellHeight = ceil(regular.lineHeight)
    }

    /// A named font (registering the bundled ones first); nil if it isn't available.
    static func mono(_ name: String, _ size: CGFloat) -> UIFont? {
        _ = registered
        return UIFont(name: name, size: size)
    }

    /// Registers the bundled fonts once, without listing them in Info.plist.
    private static let registered: Bool = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }()

    func font(bold isBold: Bool, italic isItalic: Bool) -> UIFont {
        switch (isBold, isItalic) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): regular
        }
    }
}

extension UIColor {
    convenience init(_ rgb: RGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

/// Keys a phone keyboard lacks, shown above it.
final class KeyBar: UIInputView {
    private weak var target: TerminalCanvasView?
    private var controlButton: UIButton!

    var controlOn = false {
        didSet { controlButton.isSelected = controlOn }
    }

    init(target: TerminalCanvasView) {
        self.target = target
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(equalToConstant: 48),
        ])

        func button(_ title: String, symbol: String? = nil, label: String, action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .medium
            // Eleven keys share the width: small insets, and one line ("ctrl" must not wrap).
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
            config.titleLineBreakMode = .byClipping
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = Fonts.mono("JetBrainsMono-Bold", 14) ?? .monospacedSystemFont(ofSize: 14, weight: .medium)
                return attributes
            }
            if let symbol {
                config.image = UIImage(systemName: symbol)
            } else {
                config.title = title
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            button.accessibilityLabel = label
            return button
        }

        stack.addArrangedSubview(button("esc", label: "Escape") { [weak self] in self?.target?.keyBarPressed(.escape) })
        stack.addArrangedSubview(button("tab", label: "Tab") { [weak self] in self?.target?.keyBarPressed(.tab) })
        controlButton = button("ctrl", label: "Control") { [weak self] in self?.target?.keyBarToggleControl() }
        controlButton.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseBackgroundColor = button.isSelected ? .tintColor : nil
            config?.baseForegroundColor = button.isSelected ? .white : nil
            button.configuration = config
        }
        stack.addArrangedSubview(controlButton)
        stack.addArrangedSubview(button("^C", label: "Control C") { [weak self] in
            self?.target?.keyBarPressed(.letter("c"), modifiers: .control)
        })
        for (symbol, key, label) in [
            ("arrow.left", TerminalKey.left, "Left"), ("arrow.down", .down, "Down"),
            ("arrow.up", .up, "Up"), ("arrow.right", .right, "Right"),
        ] {
            stack.addArrangedSubview(button("", symbol: symbol, label: label) { [weak self] in
                self?.target?.keyBarPressed(key)
            })
        }
        stack.addArrangedSubview(button("", symbol: "keyboard.chevron.compact.down", label: "Hide keyboard") {
            [weak self] in _ = self?.target?.resignFirstResponder()
        })
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// SwiftUI wrapper.
struct TerminalCanvas: UIViewRepresentable {
    let model: TerminalScreenModel
    @Binding var fontSize: Double
    var fontFamily: TerminalFont = .jetBrainsMono
    var dark = true
    /// What a swipe in from the left edge does, if anything.
    var onEdgeSwipe: ((_ toRight: Bool) -> Void)?
    /// A quick look: see `TerminalCanvasView.cropped`.
    var cropped = false
    let onGridSize: (Int, Int) -> Void

    func makeUIView(context: Context) -> TerminalCanvasView {
        let view = TerminalCanvasView()
        view.model = model
        view.fontFamily = fontFamily
        view.fontSize = fontSize
        view.darkKeyboard = dark
        view.onGridSize = onGridSize
        view.onEdgeSwipe = onEdgeSwipe
        view.onFontSize = { fontSize = Double($0) }
        // The model's screen from the first frame (already in the theme's colors while attaching).
        view.screen = model.frame
        return view
    }

    static func dismantleUIView(_ view: TerminalCanvasView, coordinator: ()) {
        view.cancelScrolling()
    }

    func updateUIView(_ view: TerminalCanvasView, context: Context) {
        view.model = model
        view.fontFamily = fontFamily
        view.fontSize = fontSize
        view.darkKeyboard = dark
        view.onGridSize = onGridSize
        view.onEdgeSwipe = onEdgeSwipe
        view.pinchEnabled = !model.watching && !cropped
        view.watching = model.watching && !cropped
        view.cropped = cropped
        view.screen = model.frame
        view.refreshKeyBar()
        // The toolbar's keyboard button flips this; follow it once the view is on screen.
        if model.wantsKeyboard != view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async {
                if model.wantsKeyboard { _ = view.becomeFirstResponder() } else { _ = view.resignFirstResponder() }
            }
        }
    }
}

/// The canvas's painted rows, in a clipping view below its scroll view. It takes no touches:
/// the canvas and its scroll view keep every gesture and the text input.
final class TerminalContentView: UIView {
    fileprivate weak var canvas: TerminalCanvasView?
    fileprivate var isRemoteBand = false

    override func draw(_ rect: CGRect) {
        if isRemoteBand { canvas?.drawRemoteBand(rect) }
        else { canvas?.drawContent(rect) }
    }
}

/// A label with room around its text, for the zoom indicator.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = super.sizeThatFits(size)
        return CGSize(width: fit.width + insets.left + insets.right, height: fit.height + insets.top + insets.bottom)
    }
}

extension TerminalCanvasView: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard let model, model.scrollRoute == configuredRoute, !pinching else {
            cancelScrolling()
            return
        }
        wasDecelerating = false
        if configuredRoute == .remote {
            applyingScroll = true
            scrollView.contentOffset.y = Self.remoteScrollOrigin
            remoteRow = Int(floor(Self.remoteScrollOrigin / geometry().cellHeight))
            remoteDrain.begin(at: scrollView.contentOffset.y, time: CACurrentMediaTime())
            applyingScroll = false
        }
        motionGeneration = model.scrollGeneration
        model.setScrollActive(true)
        remoteCell = cell(at: scrollView.panGestureRecognizer.location(in: self))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        #if DEBUG
        TerminalScrollTrace.shared?.record(applyingScroll ? "native-suppressed" : "native", state: scrollView.isDecelerating ? 4 : 2,
                                           offset: scrollView.contentOffset.y)
        #endif
        guard !applyingScroll else { return }
        guard let model, motionGeneration == model.scrollGeneration,
              model.scrollRoute == configuredRoute, !pinching else {
            cancelScrolling(resetFraction: false)
            synchronizeScrolling()
            return
        }
        let height = geometry().cellHeight
        var offset = scrollView.contentOffset.y
        if configuredRoute == .history { offset += historyOrigin }
        if configuredRoute == .history, let bar = screen.scrollbar {
            offset = min(max(offset, 0), CGFloat(max(0, bar.total - bar.visible)) * height)
        }
        let row = Int(floor(offset / height))
        #if DEBUG
        TerminalScrollTrace.shared?.record("scroll-input", state: scrollView.isDecelerating ? 4 : 2,
                                           touch: scrollView.panGestureRecognizer.location(in: window).y,
                                           offset: offset, height: height)
        #endif
        applyingScroll = true
        let previousOrigin = historyOrigin
        switch configuredRoute {
        case .history:
            let frame = model.scrollHistory(by: row - (screen.scrollbar?.offset ?? row))
            let fraction = ((offset - CGFloat(row) * height) * contentScaleFactor).rounded() / contentScaleFactor
            scrollFraction = frame.lineBelow == nil ? 0 : max(0, fraction)
            // Output can rebase the VT between its write and the scheduled snapshot.
            // Keep that origin shift out of UIKit's native motion, including subpixels.
            historyOrigin += CGFloat((frame.scrollbar?.offset ?? row) - row) * height
            // Changed rows repaint through `invalidate(from:)`; a fraction alone only moves them.
            screen = frame
        case .remote:
            remoteDrain.moved(to: offset, time: CACurrentMediaTime())
            let lines = row - remoteRow
            remoteRow = row
            if lines != 0 {
                lastWheelSign = lines > 0 ? 1 : -1
                lastWheelTimes[lastWheelSign] = CACurrentMediaTime()
                model.scroll(lines: lines, column: remoteCell.x, row: remoteCell.y)
            }
        case .disabled: break
        }
        applyingScroll = false
        if historyOrigin != previousOrigin { synchronizeScrolling() }
        #if DEBUG
        TerminalScrollTrace.shared?.record("offset", state: scrollView.isDecelerating ? 4 : 2,
                                           touch: scrollView.panGestureRecognizer.location(in: window).y,
                                           offset: offset, height: height)
        #endif
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        #if DEBUG
        TerminalScrollTrace.shared?.record("release", state: decelerate ? 4 : 0, offset: scrollView.contentOffset.y)
        #endif
        wasDecelerating = decelerate
        if !decelerate {
            remoteDrain.stop()
            motionGeneration = nil
            model?.setScrollActive(false)
            synchronizeScrolling()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        #if DEBUG
        TerminalScrollTrace.shared?.record("stop", offset: scrollView.contentOffset.y)
        #endif
        wasDecelerating = false
        remoteDrain.stop()
        motionGeneration = nil
        model?.setScrollActive(false)
        synchronizeScrolling()
    }
}

extension TerminalCanvasView: UIGestureRecognizerDelegate {
    /// A pinch may start while a one-finger pan runs (the second finger lands a moment later);
    /// otherwise the pan wins and the pinch never begins. The pinch then cancels the pan.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && other === pan)
            || (gestureRecognizer === pan && other is UIPinchGestureRecognizer)
    }

    /// While the edge swipe is on, a touch at the left edge is its first; anywhere else it fails
    /// at once, and scrolling goes on as before.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === edgeSwipe && other === pan && edgeSwipe.isEnabled
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === edgeSwipe { edgeTouchStart = touch.location(in: self) }
        if gestureRecognizer is UITapGestureRecognizer {
            prepareForTouch()
        }
        return true
    }

    /// An edge swipe starts in the left part and goes clearly sideways; anything else fails it at
    /// once, so scrolling begins as usual.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === edgeSwipe, let swipe = gestureRecognizer as? UIPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        let velocity = swipe.velocity(in: self)
        return (edgeTouchStart?.x ?? .infinity) <= edgeWidth && abs(velocity.x) > 1.5 * abs(velocity.y)
    }
}

// MARK: Text input

/// Just enough of `UITextInput` for the system keyboard. There is no text to edit here (it goes
/// straight to the program), so the document is made up: one character before the cursor, then
/// whatever an input method is composing.
///
/// The character is for the delete key: before repeating a held delete, the keyboard reads the
/// text before the cursor, and stops when there's none. It's also what the trackpad needs: holding
/// the space bar moves a "floating cursor", which becomes arrow keys like a held finger (see
/// `ArrowStick`).
extension TerminalCanvasView {
    private final class Position: UITextPosition {
        let offset: Int
        init(_ offset: Int) { self.offset = offset }
    }

    private final class Range: UITextRange {
        let from: Position, to: Position
        init(_ from: Int, _ to: Int) {
            self.from = Position(min(from, to))
            self.to = Position(max(from, to))
        }
        override var start: UITextPosition { from }
        override var end: UITextPosition { to }
        override var isEmpty: Bool { from.offset == to.offset }
    }

    /// Always there before the cursor, so a held delete key keeps repeating.
    private static let beforeCursor = " "

    private var document: NSString { (Self.beforeCursor + (markedText ?? "")) as NSString }
    private var cursor: Int { document.length }
    private func offset(_ position: UITextPosition) -> Int { (position as? Position)?.offset ?? cursor }

    func beginFloatingCursor(at point: CGPoint) {
        guard model != nil else { return }
        beginStick(at: point)
    }

    func updateFloatingCursor(at point: CGPoint) {
        moveStick(to: point)
    }

    func endFloatingCursor() {
        endStick()
    }

    var selectedTextRange: UITextRange? {
        get { Range(cursor, cursor) }
        set {}
    }

    var markedTextRange: UITextRange? {
        markedText == nil ? nil : Range((Self.beforeCursor as NSString).length, cursor)
    }
    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    /// Input methods (Japanese, Chinese, …) compose text before committing it; we can't show it
    /// in the terminal, so it goes out when they're done.
    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        self.markedText = markedText
    }

    func unmarkText() {
        guard let text = markedText else { return }
        markedText = nil
        if !text.isEmpty { model?.type(text) }
    }

    var inputDelegate: UITextInputDelegate? {
        get { textInputDelegate }
        set { textInputDelegate = newValue }
    }

    var tokenizer: UITextInputTokenizer { stringTokenizer }

    var beginningOfDocument: UITextPosition { Position(0) }
    var endOfDocument: UITextPosition { Position(cursor) }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? Range else { return nil }
        return document.substring(with: NSRange(location: range.from.offset, length: range.to.offset - range.from.offset))
    }

    func replace(_ range: UITextRange, withText text: String) { insertText(text) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        Range(offset(fromPosition), offset(toPosition))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        let moved = self.offset(position) + offset
        return (0...cursor).contains(moved) ? Position(moved) : nil
    }

    func position(
        from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
    ) -> UITextPosition? {
        switch direction {
        case .left: self.position(from: position, offset: -offset)
        case .right: self.position(from: position, offset: offset)
        default: offset == 0 ? position : nil
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let (a, b) = (offset(position), offset(other))
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int { offset(toPosition) - offset(from) }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        let at = offset(position)
        return direction == .left || direction == .up ? Range(max(at - 1, 0), at) : Range(at, min(at + 1, cursor))
    }

    func baseWritingDirection(
        for position: UITextPosition, in direction: UITextStorageDirection
    ) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// The middle of the screen: the trackpad's floating cursor starts here, with room to move
    /// every way.
    func caretRect(for position: UITextPosition) -> CGRect {
        let usable = usableRect
        return CGRect(x: usable.midX, y: usable.midY - 8, width: 2, height: 16)
    }

    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: range.start) }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { Position(cursor) }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { Range(cursor, cursor) }
}

/// The display link retains its target, which only weakly captures the canvas.
private final class TerminalRemoteTick: NSObject {
    var fire: ((CADisplayLink) -> Void)?
    @objc func step(_ link: CADisplayLink) { fire?(link) }
}
