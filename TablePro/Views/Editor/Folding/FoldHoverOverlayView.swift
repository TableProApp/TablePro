//
//  FoldHoverOverlayView.swift
//  TablePro
//

import AppKit

/// Reports pointer movement over the editor without taking part in it.
///
/// A tracking area needs a view to own it, and a collapsed fold's placeholder is drawn by the layout manager rather
/// than being a view. This sits over the text view to carry that tracking area, and returns `nil` from hit testing so
/// every click, selection and drag still reaches the editor underneath.
final class FoldHoverOverlayView: NSView {
    var onMouseMoved: ((NSEvent) -> Void)?
    var onMouseExited: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseMoved?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseExited?()
    }
}
