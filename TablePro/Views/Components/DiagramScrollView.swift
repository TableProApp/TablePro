//
//  DiagramScrollView.swift
//  TablePro
//
//  The scroll view both diagrams zoom in. `allowsMagnification` gives pinch and smart magnify and
//  nothing for a Command-held scroll: measured, AppKit only scrolls on one. This adds that zoom,
//  anchored at the pointer, and hands every other scroll to AppKit untouched.
//

import AppKit

/// A document that has to wait for its viewport to have a size before it can show something in it.
@MainActor
protocol DiagramViewportSettling: AnyObject {
    func viewportDidSettle()
}

final class DiagramScrollView: NSScrollView, ZoomCommandResponding {
    private var scrollZoom = DiagramScrollZoom()
    private var hasSettled = false

    /// Set while a viewport is attached, so View > Zoom In steps along the same ladder the toolbar
    /// buttons use and never a second copy of it.
    weak var zoomController: DiagramViewportController?

    /// Overriding `scrollWheel(with:)` opts a view out of responsive scrolling, which would cost a
    /// plain pan its overdraw on a large schema. Every scroll this does not zoom still goes to
    /// `super`, so the opt-in holds.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    /// SwiftUI makes this view with no size and gives it one on a later layout pass. The first tile
    /// with a size is the earliest point a saved offset lands where it was left, or a fit has a
    /// viewport to fit to, so both run here rather than in each diagram, which is how the plan
    /// diagram came to never restore at all.
    override func tile() {
        super.tile()
        guard !hasSettled, !contentView.bounds.isEmpty else { return }
        hasSettled = true
        zoomController?.placeDocumentIfLaidOut()
        (documentView as? DiagramViewportSettling)?.viewportDidSettle()
    }

    override func scrollWheel(with event: NSEvent) {
        guard allowsMagnification else {
            super.scrollWheel(with: event)
            return
        }

        switch scrollZoom.intent(for: DiagramScrollZoom.Input(event)) {
        case .scroll:
            super.scrollWheel(with: event)
        case .ignore:
            return
        case .zoom(let factor):
            zoom(by: factor, around: event.locationInWindow)
        }
    }

    /// `setMagnification(_:centeredAt:)` takes its point in the clip view's space, so converting
    /// through the document instead drifts by the document's origin.
    func zoom(by factor: CGFloat, around locationInWindow: NSPoint) {
        let target = DiagramZoom.scaled(from: magnification, by: factor)
        guard target != magnification else { return }
        setMagnification(target, centeredAt: contentView.convert(locationInWindow, from: nil))
    }

    /// A click on the pane around a document smaller than the viewport lands on the clip view,
    /// which takes no focus, so the diagram would never become what View > Zoom In acts on.
    override func mouseDown(with event: NSEvent) {
        if let documentView, documentView.acceptsFirstResponder {
            window?.makeFirstResponder(documentView)
        }
        super.mouseDown(with: event)
    }

    // MARK: - View > Zoom In / Zoom Out

    /// The document view is the first responder once clicked, and this scroll view is its ancestor,
    /// so the responder chain reaches these before the window's editor text-size fallback.
    @objc func zoomIn(_ sender: Any?) {
        zoomController?.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        zoomController?.zoomOut()
    }
}

extension DiagramScrollView: NSMenuItemValidation {
    /// At the end of the ladder the item dims rather than falling through to the editor's text
    /// size, the way a PDF view stops at its own limit.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)):
            return zoomController?.canZoomIn ?? false
        case #selector(zoomOut(_:)):
            return zoomController?.canZoomOut ?? false
        default:
            return true
        }
    }
}
