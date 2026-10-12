//
//  ResultMapHitTesting.swift
//  TablePro
//

import MapKit

/// Resolves a click on the map to the row that owns the shape under it.
///
/// Pure, and deliberately free of `MKMapView`: a renderer's `path` and its `point(for:)` both work
/// on a renderer that was never attached to a map view, measured, so the whole hit test can be
/// exercised headlessly. The alternative was a method on the coordinator that only a running app
/// could reach, which is how the first version shipped untested and did not work.
enum ResultMapHitTesting {
    /// Topmost first: later shapes draw over earlier ones, so the last match in draw order is the
    /// one the reader is pointing at.
    ///
    /// The bounding-rect test comes first because it rejects nearly every member for the cost of a
    /// comparison, which is what keeps a click over tens of thousands of shapes to a fraction of a
    /// millisecond.
    static func polygonIndex(at mapPoint: MKMapPoint, in polygons: [MKPolygon]) -> Int? {
        for index in polygons.indices.reversed() {
            let polygon = polygons[index]
            guard polygon.boundingMapRect.contains(mapPoint) else { continue }
            let renderer = MKPolygonRenderer(polygon: polygon)
            guard let path = renderer.path else { continue }
            /// Even-odd, not the default winding rule. Measured: a polygon's interior rings wind
            /// the same way as its exterior, so the non-zero rule counts a hole as inside and a
            /// click in the middle of one would select a shape that is not under the pointer.
            /// `MKPolygonRenderer` fills with even-odd for the same reason, which is why the hole
            /// looks empty on screen.
            guard path.contains(renderer.point(for: mapPoint), using: .evenOdd) else { continue }
            return index
        }
        return nil
    }

    /// A line is one pixel of target, so the click is matched against the path widened to the slop
    /// the caller measured for the current zoom rather than against the line itself.
    static func polylineIndex(
        at mapPoint: MKMapPoint,
        in polylines: [MKPolyline],
        slopInMapPoints: Double
    ) -> Int? {
        let slop = max(slopInMapPoints, 1)
        let probe = MKMapRect(
            x: mapPoint.x - slop,
            y: mapPoint.y - slop,
            width: slop * 2,
            height: slop * 2
        )
        for index in polylines.indices.reversed() {
            let polyline = polylines[index]
            guard polyline.boundingMapRect.intersects(probe) else { continue }
            let renderer = MKPolylineRenderer(polyline: polyline)
            guard let path = renderer.path else { continue }
            let local = renderer.point(for: mapPoint)
            let edge = renderer.point(for: MKMapPoint(x: mapPoint.x + slop, y: mapPoint.y))
            let localSlop = max(abs(edge.x - local.x), 1)
            let widened = path.copy(
                strokingWithWidth: localSlop * 2,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 1
            )
            guard widened.contains(local) else { continue }
            return index
        }
        return nil
    }
}
