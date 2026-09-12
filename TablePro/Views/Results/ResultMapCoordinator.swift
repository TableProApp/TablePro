//
//  ResultMapCoordinator.swift
//  TablePro
//

import AppKit
import MapKit
import os
import TableProGeometry
import TableProPluginKit

/// Owns the map's overlays, its hit-testing and its selection highlight.
@MainActor
final class ResultMapCoordinator: NSObject, MKMapViewDelegate {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ResultMap")

    /// How far off a line a click may land and still hit it, in points. A line is one pixel of
    /// target at any zoom, so the tolerance is converted to map units against the current
    /// viewport rather than being a fixed distance on the globe.
    private static let lineHitSlopPoints: Double = 8

    var onSelect: (RowID?) -> Void

    private var appliedProjection: ResultMapProjection?
    private var appliedToken: Int?
    private var polygonOverlay: MKMultiPolygon?
    private var polylineOverlay: MKMultiPolyline?
    /// The selection is two aggregate overlays, for the same reason the base layer is: one overlay
    /// per selected row costs 1.32s at 5,000 rows and 125s at 50,000, measured, and it also turned
    /// the renderer lookup into a linear scan of the selection on every overlay MapKit draws.
    private var highlightPolygonOverlay: MKMultiPolygon?
    private var highlightPolylineOverlay: MKMultiPolyline?
    private var pointAnnotations: [ResultMapAnnotation] = []
    private var selectedRowIDs: Set<RowID> = []
    /// Parallel to the member order inside each aggregate overlay, so a hit resolves to a row by
    /// index rather than by searching.
    private var polygonRowIDs: [RowID] = []
    private var polylineRowIDs: [RowID] = []
    private var lastFitToken: Int?

    init(onSelect: @escaping (RowID?) -> Void) {
        self.onSelect = onSelect
    }

    /// Clicks arrive from the map view itself rather than from an `NSClickGestureRecognizer`.
    ///
    /// A recognizer added beside MapKit's own pan and zoom recognizers has to win an arbitration it
    /// does not control, and a `shouldRecognizeSimultaneouslyWith` delegate did not make it fire.
    /// `ResultMapView` (the `MKMapView` subclass below) overrides `mouseUp` instead, which is
    /// `NSResponder`'s own path and needs no arbitration, and it calls `super` so panning and
    /// zooming behave exactly as MapKit implements them.
    func attach(to mapView: MKMapView) {
        (mapView as? ResultMapSurface)?.onClick = { [weak self, weak mapView] point in
            guard let self, let mapView else { return }
            self.handleClick(at: point, in: mapView)
        }
    }

    func detach(from mapView: MKMapView) {
        (mapView as? ResultMapSurface)?.onClick = nil
        mapView.delegate = nil
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        appliedProjection = nil
        appliedToken = nil
        polygonOverlay = nil
        polylineOverlay = nil
        highlightPolygonOverlay = nil
        highlightPolylineOverlay = nil
        pointAnnotations = []
        selectedRowIDs = []
        polygonRowIDs = []
        polylineRowIDs = []
    }

    // MARK: - Overlays

    func apply(projection: ResultMapProjection, token: Int, to mapView: MKMapView) {
        guard appliedToken != token else { return }
        appliedToken = token
        appliedProjection = projection

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        highlightPolygonOverlay = nil
        highlightPolylineOverlay = nil

        var polygons: [MKPolygon] = []
        var polylines: [MKPolyline] = []
        var annotations: [ResultMapAnnotation] = []
        polygonRowIDs = []
        polylineRowIDs = []

        for shape in projection.shapes {
            switch shape.kind {
            case .point:
                guard let coordinate = shape.rings.first?.first else { continue }
                annotations.append(
                    ResultMapAnnotation(rowID: shape.rowID, coordinate: Self.coordinate(coordinate))
                )
            case .polyline:
                guard let run = shape.rings.first, run.count >= 2 else { continue }
                polylines.append(Self.polyline(run))
                polylineRowIDs.append(shape.rowID)
            case .polygon:
                guard let polygon = Self.polygon(shape.rings) else { continue }
                polygons.append(polygon)
                polygonRowIDs.append(shape.rowID)
            }
        }

        polygonOverlay = polygons.isEmpty ? nil : MKMultiPolygon(polygons)
        polylineOverlay = polylines.isEmpty ? nil : MKMultiPolyline(polylines)
        pointAnnotations = annotations

        if let polygonOverlay { mapView.addOverlay(polygonOverlay, level: .aboveRoads) }
        if let polylineOverlay { mapView.addOverlay(polylineOverlay, level: .aboveRoads) }
        if !annotations.isEmpty { mapView.addAnnotations(annotations) }
    }

    // MARK: - Selection

