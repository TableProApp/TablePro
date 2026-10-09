//
//  SpatialShapeBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProGeometry
import Testing

@testable import TablePro

struct SpatialShapeBuilderTests {
    private static let rowID: RowID = .existing(7)

    private static let triangle = [
        SpatialPoint(x: 10, y: 10),
        SpatialPoint(x: 11, y: 10),
        SpatialPoint(x: 11, y: 11),
        SpatialPoint(x: 10, y: 10),
    ]

    /// Longitude 181 is past the range a geographic system has, so the ring cannot be projected.
    private static let offTheMap = [
        SpatialPoint(x: 179, y: 50),
        SpatialPoint(x: 181, y: 50),
        SpatialPoint(x: 181, y: 51),
        SpatialPoint(x: 179, y: 50),
    ]

    private struct Built {
        let shapes: [ResultMapShape]
        let droppedParts: Int
        let isExhausted: Bool
    }

    private static func build(
        _ geometry: SpatialGeometry,
        projectability: SpatialProjectability = .geographic,
        shapes: Int = 100,
        vertices: Int = 1_000
    ) -> Built {
        var budget = SpatialResultProjector.ShapeBudget(shapes: shapes, vertices: vertices)
        let built = SpatialShapeBuilder.shapes(
            from: geometry,
            rowID: rowID,
            projectability: projectability,
            budget: &budget
        )
        return Built(shapes: built.shapes, droppedParts: built.droppedParts, isExhausted: budget.isExhausted)
    }

    @Test("A point becomes one shape tagged with the row it was given")
    func pointBecomesOneShape() {
        let built = Self.build(.point(SpatialPoint(x: -122.4194, y: 37.7749)))
        #expect(built.shapes.count == 1)
        #expect(built.shapes.first?.rowID == Self.rowID)
        #expect(built.shapes.first?.kind == .point)
        #expect(built.shapes.first?.rings == [[GeographicCoordinate(longitude: -122.4194, latitude: 37.7749)]])
        #expect(built.droppedParts == 0)
    }

    @Test("Web Mercator metres come back as degrees")
    func webMercatorIsInverted() {
        let built = Self.build(
            .point(SpatialPoint(x: -13_627_665.271218073, y: 4_547_675.354340557)),
            projectability: .webMercator
        )
        let coordinate = built.shapes.first?.rings.first?.first
        #expect(abs((coordinate?.longitude ?? 0) - -122.4194) < 1e-9)
        #expect(abs((coordinate?.latitude ?? 0) - 37.7749) < 1e-9)
    }

    /// The member used to be skipped with nothing counted, so a row drawn in part read as drawn.
    @Test("A multipolygon member that cannot be projected is counted")
    func multiPolygonMemberOffTheMapIsCounted() {
        let built = Self.build(.multiPolygon([[Self.offTheMap], [Self.triangle]]))
        #expect(built.shapes.count == 1)
        #expect(built.shapes.first?.kind == .polygon)
        #expect(built.droppedParts == 1)
    }

    @Test("A multipoint member that cannot be projected is counted")
    func multiPointMemberOffTheMapIsCounted() {
        let built = Self.build(.multiPoint([
            SpatialPoint(x: 1, y: 2),
            SpatialPoint(x: 500, y: 2),
            SpatialPoint(x: 3, y: 95),
        ]))
        #expect(built.shapes.count == 1)
        #expect(built.droppedParts == 2)
    }

    @Test("A line with one vertex and a ring with two are counted")
    func tooFewVerticesAreCounted() {
        let line = Self.build(.multiLineString([
            [SpatialPoint(x: 1, y: 1)],
            [SpatialPoint(x: 1, y: 1), SpatialPoint(x: 2, y: 2)],
        ]))
        #expect(line.shapes.count == 1)
        #expect(line.droppedParts == 1)

        let ring = Self.build(.multiPolygon([
            [[SpatialPoint(x: 0, y: 0), SpatialPoint(x: 10, y: 10)]],
            [Self.triangle],
        ]))
        #expect(ring.shapes.count == 1)
        #expect(ring.droppedParts == 1)
    }

