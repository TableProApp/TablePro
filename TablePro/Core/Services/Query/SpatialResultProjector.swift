//
//  SpatialResultProjector.swift
//  TablePro
//

import Foundation
import TableProGeometry
import TableProPluginKit

/// Turns one spatial column of a loaded result into drawable shapes, off the main thread.
///
/// An actor for the same reason `ResultChartProjector` is one: the work is proportional to the
/// loaded page, which reaches 100,000 rows, and it must be cancellable so a page turn does not
/// queue behind the page it replaced.
actor SpatialResultProjector {
    static let shared = SpatialResultProjector()

    /// Budgets, measured rather than guessed.
    ///
    /// One `MKMultiPolygon` holding 200,000 rings costs 0.089s to add against 125s for the same
    /// rings as separate overlays, so the aggregate has no practical shape cap inside TablePro's
    /// own 100,000-row page limit. What does bind is total vertices: one 200,000-vertex
    /// multipolygon costs more than 10,000 points do.
    static let maximumShapes = 100_000
    static let maximumVertices = 2_000_000

    func project(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        column: SpatialColumn
    ) async -> ResultMapProjection {
        let order = displayIDs ?? tableRows.rows.map(\.id)
        var values: [(rowID: RowID, value: SpatialValue)] = []
        values.reserveCapacity(order.count)

        var diagnostics = ResultMapDiagnostics()
        var sridCounts: [Int32?: Int] = [:]

        for rowID in order {
            if Task.isCancelled { return ResultMapProjection() }
            diagnostics.consideredRows += 1
            guard let index = tableRows.index(of: rowID),
                  column.index < tableRows.rows[index].values.count
            else {
                continue
            }
            guard let text = Self.text(of: tableRows.rows[index][column.index]) else {
                diagnostics.emptyRows += 1
                continue
            }
            switch SpatialValueReader.read(text) {
            case .success(let value):
                guard !value.geometry.isEmpty else {
                    diagnostics.emptyRows += 1
                    continue
                }
                values.append((rowID, value))
                sridCounts[value.srid, default: 0] += 1
            case .failure(.unsupportedGeometryType(let keyword)):
                diagnostics.unsupportedTypes[keyword, default: 0] += 1
            case .failure:
                diagnostics.unreadableRows += 1
            }
        }

        guard let majority = Self.majoritySRID(in: sridCounts) else {
            diagnostics.projectability = .unsupported(srid: nil)
            return ResultMapProjection(shapes: [], diagnostics: diagnostics)
        }

        let drawable = values.filter { $0.value.srid == majority }
        diagnostics.otherSRIDRows = values.count - drawable.count
        diagnostics.drawnSRID = majority

        /// Projectability is decided from the whole drawable set, not per row, because the
        /// no-SRID case asks whether every coordinate fits the longitude/latitude envelope and one
        /// stray row is enough to mean the column is not degrees.
        let projectability = Self.projectability(of: drawable.map(\.value), srid: majority)
        diagnostics.projectability = projectability
        guard projectability != .unsupported(srid: majority) else {
            return ResultMapProjection(shapes: [], diagnostics: diagnostics)
        }

        var shapes: [ResultMapShape] = []
        var vertices = 0
        var drawnRowIDs = Set<RowID>()
        var capped = 0

        for entry in drawable {
            if Task.isCancelled { return ResultMapProjection() }
            guard shapes.count < Self.maximumShapes, vertices < Self.maximumVertices else {
                capped += 1
                continue
            }
            var produced: [ResultMapShape] = []
            Self.appendShapes(
                from: entry.value.geometry,
                rowID: entry.rowID,
                projectability: projectability,
                into: &produced
            )
            guard !produced.isEmpty else {
                diagnostics.unreadableRows += 1
                continue
            }
            for shape in produced {
                vertices += shape.rings.reduce(0) { $0 + $1.count }
            }
            shapes.append(contentsOf: produced)
            drawnRowIDs.insert(entry.rowID)
        }

        diagnostics.shapesAndRows(shapes.count, drawnRowIDs.count)
        diagnostics.cappedRows = capped > 0 ? capped : nil
        return ResultMapProjection(shapes: shapes, diagnostics: diagnostics)
    }

    /// The SRID most of the column uses. Everything else is reported rather than drawn, because a
    /// map cannot show two coordinate systems at once and silently mixing them puts shapes in the
    /// wrong place.
    static func majoritySRID(in counts: [Int32?: Int]) -> Int32?? {
        guard !counts.isEmpty else { return nil }
        let winner = counts.max { left, right in
            if left.value != right.value { return left.value < right.value }
            /// A tie is broken toward the named SRID, since an explicit one is better evidence
            /// than an absent one.
            return (left.key ?? Int32.min) < (right.key ?? Int32.min)
        }
        return winner.map(\.key)
    }

    static func projectability(of values: [SpatialValue], srid: Int32?) -> SpatialProjectability {
        guard srid == nil else {
            return SpatialProjection.projectability(srid: srid, geometry: .empty)
        }
        for value in values where !SpatialProjection.fitsGeographicEnvelope(value.geometry) {
            return .unsupported(srid: nil)
        }
        return values.isEmpty ? .unsupported(srid: nil) : .assumedGeographic
    }

    private static func appendShapes(
        from geometry: SpatialGeometry,
        rowID: RowID,
        projectability: SpatialProjectability,
        into shapes: inout [ResultMapShape]
    ) {
        switch geometry {
        case .empty:
            return
        case .point(let point):
            guard let coordinate = SpatialProjection.project(point, using: projectability) else { return }
            shapes.append(ResultMapShape(rowID: rowID, kind: .point, rings: [[coordinate]]))
        case .multiPoint(let points):
            for point in points {
                guard let coordinate = SpatialProjection.project(point, using: projectability) else { continue }
                shapes.append(ResultMapShape(rowID: rowID, kind: .point, rings: [[coordinate]]))
            }
        case .lineString(let points):
            guard let run = project(points, using: projectability), run.count >= 2 else { return }
            shapes.append(ResultMapShape(rowID: rowID, kind: .polyline, rings: [run]))
        case .multiLineString(let lines):
            for line in lines {
                guard let run = project(line, using: projectability), run.count >= 2 else { continue }
                shapes.append(ResultMapShape(rowID: rowID, kind: .polyline, rings: [run]))
            }
        case .polygon(let rings):
            guard let projected = project(rings: rings, using: projectability) else { return }
            shapes.append(ResultMapShape(rowID: rowID, kind: .polygon, rings: projected))
        case .multiPolygon(let polygons):
            for polygon in polygons {
                guard let projected = project(rings: polygon, using: projectability) else { continue }
                shapes.append(ResultMapShape(rowID: rowID, kind: .polygon, rings: projected))
            }
        case .collection(let children):
            for child in children {
                appendShapes(from: child, rowID: rowID, projectability: projectability, into: &shapes)
            }
        }
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

    /// A binary cell is handed over as uppercase hex, which is what the WKB reader expects and what
    /// PostgreSQL's own text format for an unrewritten geometry already looks like.
    private static func text(of value: PluginCellValue) -> String? {
        switch value {
        case .null:
            return nil
        case .text(let text):
            return text.isEmpty ? nil : text
        case .bytes(let data):
            return data.isEmpty ? nil : value.sortKey
        }
    }
}

private extension ResultMapDiagnostics {
    mutating func shapesAndRows(_ shapes: Int, _ rows: Int) {
        drawnShapes = shapes
        drawnRows = rows
    }
}