    func applySelection(_ rowIDs: Set<RowID>, to mapView: MKMapView) {
        if let highlightPolygonOverlay { mapView.removeOverlay(highlightPolygonOverlay) }
        if let highlightPolylineOverlay { mapView.removeOverlay(highlightPolylineOverlay) }
        highlightPolygonOverlay = nil
        highlightPolylineOverlay = nil
        selectedRowIDs = rowIDs
        defer { refreshPointHighlights(in: mapView) }
        guard !rowIDs.isEmpty, let projection = appliedProjection else { return }

        var polygons: [MKPolygon] = []
        var polylines: [MKPolyline] = []
        for shape in projection.shapes where rowIDs.contains(shape.rowID) {
            switch shape.kind {
            case .point:
                continue
            case .polyline:
                guard let run = shape.rings.first, run.count >= 2 else { continue }
                polylines.append(Self.polyline(run))
            case .polygon:
                guard let polygon = Self.polygon(shape.rings) else { continue }
                polygons.append(polygon)
            }
        }
        if !polygons.isEmpty {
            let overlay = MKMultiPolygon(polygons)
            highlightPolygonOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
        if !polylines.isEmpty {
            let overlay = MKMultiPolyline(polylines)
            highlightPolylineOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveLabels)
        }
    }

    /// A point row is an annotation rather than an overlay, so its selection is its marker colour.
    ///
    /// The views are re-tinted in place instead of being replaced, because replacing an annotation
    /// drops MapKit's own clustering and re-runs it, which moves markers the reader is looking at.
    /// A cluster is tinted when any row inside it is selected, since that is the only thing on
    /// screen standing for those rows.
    private func refreshPointHighlights(in mapView: MKMapView) {
        for annotation in pointAnnotations {
            guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView else { continue }
            Self.tint(view, selected: selectedRowIDs.contains(annotation.rowID))
        }
        for annotation in mapView.annotations {
            guard let cluster = annotation as? MKClusterAnnotation,
                  let view = mapView.view(for: cluster) as? MKMarkerAnnotationView
            else {
                continue
            }
            Self.tint(view, selected: Self.holdsSelection(cluster, in: selectedRowIDs))
        }
    }

    private static func holdsSelection(_ cluster: MKClusterAnnotation, in rowIDs: Set<RowID>) -> Bool {
        cluster.memberAnnotations.contains { member in
            guard let point = member as? ResultMapAnnotation else { return false }
            return rowIDs.contains(point.rowID)
        }
    }

    private static func tint(_ view: MKMarkerAnnotationView, selected: Bool) {
        view.markerTintColor = selected ? .systemOrange : .controlAccentColor
        view.displayPriority = selected ? .required : .defaultLow
        view.zPriority = selected ? .max : .defaultUnselected
    }

    func fitIfNeeded(token: Int, in mapView: MKMapView) {
        guard token != lastFitToken, let projection = appliedProjection, !projection.isEmpty else { return }
        lastFitToken = token
        /// `MKMapRect.null` is the correct seed: a zero rect at the origin is not null and would
        /// drag every fit back to include the map's origin.
        var union = MKMapRect.null
        if let polygonOverlay { union = union.union(polygonOverlay.boundingMapRect) }
        if let polylineOverlay { union = union.union(polylineOverlay.boundingMapRect) }
        for annotation in pointAnnotations {
            union = union.union(MKMapRect(origin: MKMapPoint(annotation.coordinate), size: MKMapSize()))
        }
        guard !union.isNull else { return }
        /// A single point folds to a zero-size rect, which MapKit would show at maximum zoom.
        /// Padding it to a few hundred metres gives the same result a user expects from "fit".
        if union.size.width <= 0 || union.size.height <= 0 {
            let padding = MKMapPointsPerMeterAtLatitude(union.origin.coordinate.latitude) * 400
            union = union.insetBy(dx: -padding, dy: -padding)
        }
        mapView.setVisibleMapRect(
            union,
            edgePadding: NSEdgeInsets(top: 32, left: 32, bottom: 32, right: 32),
            animated: false
        )
    }

    // MARK: - MKMapViewDelegate

    /// The highlight is told apart from the base layer by identity, not by class: both are now
    /// aggregates of the same two types, and identity is also a constant-time question where
    /// searching the selection was linear in it.
    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if let multiPolygon = overlay as? MKMultiPolygon {
            let isHighlight = multiPolygon === highlightPolygonOverlay
            let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
            let color: NSColor = isHighlight ? .systemOrange : .controlAccentColor
            renderer.fillColor = color.withAlphaComponent(isHighlight ? 0.45 : 0.22)
            renderer.strokeColor = isHighlight ? color : color.withAlphaComponent(0.9)
            renderer.lineWidth = isHighlight ? 2.5 : 1
            return renderer
        }
        if let multiPolyline = overlay as? MKMultiPolyline {
            let isHighlight = multiPolyline === highlightPolylineOverlay
            let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
            renderer.strokeColor = isHighlight
                ? .systemOrange
                : NSColor.controlAccentColor.withAlphaComponent(0.9)
            renderer.lineWidth = isHighlight ? 4 : 2
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    /// MapKit asks this for a cluster it built as well as for a point, so both answers live here.
    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        if let cluster = annotation as? MKClusterAnnotation {
            return markerView(
                for: cluster,
                identifier: "result-map-cluster",
                selected: Self.holdsSelection(cluster, in: selectedRowIDs),
                in: mapView
            )
        }
        guard let point = annotation as? ResultMapAnnotation else { return nil }
        let view = markerView(
            for: point,
            identifier: "result-map-point",
            selected: selectedRowIDs.contains(point.rowID),
            in: mapView
        )
        /// Clustering is what keeps a result of many thousands of points from mounting a view per
        /// row, which is the shape that made SSMS's spatial tab exhaust its object quota.
        view.clusteringIdentifier = "result-map-point"
        view.setAccessibilityLabel(point.pointDescription)
        return view
    }

