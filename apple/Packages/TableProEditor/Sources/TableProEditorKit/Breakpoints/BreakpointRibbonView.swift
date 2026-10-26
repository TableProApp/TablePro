//
//  BreakpointRibbonView.swift
//  TableProEditorKit
//

import AppKit
import TableProTextEngine

// The breakpoints and execution line live on the controller, so a host can set them before this view exists.
class BreakpointRibbonView: NSView {
    static let width: CGFloat = 14.0
    static let glyphPointSize: CGFloat = 9.0
    static let hintOpacity: CGFloat = 0.4

    enum Marker: Hashable {
        case breakpoint
        case execution
        case breakpointAtExecution
    }

    private struct GlyphKey: Hashable {
        let marker: Marker
        let color: NSColor
    }

    // Window frame and document height catch a window move, fold or rewrap that moves an element.
    struct PublishedElementsKey: Equatable {
        let breakpointLines: Set<Int>
        let visibleRect: CGRect
        let windowFrame: CGRect?
        let documentHeight: CGFloat?
    }

    @Invalidating(.display)
    var breakpointColor: NSColor = .systemRed

    @Invalidating(.display)
    var executionColor: NSColor = .systemGreen

    // NSAccessibilityElement requires its vendor to keep ownership; fresh objects per query make VoiceOver focus jump.
    var publishedElements: [BreakpointElement] = []
    var publishedElementsKey: PublishedElementsKey?

    private(set) var hoveredLine: Int? {
        didSet {
            guard hoveredLine != oldValue else { return }
            needsDisplay = true
        }
    }

    private var glyphCache: [GlyphKey: NSImage] = [:]
    private var pressedLine: Int?

    weak var controller: TextViewController?

    override var isFlipped: Bool {
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

    func pointerMoved(to point: CGPoint) {
        hoveredLine = bounds.contains(point) ? line(at: point) : nil
    }

    func pointerExitedGutter() {
        hoveredLine = nil
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse Events

    // Fires on mouse up over the line the press started on, so dragging off takes the press back, as with a button.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.type == .leftMouseDown, let line = line(at: point) else {
            super.mouseDown(with: event)
            return
        }
        pressedLine = line
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressedLine != nil else {
            super.mouseDragged(with: event)
            return
        }
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedLine else {
            super.mouseUp(with: event)
            return
        }
        pressedLine = nil

        let point = convert(event.locationInWindow, from: nil)
        if line(at: point) == pressed {
            controller?.onBreakpointToggle?(pressed)
        }
        pointerMoved(to: point)
    }

    // MARK: - Line Lookup

    func line(at point: CGPoint) -> Int? {
        guard let layoutManager = controller?.textView?.layoutManager,
              let line = layoutManager.textLineForPosition(point.y),
              point.y >= line.yPos, point.y < line.yPos + line.height else {
            return nil
        }
        return line.index + 1
    }

    // Nil for a line a collapsed fold hides, which the layout manager would otherwise answer with the fold's own line.
    func position(
        ofLine lineNumber: Int,
        in layoutManager: TextLayoutManager
    ) -> TextLineStorage<TextLine>.TextLinePosition? {
        guard let line = layoutManager.textLineForIndex(lineNumber - 1), line.index == lineNumber - 1 else {
            return nil
        }
        return line
    }

    // Resolved while drawing, so the cache key is the color for the appearance AppKit made current.
    func glyph(_ marker: Marker, color: NSColor) -> NSImage? {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let key = GlyphKey(marker: marker, color: resolved)
        if let cached = glyphCache[key] {
            return cached
        }

        let symbolName: String
        let palette: [NSColor]
        switch marker {
        case .breakpoint:
            symbolName = "circle.fill"
            palette = [resolved]
        case .execution:
            symbolName = "arrowshape.right.fill"
            palette = [resolved]
        case .breakpointAtExecution:
            symbolName = "arrowtriangle.right.circle.fill"
            palette = [.white, resolved]
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: Self.glyphPointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: palette))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)

        glyphCache[key] = image
        return image
    }
}
