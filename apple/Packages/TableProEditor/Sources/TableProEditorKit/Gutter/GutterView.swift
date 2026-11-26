//
//  GutterView.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 8/22/23.
//

import AppKit
import TableProTextEngine
import TableProTextEngineObjC

public protocol GutterViewDelegate: AnyObject {
    func gutterViewWidthDidUpdate()
}

/// The gutter view displays line numbers that match the text view's line indexes.
/// This view floats over the leading edge of the scroll view, so text scrolls underneath it when line wrapping is
/// disabled. Its width is reserved on the clip view's content insets (see ``SourceEditorScrollView``), which is what
/// keeps the start of each line, and a caret revealed there, clear of it.
///
/// If the gutter needs a different width (when the number of digits in the numbers changes eg. adding a line after
/// line 99), it will notify it's delegate via the ``GutterViewDelegate/gutterViewWidthDidUpdate()`` method. In
/// `SourceEditor`, this notifies the ``TextViewController``, which in turn updates the width the scroll view reserves.
///
/// This view also listens for selection updates, and draws a selected background on selected lines to keep the illusion
/// that the gutter's line numbers are inline with the line itself.
///
/// The gutter view has insets of it's own that are relative to the widest line index. By default, these insets are 20px
/// leading, and 12px trailing. It paints its background across its whole width, the folding ribbon included: nothing
/// it covers is meant to be read, since the text it floats over is scrolled clear of it whenever it matters.
///
public class GutterView: NSView {
    struct EdgeInsets: Equatable, Hashable {
        let leading: CGFloat
        let trailing: CGFloat

        var horizontal: CGFloat {
            leading + trailing
        }
    }

    @Invalidating(.display)
    var textColor: NSColor = .secondaryLabelColor

    @Invalidating(.display)
    var font: NSFont = .systemFont(ofSize: 13) {
        didSet {
            shapedLineNumbers.removeAll()
            updateFontLineHeight()
            lineNumberDigits = 0
            updateWidthIfNeeded()
        }
    }

    @Invalidating(.display)
    var edgeInsets = EdgeInsets(leading: GutterView.windowEdgeLeadingInset, trailing: 12)

    /// The margin a gutter keeps to its left when it runs down the side of a window.
    static let windowEdgeLeadingInset: CGFloat = 20

    /// The digits a gutter reserves room for when it has a document that can still grow.
    ///
    /// Reserving three keeps the gutter from changing width as the reader types past line nine and line ninety-nine,
    /// which would shift the whole document sideways mid-keystroke.
    static let growingDocumentDigits = 3

    /// Whether the gutter measures itself against the document rather than against a full editor window.
    ///
    /// An inline listing has no window edge to keep a margin from, and its line count is whatever it was handed, so
    /// reserving room for digits it does not have leaves a blank strip where a reader expects the number. A
    /// single-digit listing paid 20pt of window margin plus 15pt of unused digits: 35pt of nothing to the left of a
    /// 7pt "1". The view hosting it supplies whatever margin it wants through the editor's content insets.
    public var fitsContent: Bool = false {
        didSet {
            guard fitsContent != oldValue else { return }
            edgeInsets = EdgeInsets(
                leading: fitsContent ? 0 : GutterView.windowEdgeLeadingInset,
                trailing: edgeInsets.trailing
            )
            lineNumberWidth = 0
            lineNumberDigits = 0
            updateWidthIfNeeded()
        }
    }

    /// The leading padding for the folding ribbon from the line numbers.
    @Invalidating(.display)
    var foldingRibbonPadding: CGFloat = 4

    @Invalidating(.display)
    var backgroundColor: NSColor? = NSColor.controlBackgroundColor

    @Invalidating(.display)
    var highlightSelectedLines: Bool = true

    @Invalidating(.display)
    var selectedLineTextColor: NSColor? = .labelColor

