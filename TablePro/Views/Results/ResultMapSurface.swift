//
//  ResultMapSurface.swift
//  TablePro
//

import AppKit
import MapKit

/// An `MKMapView` that reports a plain click.
///
/// MapKit publishes no overlay hit-test or selection API, so a click on a polygon has to be
/// resolved by the app. Doing it with an `NSClickGestureRecognizer` added to the map view means
/// winning an arbitration against MapKit's own pan and zoom recognizers, which it does not:
/// measured, the action never fired, with and without a delegate answering
/// `shouldRecognizeSimultaneouslyWith`.
///
/// `mouseUp` is `NSResponder`'s own path and needs no arbitration. `super` is always called, so
/// panning, zooming and every other MapKit gesture behave exactly as they did.
final class ResultMapSurface: MKMapView {
    /// Called with a point in this view's coordinates for a click that did not drag.
    var onClick: ((NSPoint) -> Void)?

    /// A pan starts with a mouse-down too, so the press is only a click if the pointer barely
    /// moved. Three points is the distance AppKit itself treats as a click rather than a drag.
    private static let dragThreshold: CGFloat = 3

    private var pressOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        pressOrigin = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        let origin = pressOrigin
        pressOrigin = nil
        super.mouseUp(with: event)

        guard let origin else { return }
        let moved = hypot(end.x - origin.x, end.y - origin.y)
        guard moved <= Self.dragThreshold else { return }
        onClick?(end)
    }
}
