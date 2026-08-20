//
//  StatementRunRibbonView.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

/// Draws a run control beside each statement in the ``GutterView``.
///
/// The controls stay out of the way until the pointer is over the gutter, which is how Xcode reveals its own gutter
/// run control and how an outline view reveals a disclosure triangle. A document at rest is code and line numbers.
/// The column they sit in is reserved whether or not anything is drawn in it, so revealing a control never shifts the
/// document sideways.
///
/// Like the fold chevrons next to them, the controls are drawn rather than hosted as a view each, so scrolling a long
/// document never churns through view reuse. Drawn controls are invisible to assistive technology unless they say
/// otherwise, so the ribbon publishes one accessibility element per control; see
/// ``StatementRunRibbonView/accessibilityChildren()``.
class StatementRunRibbonView: NSView {
    /// The width of a run control, in points.
    ///
    /// Matches Xcode's own gutter run control, which is a 14pt template image.
    static let width: CGFloat = 14.0

    /// The point size of the run glyph.
    static let glyphPointSize: CGFloat = 10.0

    /// The statements this ribbon offers to run, in document order.
    var statements: [StatementRun] = [] {
        didSet {
            guard statements != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Called with the statement whose control was pressed.
    var onRun: ((StatementRun) -> Void)?

    /// What assistive technology reads for the ribbon itself. Supplied by the host, which owns localization.
    var accessibilityGroupLabel: String = "Run statement"

    /// The format assistive technology reads for one control, given the 1-based line its statement starts on.
    ///
    /// A format rather than a label per statement, because the line number is something this view already resolves
    /// while drawing. Asking the host for a label per statement would mean a layout lookup for every statement in the
    /// document each time the set changed, for labels only the handful on screen are ever read.
    var accessibilityLabelFormat: String = "Run the statement starting on line %d"

    /// The accessibility elements this view currently publishes.
    ///
    /// `NSAccessibilityElement` requires its vendor to keep ownership, so these are held rather than rebuilt and
    /// discarded on every query. Handing back fresh objects each time is what makes VoiceOver focus jump, and a
    /// positional query arrives on every pointer move.
    var publishedElements: [StatementRunElement] = []

    /// What ``publishedElements`` was built from, so a query that changes none of it reuses the elements.
    var publishedElementsKey: PublishedElementsKey?

    struct PublishedElementsKey: Equatable {
        let statements: [StatementRun]
        let visibleRect: CGRect
        let isEnabled: Bool
    }

    /// Whether the controls do anything right now.
    ///
    /// A tab that is already executing turns this off, because the editor holds one execution at a time. The controls
    /// stay drawn and dim rather than disappearing, so the gutter does not flicker for the length of a query.
    @Invalidating(.display)
    var isEnabled: Bool = true

    /// Whether the pointer is over the gutter, which is what reveals the controls.
    @Invalidating(.display)
    var isPointerInGutter: Bool = false

    /// The colour of a control revealed by the pointer. Matches the gutter's line numbers, being the same class of
    /// chrome.
    @Invalidating(.display)
    var glyphColor: NSColor = .tertiaryLabelColor

    /// The colour of the control under the pointer.
    @Invalidating(.display)
    var hoveredGlyphColor: NSColor = .controlAccentColor

    /// The statement whose control the pointer is on, if any.
    private(set) var hoveredStatement: StatementRun? {
        didSet {
            guard hoveredStatement != oldValue else { return }
            needsDisplay = true
        }
    }

    private var glyphCache: [NSColor: NSImage] = [:]
    private var pressedStatement: StatementRun?

    weak var controller: TextViewController?

    override public var isFlipped: Bool {
        true
    }

    init(controller: TextViewController) {
        self.controller = controller
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hover

    /// Called by the ``GutterView`` as the pointer moves anywhere over the gutter.
    ///
    /// The gutter owns the tracking, not this view, so moving over the line numbers reveals the controls too. Only a
    /// pointer actually over this view marks a control as hovered, so what looks pressable and what is pressable stay
    /// the same thing.
    func pointerMoved(to point: CGPoint) {
        isPointerInGutter = true
        hoveredStatement = bounds.contains(point) ? statement(at: point) : nil
    }

    /// Called by the ``GutterView`` when the pointer leaves the gutter.
    func pointerExitedGutter() {
        isPointerInGutter = false
        hoveredStatement = nil
    }

    /// Scrolling moves the statements under a stationary pointer, so the hovered one has to be resolved again.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse Events

    /// Fires on mouse up over the control the press started on, which is how every AppKit button behaves and lets a
    /// press be taken back by dragging off it. Worth the extra state here rather than firing on the way down, because
    /// this one sends SQL to a database.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.type == .leftMouseDown, isEnabled, let statement = statement(at: point) else {
            super.mouseDown(with: event)
            return
        }
        pressedStatement = statement
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressedStatement != nil else {
            super.mouseDragged(with: event)
            return
        }
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedStatement else {
            super.mouseUp(with: event)
            return
        }
        pressedStatement = nil

        let point = convert(event.locationInWindow, from: nil)
        if isEnabled, statement(at: point) == pressed {
            onRun?(pressed)
        }
        pointerMoved(to: point)
    }

    // MARK: - Statement Lookup

    /// The statement whose control sits at a point, if a control sits there at all.
    private func statement(at point: CGPoint) -> StatementRun? {
        guard let layoutManager = controller?.textView?.layoutManager,
              let line = layoutManager.textLineForPosition(point.y) else {
            return nil
        }
        return statementsByAnchorLine(in: line.range.intRange, layoutManager: layoutManager)[line.index]
    }

    /// The document range a rect in this view covers.
    ///
    /// The ribbon is taller than the text it sits beside, so a rect reaching past the last line resolves to no line at
    /// all. Falling back to the last line is what keeps a document scrolled to its end from losing every control.
    func documentRange(covering rect: CGRect, layoutManager: TextLayoutManager) -> Range<Int>? {
        guard let firstLine = layoutManager.textLineForPosition(max(0, rect.minY)) else { return nil }
        guard let lastLine = layoutManager.textLineForPosition(rect.maxY)
            ?? layoutManager.textLineForIndex(max(0, layoutManager.lineCount - 1)) else { return nil }
        return firstLine.range.location..<max(firstLine.range.upperBound, lastLine.range.upperBound)
    }

    /// The statement each line in a range starts, keyed by line number.
    ///
    /// A statement whose first character has been folded away resolves to the line holding the fold's placeholder,
    /// which already belongs to the statement that opened the fold. Anchoring a second control there would draw two
    /// controls on one line and run the wrong statement from one of them, so a line keeps the first statement that
    /// claims it.
    func statementsByAnchorLine(
        in textRange: Range<Int>,
        layoutManager: TextLayoutManager
    ) -> [Int: StatementRun] {
        var result: [Int: StatementRun] = [:]

        for statement in statements where statement.range.length > 0 {
            guard statement.range.location < textRange.upperBound,
                  statement.range.upperBound > textRange.lowerBound,
                  let anchorLine = layoutManager.textLineForOffset(statement.range.location) else {
                continue
            }
            guard anchorLine.range.contains(statement.range.location) else { continue }
            if result[anchorLine.index] == nil {
                result[anchorLine.index] = statement
            }
        }

        return result
    }

    /// The run glyph in a colour.
    ///
    /// SF Symbols draws the same triangle the rest of the system uses for play, so the control is optically sized and
    /// weighted to match instead of being a hand-drawn approximation of it. Called while drawing, so the colour
    /// resolves against the appearance AppKit has already made current, and that resolved colour is the cache key.
    func glyph(color: NSColor) -> NSImage? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        if let cached = glyphCache[resolved] {
            return cached
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        let image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)

        glyphCache[resolved] = image
        return image
    }
}