    @Invalidating(.display)
    var selectedLineColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)

    /// Toggle the visibility of the line fold decoration.
    @Invalidating(.display)
    public var showFoldingRibbon: Bool = true {
        didSet {
            foldingRibbon.isHidden = !showFoldingRibbon
            if showFoldingRibbon {
                foldingRibbon.model?.refresh()
            }
        }
    }

    // The column is reserved while this is on, revealed or not, so the document never shifts under the reader.
    @Invalidating(.display)
    public var showStatementRunControls: Bool = false {
        didSet {
            statementRunRibbon.isHidden = !showStatementRunControls
            updateWidthIfNeeded()
            layoutRibbons()
        }
    }

    @Invalidating(.display)
    public var showBreakpoints: Bool = false {
        didSet {
            breakpointRibbon.isHidden = !showBreakpoints
            updateWidthIfNeeded()
            layoutRibbons()
        }
    }

    /// Toggle the visibility of the line numbers.
    ///
    /// The gutter stays visible either way, so an editor can show the folding ribbon on its own. That costs a column
    /// wide enough for the fold controls with nothing in it whenever the document has nothing to fold, so an editor
    /// that has no line numbers to show is usually better off hiding the gutter entirely.
    @Invalidating(.display)
    public var showLineNumbers: Bool = true {
        didSet {
            updateWidthIfNeeded()
        }
    }

    private weak var textView: TextView?
    private weak var delegate: GutterViewDelegate?
    /// The width of the widest number the gutter has room for, measured for ``lineNumberDigits`` digits.
    private var lineNumberWidth: CGFloat = 0
    /// The number of digits ``lineNumberWidth`` was measured for, or zero when it has to be measured again.
    private var lineNumberDigits: Int = 0

    private var fontLineHeight = 1.0

    private(set) var selectionObserver: NSObjectProtocol?

    // A number's shape depends only on the number, the font and the colour it is drawn in, and the same few dozen
    // visible numbers are drawn on every scroll frame and every edit.
    private struct ShapedLineNumberKey: Hashable {
        let number: Int
        let color: CGColor
    }

    private var shapedLineNumbers: [ShapedLineNumberKey: CTLine] = [:]
    private static let shapedLineNumberLimit = 4_096

    // The rows the caret's band and the selected line numbers were last drawn on, redrawn when the selection leaves.
    private var drawnSelectionRows: [CGRect] = []

    private func updateFontLineHeight() {
        let string = NSAttributedString(string: "0", attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let ctLine = CTTypesetterCreateLine(typesetter, CFRangeMake(0, 1))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        fontLineHeight = (ascent + descent + leading)
    }

    /// The view that draws the fold decoration in the gutter.
    var foldingRibbon: LineFoldRibbonView

    /// The view that draws the per-statement run controls in the gutter.
    var statementRunRibbon: StatementRunRibbonView

    /// The padding between a run control and the line number beside it.
    @Invalidating(.display)
    var statementRunRibbonPadding: CGFloat = 4

    /// The room the run controls reserve at the gutter's leading edge, control plus padding.
    var statementRunRibbonWidth: CGFloat {
        statementRunRibbon.isHidden ? 0 : StatementRunRibbonView.width + statementRunRibbonPadding
    }

    var breakpointRibbon: BreakpointRibbonView

    @Invalidating(.display)
    var breakpointRibbonPadding: CGFloat = 4

    var breakpointRibbonWidth: CGFloat {
        breakpointRibbon.isHidden ? 0 : BreakpointRibbonView.width + breakpointRibbonPadding
    }

    private var leadingControlsWidth: CGFloat {
        breakpointRibbonWidth + statementRunRibbonWidth
    }

    // The leading controls share the window-edge margin, as Xcode's do; it grows only when they need more.
    private var lineNumberLeading: CGFloat {
        guard showLineNumbers else { return leadingControlsWidth }
        return max(edgeInsets.leading, leadingControlsWidth)
    }

    /// The leading inset only exists to keep line numbers off the edge, so a gutter without them drops it rather
    /// than leaving a blank margin where the numbers would have been.
    private var horizontalInsets: CGFloat {
        lineNumberLeading + edgeInsets.trailing
    }

    private var numberAreaWidth: CGFloat {
        showLineNumbers ? lineNumberWidth : 0
    }

    /// Syntax helper for determining the required space for the folding ribbon.
    private var foldingRibbonWidth: CGFloat {
        if foldingRibbon.isHidden {
            0.0
        } else {
            LineFoldRibbonView.width + foldingRibbonPadding
        }
    }

    /// The gutter's y positions start at the top of the document and increase as it moves down the screen.
    override public var isFlipped: Bool {
        true
    }

    override public var frame: NSRect {
        get {
            super.frame
        }
        set {
            super.frame = newValue
            layoutRibbons()
        }
    }

    // Also called when a ribbon shows or hides, since that can leave the gutter's width, and so its frame, unchanged.
    private func layoutRibbons() {
        let size = frame.size
        foldingRibbon.frame = NSRect(
            x: size.width - edgeInsets.trailing - foldingRibbonWidth + foldingRibbonPadding,
            y: 0.0,
            width: foldingRibbonWidth,
            height: size.height
        )
        breakpointRibbon.frame = NSRect(
            x: 0.0,
            y: 0.0,
            width: max(0, breakpointRibbonWidth - breakpointRibbonPadding),
            height: size.height
        )
        statementRunRibbon.frame = NSRect(
            x: breakpointRibbonWidth,
            y: 0.0,
            width: max(0, statementRunRibbonWidth - statementRunRibbonPadding),
            height: size.height
        )
    }

    public convenience init(
        configuration: borrowing SourceEditorConfiguration,
        controller: TextViewController,
        delegate: GutterViewDelegate? = nil
    ) {
        self.init(
            font: configuration.appearance.font,
            textColor: configuration.appearance.theme.text.color,
            selectedTextColor: configuration.appearance.theme.selection,
            controller: controller,
            delegate: delegate
        )
    }

    public init(
        font: NSFont,
        textColor: NSColor,
        selectedTextColor: NSColor?,
        controller: TextViewController,
        delegate: GutterViewDelegate? = nil
    ) {
        self.font = font
        self.textColor = textColor
        self.selectedLineTextColor = selectedTextColor ?? .secondaryLabelColor
        self.textView = controller.textView
        self.delegate = delegate

        foldingRibbon = LineFoldRibbonView(controller: controller)
        statementRunRibbon = StatementRunRibbonView(controller: controller)
        breakpointRibbon = BreakpointRibbonView(controller: controller)

        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true

        statementRunRibbon.isHidden = !showStatementRunControls
        breakpointRibbon.isHidden = !showBreakpoints
        addSubview(foldingRibbon)
        addSubview(statementRunRibbon)
        addSubview(breakpointRibbon)

        // A block observer is only removed through its token, and only this editor's selection moves its line band.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: controller.textView.selectionManager,
            queue: .main
        ) { [weak self] _ in
            self?.setNeedsDisplayForSelection()
        }
    }

    /// Redraws the numbers an edit can change: its own line, or every line from it down when the edit adds or removes
    /// a line, or can rewrap one, since each number below then moves.
    func setNeedsDisplayForEdit(at location: Int, movesLinesBelow: Bool) {
        guard let line = textView?.layoutManager.textLineForOffset(location) else {
            needsDisplay = true
            return
        }
        let height = movesLinesBelow ? max(bounds.maxY - line.yPos, line.height) : line.height
        setNeedsDisplay(CGRect(x: 0, y: line.yPos, width: frame.width, height: height))
    }

    /// Redraws the rows the selection was on and the rows it is on now: its band and its line numbers' colour.
    func setNeedsDisplayForSelection() {
        let current = selectionRows()
        let dirty = drawnSelectionRows + current
        drawnSelectionRows = current
        for row in dirty {
            setNeedsDisplay(row)
        }
    }

    // A layout pass can redraw the band on rows no selection change named, so a draw remembers where it put it.
    private func noteSelectionDrawn(in rect: NSRect) {
        for row in selectionRows() where row.intersects(rect) && !drawnSelectionRows.contains(row) {
            drawnSelectionRows.append(row)
        }
        if drawnSelectionRows.count > 16 {
            drawnSelectionRows = [drawnSelectionRows.reduce(CGRect.null) { $0.union($1) }]
        }
    }

    // Many carets, or a range, collapse to one rect spanning them, which is all one draw pass would cover anyway.
    private func selectionRows() -> [CGRect] {
        guard let textView, let selectionManager = textView.selectionManager else { return [] }
        let layoutManager = textView.layoutManager
        var top = CGFloat.greatestFiniteMagnitude
        var bottom = -CGFloat.greatestFiniteMagnitude
        var rows: [CGRect] = []
        for selection in selectionManager.textSelections {
            guard let first = layoutManager?.textLineForOffset(selection.range.location) else { continue }
            let last = selection.range.isEmpty
                ? first
                : layoutManager?.textLineForOffset(selection.range.max) ?? first
            rows.append(CGRect(x: 0, y: first.yPos, width: frame.width, height: last.yPos + last.height - first.yPos))
            top = min(top, first.yPos)
            bottom = max(bottom, last.yPos + last.height)
        }
        guard rows.count > 8 else { return rows }
        return [CGRect(x: 0, y: top, width: frame.width, height: bottom - top)]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The gutter floats on top of the text view, so a right-click on the line numbers resolves to the
    /// gutter rather than the editor. Forward the menu so the editor answers for its own ruler.
    override public func menu(for event: NSEvent) -> NSMenu? {
        textView?.menu(for: event)
    }

    // A positional lookup lands on the gutter, not the ribbons, for the same reason a right-click does.
    override public func accessibilityHitTest(_ point: NSPoint) -> Any? {
        if !breakpointRibbon.isHidden,
           let hit = breakpointRibbon.accessibilityElement(atScreenPoint: point) {
            return hit
        }
        if !statementRunRibbon.isHidden,
           let hit = statementRunRibbon.accessibilityElement(atScreenPoint: point) {
            return hit
        }
        return super.accessibilityHitTest(point)
    }

    // MARK: - Fold Control Hover

    /// The gutter owns the tracking for the fold controls, not the ribbon that draws them.
    ///
    /// The ribbon is only as wide as a chevron, and a strip that narrow is a poor thing to have to find with the
    /// pointer before the controls will even appear. Tracking the whole gutter means moving anywhere near the line
    /// numbers reveals them, which is how an outline view reveals its disclosure triangles.
    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    /// The gutter holds controls, not text, so the pointer says so by staying an arrow over the whole column.
    ///
    /// A tracking area rather than a cursor rect, because `NSView.addCursorRect` is soft deprecated in favour of
    /// this, and because `.inVisibleRect` keeps it correct as the gutter scrolls without rebuilding anything.
    override public func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override public func mouseEntered(with event: NSEvent) {
        forwardPointer(event)
    }

    override public func mouseMoved(with event: NSEvent) {
        forwardPointer(event)
    }

    override public func mouseExited(with event: NSEvent) {
        foldingRibbon.pointerExitedGutter()
        statementRunRibbon.pointerExitedGutter()
        breakpointRibbon.pointerExitedGutter()
    }

    private func forwardPointer(_ event: NSEvent) {
        if !foldingRibbon.isHidden {
            foldingRibbon.pointerMoved(to: foldingRibbon.convert(event.locationInWindow, from: nil))
        }
        if !statementRunRibbon.isHidden {
            statementRunRibbon.pointerMoved(to: statementRunRibbon.convert(event.locationInWindow, from: nil))
        }
        if !breakpointRibbon.isHidden {
            breakpointRibbon.pointerMoved(to: breakpointRibbon.convert(event.locationInWindow, from: nil))
        }
    }

    /// Updates the width of the gutter if needed to match the maximum line number found as well as the folding ribbon.
    func updateWidthIfNeeded() {
        guard let textView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let documentDigits = String(textView.layoutManager.lineCount).count
        let lineStorageDigits = fitsContent
            ? documentDigits
            : max(GutterView.growingDocumentDigits, documentDigits)

        if lineNumberDigits != lineStorageDigits {
            let widestNumber = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(repeating: "0", count: lineStorageDigits), attributes: attributes)
            )
            lineNumberWidth = CTLineGetTypographicBounds(widestNumber, nil, nil, nil)
            lineNumberDigits = lineStorageDigits
        }

        let newWidth = numberAreaWidth + horizontalInsets + foldingRibbonWidth
        if frame.size.width != newWidth {
            frame.size.width = newWidth
            delegate?.gutterViewWidthDidUpdate()
        }
    }

    /// Fills the gutter background color.
    /// - Parameters:
    ///   - context: The drawing context to draw in.
    ///   - dirtyRect: A rect to draw in, received from ``draw(_:)``.
    private func drawBackground(_ context: CGContext, dirtyRect: NSRect) {
        guard let backgroundColor else { return }
        context.saveGState()
        context.setFillColor(backgroundColor.safeCGColor)
        context.fill(bounds.intersection(dirtyRect))
        context.restoreGState()
    }

    /// Draws selected line backgrounds from the text view's selection manager into the gutter view, making the
    /// selection background appear seamless between the gutter and text view.
    /// - Parameter context: The drawing context to use.
    ///
    /// Tested against the rect being drawn rather than the visible text, so a scroll that brings the caret's line in
    /// draws its band in the newly exposed rows without redrawing the rest of the gutter.
    private func drawSelectedLines(_ context: CGContext, dirtyRect: NSRect) {
        guard let textView = textView,
              let selectionManager = textView.selectionManager,
              highlightSelectedLines else {
            return
        }
        context.saveGState()

        var highlightedLines: Set<UUID> = []
        context.setFillColor(selectedLineColor.safeCGColor)

        // Spans the whole gutter, the folding ribbon included, so the band meets the text view's own line highlight
        // at the gutter's trailing edge.
        let xPos: CGFloat = 0
        let width = frame.width

        for selection in selectionManager.textSelections where selection.range.isEmpty {
            guard let line = textView.layoutManager.textLineForOffset(selection.range.location),
                  !highlightedLines.contains(line.data.id) else {
                continue
            }
            let band = CGRect(x: xPos, y: line.yPos, width: width, height: line.height).pixelAligned
            guard band.intersects(dirtyRect) else { continue }
            highlightedLines.insert(line.data.id)
            context.fill(band)
        }

        context.restoreGState()
    }

    /// IDs of lines that should render with the selected line number color.
    /// Empty (caret) selections route through `textLineForOffset` so the caret at the very end of
    /// the document still highlights the last line — the IndexSet path used for ranged selections
    /// is half-open and would otherwise drop that case.
    ///
    /// A ranged selection contributes only the lines inside `drawnRange`, when given, so a draw after Select All
    /// walks the lines it draws and not every line of the document.
    internal func highlightedLineIDs(in drawnRange: NSRange? = nil) -> Set<UUID> {
        guard let textView = textView, let selectionManager = textView.selectionManager else { return [] }
        var ids: Set<UUID> = []
        for selection in selectionManager.textSelections {
            if selection.range.isEmpty {
                if let line = textView.layoutManager.textLineForOffset(selection.range.location) {
                    ids.insert(line.data.id)
                }
            } else {
                let range = drawnRange.map { selection.range.intersection($0) } ?? selection.range
                guard let range, range.length > 0 else { continue }
                for linePosition in textView.layoutManager.lineStorage.linesInRange(range) {
                    ids.insert(linePosition.data.id)
                }
            }
        }
        return ids
    }

    /// Draw line numbers in the gutter, limited to a drawing rect.
    /// - Parameters:
    ///   - context: The drawing context to draw in.
    ///   - dirtyRect: A rect to draw in, received from ``draw(_:)``.
    private func drawLineNumbers(_ context: CGContext, dirtyRect: NSRect) {
        guard let textView = textView else { return }

        let highlightedIDs = highlightedLineIDs(in: textView.layoutManager.textRange(covering: dirtyRect))
        // Resolved once per pass in the drawing appearance, so a cached shape never carries another appearance's
        // colour.
        let numberColor = textColor.safeCGColor
        let highlightedNumberColor = (selectedLineTextColor ?? textColor).safeCGColor

        context.saveGState()
        context.clip(to: dirtyRect)

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for linePosition in textView.layoutManager.linesStartingAt(dirtyRect.minY, until: dirtyRect.maxY) {
            let ctLine = shapedLineNumber(
                linePosition.index + 1,
                color: highlightedIDs.contains(linePosition.data.id) ? highlightedNumberColor : numberColor
            )
            let fragment: LineFragment? = linePosition.data.lineFragments.first?.data
            var ascent: CGFloat = 0
            let lineNumberWidth = CTLineGetTypographicBounds(ctLine, &ascent, nil, nil)
            let fontHeightDifference = ((fragment?.height ?? 0) - fontLineHeight) / 4

            let yPos = linePosition.yPos + ascent + (fragment?.heightDifference ?? 0) / 2 + fontHeightDifference
            // Leading padding + (width - linewidth)
            let xPos = lineNumberLeading + (numberAreaWidth - lineNumberWidth)

            ContextSetHiddenSmoothingStyle(context, 16)

            context.textPosition = CGPoint(x: xPos, y: yPos)

            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    private func shapedLineNumber(_ number: Int, color: CGColor) -> CTLine {
        let key = ShapedLineNumberKey(number: number, color: color)
        if let shaped = shapedLineNumbers[key] {
            return shaped
        }
        if shapedLineNumbers.count >= Self.shapedLineNumberLimit {
            shapedLineNumbers.removeAll(keepingCapacity: true)
        }
        let shaped = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: "\(number)",
                attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? textColor]
            )
        )
        shapedLineNumbers[key] = shaped
        return shaped
    }

    override public func setNeedsDisplay(_ invalidRect: NSRect) {
        updateWidthIfNeeded()
        super.setNeedsDisplay(invalidRect)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        drawBackground(context, dirtyRect: dirtyRect)
        drawSelectedLines(context, dirtyRect: dirtyRect)
        if showLineNumbers {
            drawLineNumbers(context, dirtyRect: dirtyRect)
        }
        context.restoreGState()
        noteSelectionDrawn(in: dirtyRect)
    }

    deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
        delegate = nil
        textView = nil
    }
}
