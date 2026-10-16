//
//  ResultMapOverlayPaintTests.swift
//  TableProTests
//
//  The map's shape renderers held `controlAccentColor.withAlphaComponent(...)`, a color frozen at
//  the Accent and appearance current when it was made, so an Accent change left the shapes on the
//  old one until the next projection. Each color is now baked in the map view's own appearance and
//  baked again whenever the system colors move.
//

import AppKit
import MapKit
@testable import TablePro
import Testing

@MainActor
struct ResultMapOverlayPaintTests {
    private func baked(_ color: NSColor, alpha: CGFloat, in name: NSAppearance.Name) throws -> String {
        let appearance = try #require(NSAppearance(named: name))
        return try #require(ThemeTestFixture.hex(ThemeTestFixture.resolved(in: appearance) {
            color.withAlphaComponent(alpha).cgColor
        }))
    }

    private func hex(_ color: NSColor?) throws -> String {
        try #require(color.flatMap { HexColor.string(from: $0) })
    }

    @Test("A shape's colors are fixed values baked in the map's appearance, at the alphas it always drew")
    func paintIsBakedInTheAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            let polygon = ResultMapOverlayPaint.polygon(isHighlight: false, in: appearance)
            let highlight = ResultMapOverlayPaint.polygon(isHighlight: true, in: appearance)
            let line = ResultMapOverlayPaint.polyline(isHighlight: false, in: appearance)

            #expect(try hex(polygon.fill) == baked(.controlAccentColor, alpha: 0.22, in: name))
            #expect(try hex(polygon.stroke) == baked(.controlAccentColor, alpha: 0.9, in: name))
            #expect(try hex(highlight.fill) == baked(.systemOrange, alpha: 0.45, in: name))
            #expect(try hex(highlight.stroke) == baked(.systemOrange, alpha: 1, in: name))
            #expect(try hex(line.stroke) == baked(.controlAccentColor, alpha: 0.9, in: name))
            #expect(line.fill == nil)
            #expect(polygon.fill?.type == .componentBased, "a dynamic color would resolve wherever MapKit draws")
        }
    }

    @Test("The highlight is orange in each appearance's own shade")
    func highlightFollowsTheAppearance() throws {
        let light = ResultMapOverlayPaint.polygon(isHighlight: true, in: try #require(NSAppearance(named: .aqua)))
        let dark = ResultMapOverlayPaint.polygon(isHighlight: true, in: try #require(NSAppearance(named: .darkAqua)))
        #expect(try hex(light.stroke) != hex(dark.stroke))
    }

    @Test("A renderer the map asks for is painted in the map view's appearance")
    func rendererTakesTheMapsAppearance() throws {
        let coordinator = ResultMapCoordinator(onSelect: { _ in })
        let coordinates = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
        ]
        let overlay = MKMultiPolygon([MKPolygon(coordinates: coordinates, count: coordinates.count)])

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let mapView = MKMapView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            mapView.appearance = try #require(NSAppearance(named: name))
            let renderer = try #require(coordinator.mapView(mapView, rendererFor: overlay) as? MKOverlayPathRenderer)
            let expected = ResultMapOverlayPaint.polygon(isHighlight: false, in: mapView.effectiveAppearance)

            #expect(try hex(renderer.fillColor) == hex(expected.fill))
            #expect(try hex(renderer.strokeColor) == hex(expected.stroke))
            #expect(renderer.lineWidth == expected.lineWidth)
        }
    }
}
