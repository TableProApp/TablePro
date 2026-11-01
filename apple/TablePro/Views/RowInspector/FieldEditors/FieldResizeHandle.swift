//
//  FieldResizeHandle.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The grip under a resizable field, reporting how far it has been dragged downward.
///
/// AppKit on purpose. The inspector is a SwiftUI `List`, an `NSTableView`, and the table took the
/// mouse from a `DragGesture` in its row a few points into the drag: the gesture was cancelled
/// without ending, so the field snapped back to its stored height. A view that takes `mouseDown`
/// itself receives every drag and the release, as a split view's divider does.
internal struct FieldResizeHandle: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onDrag: (Double) -> Void
    let onEnd: (Double) -> Void

    func makeNSView(context: Context) -> FieldResizeHandleView {
        let view = FieldResizeHandleView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: FieldResizeHandleView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

internal final class FieldResizeHandleView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDrag: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?

    /// Window coordinates, which stay put while the field grows and moves this view down.
    private var dragStartY: CGFloat?
    private var hoverArea: NSTrackingArea?
    private var isHovered = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }

    /// Expanding from the keyboard removes the handle under a resting pointer, and no exit follows,
    /// so the grip stayed lit after collapsing.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, isHovered else { return }
        isHovered = false
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let delta = downwardDelta(to: event) else { return }
        NSCursor.resizeUpDown.set()
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard let delta = downwardDelta(to: event) else { return }
        dragStartY = nil
        onEnd?(delta)
    }

    private func downwardDelta(to event: NSEvent) -> Double? {
        guard let dragStartY else { return nil }
        return Double(dragStartY - event.locationInWindow.y)
    }
}
