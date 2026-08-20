//
//  GutterView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 8/22/23.
//

import AppKit
import CodeEditTextView
import CodeEditTextViewObjC

public protocol GutterViewDelegate: AnyObject {
    func gutterViewWidthDidUpdate()
}

/// The gutter view displays line numbers that match the text view's line indexes.
/// This view is used as a scroll view's ruler view. It sits on top of the text view so text scrolls underneath the
/// gutter if line wrapping is disabled.
///
/// If the gutter needs more space (when the number of digits in the numbers increases eg. adding a line after line 99),
/// it will notify it's delegate via the ``GutterViewDelegate/gutterViewWidthDidUpdate(newWidth:)`` method. In
/// `SourceEditor`, this notifies the ``TextViewController``, which in turn updates the textview's edge insets
/// to adjust for the new leading inset.
///
/// This view also listens for selection updates, and draws a selected background on selected lines to keep the illusion
/// that the gutter's line numbers are inline with the line itself.
///
/// The gutter view has insets of it's own that are relative to the widest line index. By default, these insets are 20px
/// leading, and 12px trailing. However, this view also has a ``GutterView/backgroundEdgeInsets`` property, that pads
/// the rect that has a background drawn. This allows the text to be scrolled under the gutter view for 8px before being
/// overlapped by the gutter. It should help the textview keep the cursor visible if the user types while the cursor is
/// off the leading edge of the editor.
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
            updateFontLineHeight()
        }
    }

    @Invalidating(.display)
    var edgeInsets: EdgeInsets = EdgeInsets(leading: GutterView.windowEdgeLeadingInset, trailing: 12)

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
            maxLineNumberWidth = 0
            maxLineLength = 0
            updateWidthIfNeeded()
        }
    }

    @Invalidating(.display)
    var backgroundEdgeInsets: EdgeInsets = EdgeInsets(leading: 0, trailing: 8)

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
    var selectedLineColor: NSColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)

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

    /// Toggle the visibility of the per-statement run controls.
    ///
    /// The column they sit in is reserved for as long as this is on, whether or not the pointer is revealing a
    /// control, so a document never shifts sideways under the reader.
    @Invalidating(.display)
    public var showStatementRunControls: Bool = false {
        didSet {
            statementRunRibbon.isHidden = !showStatementRunControls
            updateWidthIfNeeded()
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
    private var maxLineNumberWidth: CGFloat = 0
    /// The maximum number of digits found for a line number.
    private var maxLineLength: Int = 0

    private var fontLineHeight = 1.0

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

    /// Where the line numbers start.
    ///
    /// The run controls live in the margin the gutter already keeps from the window edge rather than being charged
    /// for a column of their own, which is where Xcode puts its gutter controls too. The margin only grows when the
    /// controls need more room than it already had.
    private var lineNumberLeading: CGFloat {
        guard showLineNumbers else { return statementRunRibbonWidth }
        return max(edgeInsets.leading, statementRunRibbonWidth)
    }

    /// The leading inset only exists to keep line numbers off the edge, so a gutter without them drops it rather
    /// than leaving a blank margin where the numbers would have been.
    private var horizontalInsets: CGFloat {
        lineNumberLeading + edgeInsets.trailing
    }

    private var numberAreaWidth: CGFloat {
        showLineNumbers ? maxLineNumberWidth : 0
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

    /// We override this variable so we can update the two ribbons' frames to match the gutter.
    override public var frame: NSRect {
        get {
            super.frame
        }
        set {
            super.frame = newValue
            foldingRibbon.frame = NSRect(
                x: newValue.width - edgeInsets.trailing - foldingRibbonWidth + foldingRibbonPadding,
                y: 0.0,
                width: foldingRibbonWidth,
                height: newValue.height
            )
            statementRunRibbon.frame = NSRect(
                x: 0.0,
                y: 0.0,
                width: max(0, statementRunRibbonWidth - statementRunRibbonPadding),
                height: newValue.height
            )
        }
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

        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true

        statementRunRibbon.isHidden = !showStatementRunControls
        addSubview(foldingRibbon)
        addSubview(statementRunRibbon)

        NotificationCenter.default.addObserver(
            forName: TextSelectionManager.selectionChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The gutter floats on top of the text view, so a right-click on the line numbers resolves to the
    /// gutter rather than the editor. Forward the menu so the editor answers for its own ruler.
    override public func menu(for event: NSEvent) -> NSMenu? {
        textView?.menu(for: event)
    }

    /// A positional accessibility lookup lands on the gutter for the same reason a right-click does, so it answers for
    /// the controls its ribbons draw rather than letting the search fall through to the text view underneath.
    override public func accessibilityHitTest(_ point: NSPoint) -> Any? {
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
    }

    private func forwardPointer(_ event: NSEvent) {
        if !foldingRibbon.isHidden {
            foldingRibbon.pointerMoved(to: foldingRibbon.convert(event.locationInWindow, from: nil))
        }
        if !statementRunRibbon.isHidden {
            statementRunRibbon.pointerMoved(to: statementRunRibbon.convert(event.locationInWindow, from: nil))
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

        if maxLineLength < lineStorageDigits {
            // Update the max width
            let maxCtLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(repeating: "0", count: lineStorageDigits), attributes: attributes)
            )
            let width = CTLineGetTypographicBounds(maxCtLine, nil, nil, nil)
            maxLineNumberWidth = max(maxLineNumberWidth, width)
            maxLineLength = lineStorageDigits
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
        let minX = max(backgroundEdgeInsets.leading, dirtyRect.minX)
        let maxX = min(frame.width - backgroundEdgeInsets.trailing - foldingRibbonWidth, dirtyRect.maxX)
        let width = maxX - minX

        context.saveGState()
        context.setFillColor(backgroundColor.safeCGColor)
        context.fill(CGRect(x: minX, y: dirtyRect.minY, width: width, height: dirtyRect.height))
        context.restoreGState()
    }

    /// Draws selected line backgrounds from the text view's selection manager into the gutter view, making the
    /// selection background appear seamless between the gutter and text view.
    /// - Parameter context: The drawing context to use.
    private func drawSelectedLines(_ context: CGContext) {
        guard let textView = textView,
              let selectionManager = textView.selectionManager,
              let visibleRange = textView.visibleTextRange,
              highlightSelectedLines else {
            return
        }
        context.saveGState()

        var highlightedLines: Set<UUID> = []
        context.setFillColor(selectedLineColor.safeCGColor)

        let xPos = backgroundEdgeInsets.leading
        // Stops where the gutter background stops. The folding ribbon sits over the text view, so painting the
        // selection under it would stack this colour on top of the text view's own line highlight.
        let width = frame.width - backgroundEdgeInsets.trailing - foldingRibbonWidth

        for selection in selectionManager.textSelections where selection.range.isEmpty {
            guard let line = textView.layoutManager.textLineForOffset(selection.range.location),
                  visibleRange.intersection(line.range) != nil || selection.range.location == textView.length,
                  !highlightedLines.contains(line.data.id) else {
                continue
            }
            highlightedLines.insert(line.data.id)
            context.fill(
                CGRect(
                    x: xPos,
                    y: line.yPos,
                    width: width,
                    height: line.height
                ).pixelAligned
            )
        }

        context.restoreGState()
    }

    /// IDs of lines that should render with the selected line number color.
    /// Empty (caret) selections route through `textLineForOffset` so the caret at the very end of
    /// the document still highlights the last line — the IndexSet path used for ranged selections
    /// is half-open and would otherwise drop that case.
    internal func highlightedLineIDs() -> Set<UUID> {
        guard let textView = textView, let selectionManager = textView.selectionManager else { return [] }
        var ids: Set<UUID> = []
        for selection in selectionManager.textSelections {
            if selection.range.isEmpty {
                if let line = textView.layoutManager.textLineForOffset(selection.range.location) {
                    ids.insert(line.data.id)
                }
            } else {
                for linePosition in textView.layoutManager.lineStorage.linesInRange(selection.range) {
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
        var attributes: [NSAttributedString.Key: Any] = [.font: font]

        let highlightedIDs = highlightedLineIDs()

        context.saveGState()
        context.clip(to: dirtyRect)

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for linePosition in textView.layoutManager.linesStartingAt(dirtyRect.minY, until: dirtyRect.maxY) {
            if highlightedIDs.contains(linePosition.data.id) {
                attributes[.foregroundColor] = selectedLineTextColor ?? textColor
            } else {
                attributes[.foregroundColor] = textColor
            }

            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\(linePosition.index + 1)", attributes: attributes)
            )
            let fragment: LineFragment? = linePosition.data.lineFragments.first?.data
            var ascent: CGFloat = 0
            let lineNumberWidth = CTLineGetTypographicBounds(ctLine, &ascent, nil, nil)
            let fontHeightDifference = ((fragment?.height ?? 0) - fontLineHeight) / 4

            let yPos = linePosition.yPos + ascent + (fragment?.heightDifference ?? 0)/2 + fontHeightDifference
            // Leading padding + (width - linewidth)
            let xPos = lineNumberLeading + (numberAreaWidth - lineNumberWidth)

            ContextSetHiddenSmoothingStyle(context, 16)

            context.textPosition = CGPoint(x: xPos, y: yPos)

            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
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
        drawSelectedLines(context)
        if showLineNumbers {
            drawLineNumbers(context, dirtyRect: dirtyRect)
        }
        context.restoreGState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        delegate = nil
        textView = nil
    }
}
