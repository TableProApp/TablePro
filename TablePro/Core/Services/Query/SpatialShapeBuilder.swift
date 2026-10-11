//
//  SpatialShapeBuilder.swift
//  TablePro
//

import Foundation
import TableProGeometry

/// Outside the projector's actor so one value can be drawn without queueing behind a page of rows.
enum SpatialShapeBuilder {
    /// `droppedParts` counts members that fail projection or have too few vertices for a line or a
    /// ring. A lost hole, an empty member and a budget cut are not counted.
    static func shapes(
        from geometry: SpatialGeometry,
        rowID: RowID,
        projectability: SpatialProjectability,
        budget: inout SpatialResultProjector.ShapeBudget
    ) -> (shapes: [ResultMapShape], droppedParts: Int) {
        var output = Output()
        append(geometry, rowID: rowID, projectability: projectability, depth: 1, budget: &budget, into: &output)
        return (output.shapes, output.droppedParts)
    }

    private struct Output {
        var shapes: [ResultMapShape] = []
        var droppedParts = 0
    }

    private static func append(
        _ geometry: SpatialGeometry,
        rowID: RowID,
        projectability: SpatialProjectability,
        depth: Int,
        budget: inout SpatialResultProjector.ShapeBudget,
        into output: inout Output
    ) {
        /// The same bound the readers apply, for the same reason: a collection nested past it is
        /// stack depth rather than geometry.
        guard depth <= SpatialLimits.maximumNestingDepth else {
            output.droppedParts += 1
            return
        }
        switch geometry {
        case .empty:
            return
        case .point(let point):
            guard let coordinate = SpatialProjection.project(point, using: projectability) else {
                output.droppedParts += 1
                return
            }
            guard budget.take(vertices: 1) else { return }
            output.shapes.append(ResultMapShape(rowID: rowID, kind: .point, rings: [[coordinate]]))
        case .multiPoint(let points):
            for point in points {
                guard let coordinate = SpatialProjection.project(point, using: projectability) else {
                    output.droppedParts += 1
                    continue
                }
                guard budget.take(vertices: 1) else { return }
                output.shapes.append(ResultMapShape(rowID: rowID, kind: .point, rings: [[coordinate]]))
            }
        case .lineString(let points):
            guard !points.isEmpty else { return }
            guard let run = project(points, using: projectability), run.count >= 2 else {
                output.droppedParts += 1
                return
            }
            guard budget.take(vertices: run.count) else { return }
            output.shapes.append(ResultMapShape(rowID: rowID, kind: .polyline, rings: [run]))
        case .multiLineString(let lines):
            for line in lines where !line.isEmpty {
                guard let run = project(line, using: projectability), run.count >= 2 else {
                    output.droppedParts += 1
                    continue
                }
                guard budget.take(vertices: run.count) else { return }
                output.shapes.append(ResultMapShape(rowID: rowID, kind: .polyline, rings: [run]))
            }
        case .polygon(let rings):
            guard hasExterior(rings) else { return }
            guard let projected = project(rings: rings, using: projectability) else {
                output.droppedParts += 1
                return
            }
            guard budget.take(vertices: vertexCount(of: projected)) else { return }
            output.shapes.append(ResultMapShape(rowID: rowID, kind: .polygon, rings: projected))
        case .multiPolygon(let polygons):
            for polygon in polygons where hasExterior(polygon) {
                guard let projected = project(rings: polygon, using: projectability) else {
                    output.droppedParts += 1
                    continue
                }
                guard budget.take(vertices: vertexCount(of: projected)) else { return }
                output.shapes.append(ResultMapShape(rowID: rowID, kind: .polygon, rings: projected))
            }
        case .collection(let children):
            for child in children {
                guard !budget.isExhausted else { return }
                append(
                    child,
                    rowID: rowID,
                    projectability: projectability,
                    depth: depth + 1,
                    budget: &budget,
                    into: &output
                )
            }
        }
    }

    private static func hasExterior(_ rings: [[SpatialPoint]]) -> Bool {
        !(rings.first?.isEmpty ?? true)
    }

    private static func vertexCount(of rings: [[GeographicCoordinate]]) -> Int {
        rings.reduce(0) { $0 + $1.count }
    }

    /// A run is dropped whole when any coordinate in it cannot be projected. Keeping the rest would
    /// draw a shape whose outline the database never described.
    private static func project(
        _ points: [SpatialPoint],
        using projectability: SpatialProjectability
    ) -> [GeographicCoordinate]? {
        var out: [GeographicCoordinate] = []
        out.reserveCapacity(points.count)
        for point in points {
            guard let coordinate = SpatialProjection.project(point, using: projectability) else { return nil }
            out.append(coordinate)
        }
        return out
    }

    private static func project(
        rings: [[SpatialPoint]],
        using projectability: SpatialProjectability
    ) -> [[GeographicCoordinate]]? {
        guard let exterior = rings.first, let projectedExterior = project(exterior, using: projectability),
              projectedExterior.count >= 3
        else {
            return nil
        }
        var out = [projectedExterior]
        /// A hole that cannot be projected is dropped while the polygon is kept: the exterior is
        /// still the shape the row describes, and losing a hole is a smaller lie than losing the
        /// row.
        for ring in rings.dropFirst() {
            guard let projected = project(ring, using: projectability), projected.count >= 3 else { continue }
            out.append(projected)
        }
        return out
    }
}