    private func markerView(
        for annotation: any MKAnnotation,
        identifier: String,
        selected: Bool,
        in mapView: MKMapView
    ) -> MKMarkerAnnotationView {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        view.animatesWhenAdded = false
        Self.tint(view, selected: selected)
        return view
    }

    /// macOS publishes the annotation-view variant; the annotation-typed overload is iOS 16 only
    /// and unavailable here.
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let point = view.annotation as? ResultMapAnnotation {
            onSelect(point.rowID)
            return
        }
        if let cluster = view.annotation as? MKClusterAnnotation,
           let first = cluster.memberAnnotations.compactMap({ $0 as? ResultMapAnnotation }).first
        {
            onSelect(first.rowID)
        }
    }

    // MARK: - Hit-testing

    /// Resolves a click to a row through `ResultMapHitTesting`, which asks each shape's renderer
    /// for its `CGPath`.
    ///
    /// This is the whole reason the pane is AppKit: it is the only route MapKit publishes to a
    /// polygon or polyline hit, and it costs 0.116ms over 20,000 shapes. The geometry lives in a
    /// pure type so it can be tested without a map view, which is what the first version could not
    /// be and why it shipped not working.
    private func handleClick(at point: NSPoint, in mapView: MKMapView) {
        /// An annotation reports its own selection through the delegate, so a click that lands on
        /// one is left alone rather than being resolved twice.
        if let hit = mapView.hitTest(mapView.convert(point, to: mapView.superview)),
           hit is MKAnnotationView || hit.superview is MKAnnotationView
        {
            return
        }
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let mapPoint = MKMapPoint(coordinate)
        let slop = Self.lineHitSlopPoints * mapView.visibleMapRect.width / Double(mapView.bounds.width)

        /// Topmost first, which means lines before polygons: `apply` adds the polyline overlay
        /// after the polygon one, so a line crossing a polygon is what the reader is pointing at.
        /// Testing polygons first selected the shape underneath the line they clicked.
        if let rowID = polylineHit(at: mapPoint, slop: slop) {
            onSelect(rowID)
            return
        }
        if let rowID = polygonHit(at: mapPoint) {
            onSelect(rowID)
            return
        }
        onSelect(nil)
    }

    private func polygonHit(at mapPoint: MKMapPoint) -> RowID? {
        guard let overlay = polygonOverlay,
              let index = ResultMapHitTesting.polygonIndex(at: mapPoint, in: overlay.polygons),
              index < polygonRowIDs.count
        else {
            return nil
        }
        return polygonRowIDs[index]
    }

    private func polylineHit(at mapPoint: MKMapPoint, slop: Double) -> RowID? {
        guard let overlay = polylineOverlay,
              let index = ResultMapHitTesting.polylineIndex(
                  at: mapPoint,
                  in: overlay.polylines,
                  slopInMapPoints: slop
              ),
              index < polylineRowIDs.count
        else {
            return nil
        }
        return polylineRowIDs[index]
    }

    // MARK: - Shape building

    private static func coordinate(_ value: GeographicCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
    }

    private static func polyline(_ run: [GeographicCoordinate]) -> MKPolyline {
        var coordinates = run.map(coordinate)
        return MKPolyline(coordinates: &coordinates, count: coordinates.count)
    }

    private static func polygon(_ rings: [[GeographicCoordinate]]) -> MKPolygon? {
        guard let exterior = rings.first, exterior.count >= 3 else { return nil }
        let holes: [MKPolygon] = rings.dropFirst().compactMap { ring in
            guard ring.count >= 3 else { return nil }
            var coordinates = ring.map(coordinate)
            return MKPolygon(coordinates: &coordinates, count: coordinates.count)
        }
        var coordinates = exterior.map(coordinate)
        return MKPolygon(
            coordinates: &coordinates,
            count: coordinates.count,
            interiorPolygons: holes.isEmpty ? nil : holes
        )
    }
}

/// A point row on the map. Carries its row so a click on the marker selects the same row a click on
/// a polygon would.
final class ResultMapAnnotation: NSObject, MKAnnotation {
    let rowID: RowID
    let coordinate: CLLocationCoordinate2D
    let pointDescription: String

    init(rowID: RowID, coordinate: CLLocationCoordinate2D) {
        self.rowID = rowID
        self.coordinate = coordinate
        pointDescription = String(
            format: String(localized: "Point at latitude %1$.5f, longitude %2$.5f"),
            coordinate.latitude,
            coordinate.longitude
        )
    }
}
