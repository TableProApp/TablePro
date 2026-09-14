//
//  DiagramScrollView.swift
//  TablePro
//
//  The scroll view both diagrams zoom in. `allowsMagnification` gives pinch and smart magnify and
//  nothing for a Command-held scroll: measured, AppKit only scrolls on one. This adds that zoom,
//  anchored at the pointer, and hands every other scroll to AppKit untouched.
//

import AppKit

final class DiagramScrollView: NSScrollView {
    private var scrollZoom = DiagramScrollZoom()

    /// Overriding `scrollWheel(with:)` opts a view out of responsive scrolling, which would cost a
    /// plain pan its overdraw on a large schema. Every scroll this does not zoom still goes to
    /// `super`, so the opt-in holds.
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

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
}
