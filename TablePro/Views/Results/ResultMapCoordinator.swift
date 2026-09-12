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

    private var clickRecognizer: NSClickGestureRecognizer?
    private var appliedProjection: ResultMapProjection?
    private var appliedToken: Int?
    private var polygonOverlay: MKMultiPolygon?
    private var polylineOverlay: MKMultiPolyline?
    private var highlightOverlays: [MKOverlay] = []
    private var pointAnnotations: [ResultMapAnnotation] = []
    /// Parallel to the member order inside each aggregate overlay, so a hit resolves to a row by
    /// index rather than by searching.
    private var polygonRowIDs: [RowID] = []
    private var polylineRowIDs: [RowID] = []
    private var lastFitToken: Int?

    init(onSelect: @escaping (RowID?) -> Void) {
        self.onSelect = onSelect
    }

    func attach(to mapView: MKMapView) {
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        /// Delaying nothing keeps panning and zooming exactly as MapKit implements them; the
        /// recognizer only ever reports a completed click.
        recognizer.delaysPrimaryMouseButtonEvents = false
        mapView.addGestureRecognizer(recognizer)
        clickRecognizer = recognizer
    }

    func detach(from mapView: MKMapView) {
        if let clickRecognizer { mapView.removeGestureRecognizer(clickRecognizer) }
        clickRecognizer = nil
        mapView.delegate = nil
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        appliedProjection = nil
        appliedToken = nil
        polygonOverlay = nil
        polylineOverlay = nil
        highlightOverlays = []
        pointAnnotations = []
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
        highlightOverlays = []

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
        mapView.removeOverlays(highlightOverlays)
        highlightOverlays = []
        guard !rowIDs.isEmpty, let projection = appliedProjection else { return }

        var highlights: [MKOverlay] = []
        for shape in projection.shapes where rowIDs.contains(shape.rowID) {
            switch shape.kind {
            case .point:
                continue
            case .polyline:
                guard let run = shape.rings.first, run.count >= 2 else { continue }
                highlights.append(Self.polyline(run))
            case .polygon:
                guard let polygon = Self.polygon(shape.rings) else { continue }
                highlights.append(polygon)
            }
        }
        guard !highlights.isEmpty else { return }
        highlightOverlays = highlights
        mapView.addOverlays(highlights, level: .aboveLabels)
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

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        let isHighlight = highlightOverlays.contains { $0 === overlay }
        if let multiPolygon = overlay as? MKMultiPolygon {
            let renderer = MKMultiPolygonRenderer(multiPolygon: multiPolygon)
            renderer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.22)
            renderer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9)
            renderer.lineWidth = 1
            return renderer
        }
        if let multiPolyline = overlay as? MKMultiPolyline {
            let renderer = MKMultiPolylineRenderer(multiPolyline: multiPolyline)
            renderer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9)
            renderer.lineWidth = 2
            return renderer
        }
        if let polygon = overlay as? MKPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = NSColor.systemOrange.withAlphaComponent(isHighlight ? 0.45 : 0.22)
            renderer.strokeColor = .systemOrange
            renderer.lineWidth = 2.5
            return renderer
        }
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemOrange
            renderer.lineWidth = 4
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        guard let point = annotation as? ResultMapAnnotation else { return nil }
        let identifier = "result-map-point"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
            as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
        view.annotation = annotation
        /// Clustering is what keeps a result of many thousands of points from mounting a view per
        /// row, which is the shape that made SSMS's spatial tab exhaust its object quota.
        view.clusteringIdentifier = identifier
        view.markerTintColor = .controlAccentColor
        view.animatesWhenAdded = false
        view.displayPriority = .defaultLow
        view.setAccessibilityLabel(point.pointDescription)
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

    /// Resolves a click to a row by asking each aggregate overlay's renderer for its `CGPath`.
    ///
    /// This is the whole reason the pane is AppKit: it is the only route MapKit publishes to a
    /// polygon or polyline hit, and it costs 0.116ms over 20,000 shapes.
    @objc
    private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let mapView = recognizer.view as? MKMapView else { return }
        let point = recognizer.location(in: mapView)
        /// An annotation reports its own selection through the delegate, so a click that lands on
        /// one is left alone rather than being resolved twice.
        if mapView.annotations(in: mapView.visibleMapRect).isEmpty == false,
           let hit = mapView.hitTest(mapView.convert(point, to: mapView.superview)),
           hit is MKAnnotationView || hit.superview is MKAnnotationView
        {
            return
        }
        let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        let mapPoint = MKMapPoint(coordinate)
        let slop = Self.lineHitSlopPoints * mapView.visibleMapRect.width / Double(mapView.bounds.width)

        if let rowID = polygonHit(at: mapPoint, in: mapView) {
            onSelect(rowID)
            return
        }
        if let rowID = polylineHit(at: mapPoint, slop: slop, in: mapView) {
            onSelect(rowID)
            return
        }
        onSelect(nil)
    }

    private func polygonHit(at mapPoint: MKMapPoint, in mapView: MKMapView) -> RowID? {
        guard let overlay = polygonOverlay, mapView.renderer(for: overlay) != nil else { return nil }
        /// Later shapes draw over earlier ones, so the topmost match is the one the user clicked.
        /// The bounding-rect test comes first because it rejects almost every member for the cost
        /// of a comparison, which is what keeps this at a fraction of a millisecond over 20,000
        /// shapes.
        for (index, polygon) in overlay.polygons.enumerated().reversed()
            where polygon.boundingMapRect.contains(mapPoint)
        {
            let renderer = MKPolygonRenderer(polygon: polygon)
            guard let path = renderer.path, path.contains(renderer.point(for: mapPoint)) else { continue }
            guard index < polygonRowIDs.count else { continue }
            return polygonRowIDs[index]
        }
        return nil
    }

    private func polylineHit(at mapPoint: MKMapPoint, slop: Double, in mapView: MKMapView) -> RowID? {
        guard let overlay = polylineOverlay else { return nil }
        let padded = MKMapRect(
            x: mapPoint.x - slop,
            y: mapPoint.y - slop,
            width: slop * 2,
            height: slop * 2
        )
        for (index, polyline) in overlay.polylines.enumerated().reversed()
            where polyline.boundingMapRect.intersects(padded)
        {
            let renderer = MKPolylineRenderer(polyline: polyline)
            guard let cgPath = renderer.path else { continue }
            let localSlop = abs(renderer.point(for: MKMapPoint(x: mapPoint.x + slop, y: mapPoint.y)).x
                - renderer.point(for: mapPoint).x)
            let stroked = cgPath.copy(strokingWithWidth: max(localSlop * 2, 1), lineCap: .round, lineJoin: .round, miterLimit: 1)
            guard stroked.contains(renderer.point(for: mapPoint)) else { continue }
            guard index < polylineRowIDs.count else { continue }
            return polylineRowIDs[index]
        }
        return nil
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
