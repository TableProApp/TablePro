//
//  GeometryFieldMapCanvas.swift
//  TablePro
//

import AppKit
import MapKit
import SwiftUI

/// The map for one geometry value: the result Map's surface and coordinator, with nothing to
/// select and a surface taken from the pool.
internal struct GeometryFieldMapCanvas: NSViewRepresentable {
    static let inspectorIdentifier = "inspector-geometry-map"

    let projection: ResultMapProjection
    /// A cheap identity for `projection`, as on the result Map's canvas.
    let projectionToken: Int
    let fitToken: Int
    let caption: String
    /// The pop-out window draws this canvas too, and a UI test cannot tell two elements with one
    /// identifier apart.
    var identifier = GeometryFieldMapCanvas.inspectorIdentifier

    func makeCoordinator() -> ResultMapCoordinator {
        ResultMapCoordinator(fitPolicy: .field, onSelect: { _ in })
    }

    /// The coordinator is not attached for clicks: a field has no selection for one to change.
    func makeNSView(context: Context) -> ResultMapSurface {
        let surface = ResultMapSurface.inspectorPool.take()
        surface.delegate = context.coordinator
        surface.setAccessibilityIdentifier(identifier)
        surface.setAccessibilityLabel(String(localized: "Map"))
        return surface
    }

    func updateNSView(_ surface: ResultMapSurface, context: Context) {
        context.coordinator.apply(projection: projection, token: projectionToken, to: surface)
        context.coordinator.fitIfNeeded(
            token: Self.fitKey(projectionToken: projectionToken, fitToken: fitToken),
            in: surface
        )
        /// `MKMapView` is one image element with no children, so the caption is all VoiceOver has
        /// of what the map shows.
        surface.setAccessibilityValue(caption)
    }

    static func dismantleNSView(_ surface: ResultMapSurface, coordinator: ResultMapCoordinator) {
        coordinator.detach(from: surface)
        ResultMapSurface.inspectorPool.give(surface)
    }

    /// A new value can be anywhere on the globe, so a new projection is fitted whether or not the
    /// caller also asked for a fit.
    nonisolated static func fitKey(projectionToken: Int, fitToken: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(projectionToken)
        hasher.combine(fitToken)
        return hasher.finalize()
    }
}
