//
//  LineFoldRibbonView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/6/25.
//

import AppKit
import CodeEditTextView

/// Draws the fold controls in the ``GutterView``.
///
/// A fold is disclosed the way macOS discloses anything else: a chevron pointing down while the content shows, and
/// right while it is hidden. An open fold's chevron stays out of the way until the pointer is over the gutter, the
/// same way an outline view reveals its disclosure triangles, so a document at rest is nothing but code and line
/// numbers. A collapsed fold keeps its chevron at all times, because hidden content the reader cannot find again is
/// worse than a little chrome.
///
/// The controls are drawn rather than hosted as a view per fold, so scrolling a long document never churns through
/// view reuse. Drawn controls are invisible to assistive technology unless they say otherwise, so the ribbon
/// publishes one accessibility element per chevron; see ``LineFoldRibbonView/accessibilityChildren()``.
///
/// Which fold is hovered is ``LineFoldModel/hoveredFold``, not state of this view: the gutter's chevron and the
/// collapsed fold's placeholder are two controls for the same fold, and both have to agree on which one the pointer
/// is on.
class LineFoldRibbonView: NSView {
    /// The width of the fold controls, in points.
    ///
    /// Matches the room AppKit gives a disclosure triangle in an outline view, so a chevron is the same size target
    /// here as everywhere else in the system.
    static let width: CGFloat = 14.0

    /// The point size of the chevron glyph.
    static let chevronPointSize: CGFloat = 9.0

    /// The width of the bar marking how far the hovered fold reaches, in points.
    static let extentWidth: CGFloat = 2.0

    var model: LineFoldModel?

    /// Whether the pointer is over the gutter, which is what reveals the open folds' chevrons.
    @Invalidating(.display)
    var isPointerInGutter: Bool = false

    @Invalidating(.display)
    var backgroundColor: NSColor = .controlBackgroundColor

    /// The colour of a chevron revealed by the pointer. Matches the gutter's line numbers, since it is the same
    /// class of chrome.
    @Invalidating(.display)
    var chevronColor: NSColor = .tertiaryLabelColor

    /// The colour of a collapsed fold's chevron, which is on screen whether or not the pointer is.
    @Invalidating(.display)
    var collapsedChevronColor: NSColor = .secondaryLabelColor

    /// The colour of the chevron under the pointer.
    @Invalidating(.display)
    var hoveredChevronColor: NSColor = .labelColor

    /// The colour of the bar marking how far the hovered fold reaches.
    @Invalidating(.display)
    var foldExtentColor: NSColor = .quaternaryLabelColor

    private var chevronCache: [ChevronKey: NSImage] = [:]

    private struct ChevronKey: Hashable {
        let isCollapsed: Bool
        let color: NSColor
    }

    override public var isFlipped: Bool {
        true
    }

    init(controller: TextViewController) {
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = false
        self.model = LineFoldModel(controller: controller, foldView: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A chevron is a control, not text, so the pointer says so by staying an arrow. Disclosure triangles elsewhere
    /// in the system do the same.
    override public func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    // MARK: - Hover

    /// Called by the ``GutterView`` as the pointer moves anywhere over the gutter.
    ///
    /// The gutter owns the tracking, not this view, so moving over the line numbers reveals the controls too. Only a
    /// pointer actually over this view marks a chevron as hovered, so what looks clickable and what is clickable stay
    /// the same thing.
    func pointerMoved(to point: CGPoint) {
        isPointerInGutter = true
        model?.setGutterHover(bounds.contains(point) ? fold(at: point) : nil)
    }

    /// Called by the ``GutterView`` when the pointer leaves the gutter.
    func pointerExitedGutter() {
        isPointerInGutter = false
        model?.setGutterHover(nil)
    }

    /// Scrolling moves the folds under a stationary pointer, so the hovered fold has to be resolved again.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.type == .leftMouseDown, let model, let fold = fold(at: point) else {
            super.mouseDown(with: event)
            return
        }

        model.setCollapsed(!model.isCollapsed(fold), for: fold)
        pointerMoved(to: point)
    }

    // MARK: - Fold Lookup

    /// The fold whose chevron sits at a point, if a chevron sits there at all.
    private func fold(at point: CGPoint) -> FoldRange? {
        guard let layoutManager = model?.controller?.textView.layoutManager,
              let line = layoutManager.textLineForPosition(point.y) else { return nil }
        return foldsByStartLine(in: line.range.intRange, layoutManager: layoutManager)[line.index]
    }

    /// The document range a rect in this view covers.
    ///
    /// The ribbon is taller than the text it sits beside, so a rect reaching past the last line resolves to no line
    /// at all. Falling back to the last line is what keeps a document scrolled to its end from losing every chevron.
    func documentRange(covering rect: CGRect, layoutManager: TextLayoutManager) -> Range<Int>? {
        guard let firstLine = layoutManager.textLineForPosition(max(0, rect.minY)) else { return nil }
        guard let lastLine = layoutManager.textLineForPosition(rect.maxY)
            ?? layoutManager.textLineForIndex(max(0, layoutManager.lineCount - 1)) else { return nil }
        return firstLine.range.location..<max(firstLine.range.upperBound, lastLine.range.upperBound)
    }

    /// The fold each line in a range opens, keyed by line number.
    ///
    /// A line can open more than one fold, since a statement and the parenthesised body inside it often begin on the
    /// same line. The outermost one wins, so a chevron always folds the largest block that starts where it is drawn.
    func foldsByStartLine(
        in textRange: Range<Int>,
        layoutManager: TextLayoutManager
    ) -> [Int: FoldRange] {
        guard let model else { return [:] }
        var result: [Int: FoldRange] = [:]

        for fold in model.getFolds(in: textRange) {
            guard let startLine = layoutManager.textLineForOffset(fold.range.lowerBound) else { continue }
            guard let existing = result[startLine.index] else {
                result[startLine.index] = fold
                continue
            }
            if fold.depth < existing.depth {
                result[startLine.index] = fold
            }
        }

        return result
    }

    /// The chevron glyph for a fold's state, in a colour.
    ///
    /// SF Symbols draws the same chevron the rest of the system uses for disclosure, so the control is optically
    /// sized and weighted to match instead of being a hand-drawn approximation of it.
    /// Called while drawing, so the colour resolves against the appearance AppKit has already made current. That
    /// resolved colour is the cache key, which is what keeps a light-mode chevron from being reused in dark mode.
    func chevron(isCollapsed: Bool, color: NSColor) -> NSImage? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = ChevronKey(isCollapsed: isCollapsed, color: resolved)
        if let cached = chevronCache[key] {
            return cached
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: Self.chevronPointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        let image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)

        chevronCache[key] = image
        return image
    }
}
