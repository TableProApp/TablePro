//
//  ResultMapHitTestingTests.swift
//  TableProTests
//

import MapKit
import Testing

@testable import TablePro

/// Click-to-select is half the request in #2532, and the first implementation shipped it inside the
/// coordinator where only a running app could reach it. It did not work, and nothing said so. The
/// hit test is pure now so this suite can prove it without a map view: a renderer's `path` and its
/// `point(for:)` both work unattached.
@Suite("ResultMapHitTesting")
@MainActor
struct ResultMapHitTestingTests {
    /// Six separated boxes over San Francisco, in the same shape the projector produces.
    private func boxes() -> [MKPolygon] {
        let corners: [(Double, Double)] = [
            (37.748, -122.425), (37.770, -122.411), (37.772, -122.510),
            (37.738, -122.510), (37.789, -122.421), (37.720, -122.400),
        ]
        return corners.map { latitude, longitude in
            var ring = [
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude + 0.012),
                CLLocationCoordinate2D(latitude: latitude + 0.010, longitude: longitude + 0.012),
                CLLocationCoordinate2D(latitude: latitude + 0.010, longitude: longitude),
            ]
            return MKPolygon(coordinates: &ring, count: ring.count)
        }
    }

    private func centre(of polygon: MKPolygon) -> MKMapPoint {
        let rect = polygon.boundingMapRect
        return MKMapPoint(x: rect.midX, y: rect.midY)
    }

    @Test("Every polygon's centre resolves back to that polygon")
    func centresRoundTrip() {
        let polygons = boxes()
        for (index, polygon) in polygons.enumerated() {
            #expect(
                ResultMapHitTesting.polygonIndex(at: centre(of: polygon), in: polygons) == index,
                "polygon \(index) must resolve to itself"
            )
        }
    }

    @Test("A point outside every polygon resolves to nothing")
    func missResolvesToNil() {
        let far = MKMapPoint(CLLocationCoordinate2D(latitude: 51.5072, longitude: -0.1276))
        #expect(ResultMapHitTesting.polygonIndex(at: far, in: boxes()) == nil)
    }

    @Test("An empty overlay list is a miss rather than a crash")
    func emptyListIsAMiss() {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194))
        #expect(ResultMapHitTesting.polygonIndex(at: point, in: []) == nil)
        #expect(ResultMapHitTesting.polylineIndex(at: point, in: [], slopInMapPoints: 100) == nil)
    }

    /// Later shapes draw over earlier ones, so an overlap resolves to the one the reader can see.
    @Test("Overlapping polygons resolve to the topmost")
    func overlapPrefersTheTopmost() {
        var ring = [
            CLLocationCoordinate2D(latitude: 37.75, longitude: -122.45),
            CLLocationCoordinate2D(latitude: 37.75, longitude: -122.40),
            CLLocationCoordinate2D(latitude: 37.80, longitude: -122.40),
            CLLocationCoordinate2D(latitude: 37.80, longitude: -122.45),
        ]
        let lower = MKPolygon(coordinates: &ring, count: ring.count)
        let upper = MKPolygon(coordinates: &ring, count: ring.count)
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: 37.775, longitude: -122.425))
        #expect(ResultMapHitTesting.polygonIndex(at: point, in: [lower, upper]) == 1)
    }

    /// A hole is not part of the shape, so a click inside one must miss the polygon that owns it.
    @Test("A click inside a hole misses the polygon")
    func holeIsNotPartOfTheShape() {
        var outer = [
            CLLocationCoordinate2D(latitude: 37.70, longitude: -122.50),
            CLLocationCoordinate2D(latitude: 37.70, longitude: -122.36),
            CLLocationCoordinate2D(latitude: 37.82, longitude: -122.36),
            CLLocationCoordinate2D(latitude: 37.82, longitude: -122.50),
        ]
        var inner = [
            CLLocationCoordinate2D(latitude: 37.75, longitude: -122.45),
            CLLocationCoordinate2D(latitude: 37.75, longitude: -122.41),
            CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41),
            CLLocationCoordinate2D(latitude: 37.78, longitude: -122.45),
        ]
        let hole = MKPolygon(coordinates: &inner, count: inner.count)
        let ring = MKPolygon(coordinates: &outer, count: outer.count, interiorPolygons: [hole])

        let insideHole = MKMapPoint(CLLocationCoordinate2D(latitude: 37.765, longitude: -122.43))
        let insideRing = MKMapPoint(CLLocationCoordinate2D(latitude: 37.715, longitude: -122.43))
        #expect(ResultMapHitTesting.polygonIndex(at: insideHole, in: [ring]) == nil)
        #expect(ResultMapHitTesting.polygonIndex(at: insideRing, in: [ring]) == 0)
    }

    @Test("A click on a line hits it, and one well off it does not")
    func polylineTolerance() {
        var run = [
            CLLocationCoordinate2D(latitude: 37.75, longitude: -122.45),
            CLLocationCoordinate2D(latitude: 37.79, longitude: -122.39),
        ]
        let line = MKPolyline(coordinates: &run, count: run.count)
        let onLine = MKMapPoint(CLLocationCoordinate2D(latitude: 37.77, longitude: -122.42))
        let offLine = MKMapPoint(CLLocationCoordinate2D(latitude: 37.72, longitude: -122.50))

        #expect(ResultMapHitTesting.polylineIndex(at: onLine, in: [line], slopInMapPoints: 300) == 0)
        #expect(ResultMapHitTesting.polylineIndex(at: offLine, in: [line], slopInMapPoints: 300) == nil)
    }
}