    /// The exterior is still the shape the row describes, so a lost hole is not a lost part.
    @Test("A hole that cannot be projected is left out without being counted")
    func holeIsNotAPart() {
        let exterior = [
            SpatialPoint(x: 0, y: 0),
            SpatialPoint(x: 4, y: 0),
            SpatialPoint(x: 4, y: 4),
            SpatialPoint(x: 0, y: 0),
        ]
        let built = Self.build(.polygon(rings: [exterior, Self.offTheMap]))
        #expect(built.shapes.count == 1)
        #expect(built.shapes.first?.rings.count == 1)
        #expect(built.droppedParts == 0)
    }

    @Test("An empty member is not counted")
    func emptyMemberIsNotAPart() {
        let lines = Self.build(.multiLineString([[], [SpatialPoint(x: 1, y: 1), SpatialPoint(x: 2, y: 2)]]))
        #expect(lines.shapes.count == 1)
        #expect(lines.droppedParts == 0)

        let polygons = Self.build(.multiPolygon([[], [[]], [Self.triangle]]))
        #expect(polygons.shapes.count == 1)
        #expect(polygons.droppedParts == 0)

        let collection = Self.build(.collection([.empty, .point(SpatialPoint(x: 1, y: 2))]))
        #expect(collection.shapes.count == 1)
        #expect(collection.droppedParts == 0)
    }

    /// The budget has its own count. Reporting its cut here as well would say the same rows twice.
    @Test("What the budget cuts is not counted")
    func budgetCutIsNotAPart() {
        let points = (0 ..< 5).map { SpatialPoint(x: Double($0), y: 1) }
        let built = Self.build(.multiPoint(points), shapes: 2)
        #expect(built.shapes.count == 2)
        #expect(built.isExhausted)
        #expect(built.droppedParts == 0)
    }

    @Test("A collection counts each child that cannot be drawn, at any depth")
    func collectionChildrenAreCounted() {
        let built = Self.build(.collection([
            .point(SpatialPoint(x: 1, y: 2)),
            .point(SpatialPoint(x: 500, y: 2)),
            .collection([
                .lineString([SpatialPoint(x: 0, y: 0), SpatialPoint(x: 1, y: 1)]),
                .lineString([SpatialPoint(x: 0, y: 0)]),
            ]),
        ]))
        #expect(built.shapes.count == 2)
        #expect(built.droppedParts == 2)
        #expect(built.shapes.allSatisfy { $0.rowID == Self.rowID })
    }

    /// The builder only counts. Whether a value with no shape is unreadable, or has nothing to draw,
    /// is the caller's sentence to choose.
    @Test("A value that draws nothing reports no shapes and its failed part")
    func wholeValueThatFails() {
        let built = Self.build(.point(SpatialPoint(x: 37.7749, y: -122.4194)))
        #expect(built.shapes.isEmpty)
        #expect(built.droppedParts == 1)
    }

    @Test("A collection nested past the readers' bound is counted rather than dropped in silence")
    func nestingPastTheBoundIsCounted() {
        var withinBound = SpatialGeometry.point(SpatialPoint(x: 1, y: 2))
        for _ in 1 ..< SpatialLimits.maximumNestingDepth {
            withinBound = .collection([withinBound])
        }
        let kept = Self.build(withinBound)
        #expect(kept.shapes.count == 1)
        #expect(kept.droppedParts == 0)

        let pastBound = Self.build(.collection([withinBound]))
        #expect(pastBound.shapes.isEmpty)
        #expect(pastBound.droppedParts == 1)
    }

    @Test("An unsupported coordinate system draws nothing")
    func unsupportedSystemDrawsNothing() {
        let built = Self.build(.polygon(rings: [Self.triangle]), projectability: .unsupported(srid: 27_700))
        #expect(built.shapes.isEmpty)
    }
}
