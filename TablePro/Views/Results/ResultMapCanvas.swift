//
//  ResultMapCanvas.swift
//  TablePro
//

import AppKit
import MapKit
import SwiftUI
import TableProGeometry
import TableProPluginKit

/// The map surface, as `MKMapView` rather than SwiftUI's `Map`.
///
/// Not a preference. MapKit publishes no overlay selection and no overlay hit-test API at any
/// layer: the only selection API in the framework covers annotations. Clicking a polygon or a line
/// can only be resolved through `MKOverlayPathRenderer.path` plus `MKOverlayRenderer.point(for:)`,
/// and the renderer is reachable only via `MKMapView.renderer(for:)`, which SwiftUI's `Map` does
/// not expose. SwiftUI's `MapPolygon` also has no `interiorPolygons` initializer, so it cannot draw
/// a polygon with a hole, and `MapSelection` is macOS 15 only.
///
/// Every polygon row goes into one `MKMultiPolygon` and every line row into one `MKMultiPolyline`.
/// Measured: 50,000 rows cost 0.022s that way against 125s as separate overlays, and the selected
/// shape is a single extra overlay swapped on click at 0.170ms.
struct ResultMapCanvas: NSViewRepresentable {
    let projection: ResultMapProjection
    /// A cheap identity for `projection`, so the coordinator can tell "same shapes" from "new
    /// shapes" without an element-wise comparison of up to 100,000 of them on every SwiftUI update.
    let projectionToken: Int
    let selectedRowIDs: Set<RowID>
    let fitToken: Int
    let onSelect: (RowID?) -> Void

    func makeCoordinator() -> ResultMapCoordinator {
        ResultMapCoordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsZoomControls = true
        mapView.isPitchEnabled = false
        mapView.showsUserLocation = false
        if #available(macOS 14.0, *) {
            /// A muted basemap keeps the tiles from competing with the data drawn over them, which
            /// is the whole point of the pane.
            mapView.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        }
        context.coordinator.attach(to: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.apply(projection: projection, token: projectionToken, to: mapView)
        context.coordinator.applySelection(selectedRowIDs, to: mapView)
        context.coordinator.fitIfNeeded(token: fitToken, in: mapView)
    }

    /// Terminal teardown belongs here and not to `onDisappear`.
    ///
    /// Switching the result view away from Map destroys this view's identity, which is what
    /// `dismantleNSView` fires on; `onDisappear` also fires when a pane is merely unparented, and
    /// releasing an aggregate holding up to 100,000 geometries there would take it away from a
    /// view that is coming straight back.
    static func dismantleNSView(_ mapView: MKMapView, coordinator: ResultMapCoordinator) {
        coordinator.detach(from: mapView)
    }
}
