//
//  FieldResizeHandle.swift
//  TablePro
//

import AppKit
import SwiftUI

// AppKit on purpose: in the inspector's List, an NSTableView, a SwiftUI DragGesture lost the mouse to the table a few points into the drag.
internal struct FieldResizeHandle: NSViewRepresentable {
    let onDrag: (Double) -> Void
    let onEnd: (Double) -> Void

    func makeNSView(context: Context) -> FieldResizeHandleView {
        FieldResizeHandleView()
    }

    func updateNSView(_ view: FieldResizeHandleView, context: Context) {
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.isEnabled = context.environment.isEnabled
    }
}

internal final class FieldResizeHandleView: NSView {
    static let gripSize = NSSize(width: 26, height: 4)

    var onDrag: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    // The inspector keeps its field list mounted, disabled, behind the JSON rendering.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            drag = nil
            isHovered = false
        }
    }

    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    // Window coordinates, which stay put while the field grows and moves this view down.
    private var drag: (startY: CGFloat, hasMoved: Bool)? {
        didSet { if (drag == nil) != (oldValue == nil) { needsDisplay = true } }
    }

    var isHighlighted: Bool { isHovered || drag != nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isEnabled else {
            super.cursorUpdate(with: event)
            return
        }
        NSCursor.dividerResize(isVertical: false).set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    // A handle removed mid-drag, as Expand does, gets no mouseUp it could act on.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        drag = nil
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        drag = (event.locationInWindow.y, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delta = downwardDelta(to: event) else { return }
        drag?.hasMoved = true
        NSCursor.dividerResize(isVertical: false).set()
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard let delta = downwardDelta(to: event), let drag else { return }
        self.drag = nil
        if drag.hasMoved { onEnd?(delta) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let size = Self.gripSize
        let grip = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        context.saveGState()
        context.setAlpha(isHighlighted ? 1 : 0.5)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: grip, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        context.restoreGState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func downwardDelta(to event: NSEvent) -> Double? {
        guard let drag else { return nil }
        return Double(drag.startY - event.locationInWindow.y)
    }
}
