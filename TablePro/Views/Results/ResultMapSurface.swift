//
//  ResultMapSurface.swift
//  TablePro
//

import AppKit
import MapKit

/// An `MKMapView` that reports a plain click, and can leave a scroll to the list it sits in.
///
/// MapKit publishes no overlay hit-test or selection API, so a click on a polygon has to be
/// resolved by the app. Doing it with an `NSClickGestureRecognizer` added to the map view means
/// winning an arbitration against MapKit's own pan and zoom recognizers, which it does not:
/// measured, the action never fired, with and without a delegate answering
/// `shouldRecognizeSimultaneouslyWith`.
///
/// `mouseUp` is `NSResponder`'s own path and needs no arbitration. Both mouse overrides call
/// `super`, so panning, zooming and every other MapKit gesture behave exactly as they did.
final class ResultMapSurface: MKMapView {
    /// Called with a point in this view's coordinates for a click that did not drag.
    var onClick: ((NSPoint) -> Void)?

    /// Off for the result Map, which owns every scroll over it. Inside a scrolling list a map that
    /// takes the wheel is a second scroller with no end, and `isScrollEnabled` does not hand it on.
    var yieldsScrollToEnclosingScrollView = false {
        didSet { scrollRouting = ResultMapScrollRouting() }
    }

    /// A pan starts with a mouse-down too, so the press is only a click if the pointer barely
    /// moved. Three points is the distance AppKit itself treats as a click rather than a drag.
    private static let dragThreshold: CGFloat = 3

    private var pressOrigin: NSPoint?
    /// Started over whenever the flag is set, so a recycled surface does not carry a gesture
    /// latched under its last owner.
    private var scrollRouting = ResultMapScrollRouting()

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

    override func scrollWheel(with event: NSEvent) {
        let destination = scrollRouting.destination(
            for: DiagramScrollZoom.Input(event),
            yieldsToEnclosingScrollView: yieldsScrollToEnclosingScrollView,
            hasEnclosingScrollView: enclosingScrollView != nil
        )
        switch destination {
        case .map:
            super.scrollWheel(with: event)
        case .enclosingScrollView:
            nextResponder?.scrollWheel(with: event)
        }
    }
}

/// Who a scroll over the map belongs to: the map, or the scroll view the map sits in.
///
/// A plain scroll moves the list. Command-scroll stays with the map, so a mouse can still zoom at
/// a size where MapKit draws no zoom buttons.
struct ResultMapScrollRouting {
    enum Destination: Equatable {
        case map
        case enclosingScrollView
    }

    /// Reads Command once per trackpad gesture, so a swipe is never split between the two owners.
    private var gesture = DiagramScrollZoom()

    mutating func destination(
        for input: DiagramScrollZoom.Input,
        yieldsToEnclosingScrollView: Bool,
        hasEnclosingScrollView: Bool
    ) -> Destination {
        guard yieldsToEnclosingScrollView, hasEnclosingScrollView else { return .map }
        switch gesture.intent(for: input) {
        case .scroll:
            return .enclosingScrollView
        /// `.ignore` is the momentum after a Command swipe, and the map glides to a stop on it.
        case .zoom, .ignore:
            return .map
        }
    }
}
