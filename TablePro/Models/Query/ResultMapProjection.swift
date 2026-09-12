//
//  ResultMapProjection.swift
//  TablePro
//

import Foundation
import TableProGeometry
import TableProPluginKit

/// One drawable shape, already in WGS84 degrees, tagged with the row it came from.
///
/// Deliberately not an `MKShape`: those are classes, are not `Sendable`, and would have to cross
/// an actor boundary. The expensive half of the work is reading and projecting thousands of
/// strings, and that is what this type carries off the main thread; building the MapKit objects
/// from flat coordinates is a copy and happens where they are drawn.
///
/// One row can produce several shapes, and every one of them keeps the same `rowID`, so a click on
/// any part of a multipolygon selects the row that owns it.
struct ResultMapShape: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case point
        case polyline
        case polygon
    }

    let rowID: RowID
    let kind: Kind
    /// A point carries one coordinate, a polyline one run, a polygon its exterior ring followed by
    /// any holes.
    let rings: [[GeographicCoordinate]]
}

/// What the map could not draw, and why, in the terms the pane has to say out loud.
struct ResultMapDiagnostics: Sendable, Equatable {
    var drawnShapes = 0
    var drawnRows = 0
    var consideredRows = 0
    /// The coordinate system the drawn shapes are in, and how it was handled.
    var projectability: SpatialProjectability = .unsupported(srid: nil)
    var drawnSRID: Int32?
    /// Rows whose geometry is in a different coordinate system from the majority, so they are not
    /// drawn. Counted rather than silently skipped: drawing fewer shapes with no explanation is
    /// pgAdmin's shipped behaviour and users hit it.
    var otherSRIDRows = 0
    /// Keyword to row count, for types no parser turns into line segments.
    var unsupportedTypes: [String: Int] = [:]
    var unreadableRows = 0
    var emptyRows = 0
    /// Rows past the shape or vertex budget. Nil when nothing was capped.
    var cappedRows: Int?

    var hasAnythingToReport: Bool {
        otherSRIDRows > 0 || !unsupportedTypes.isEmpty || unreadableRows > 0 || cappedRows != nil
    }
}

struct ResultMapProjection: Sendable, Equatable {
    var shapes: [ResultMapShape] = []
    var diagnostics = ResultMapDiagnostics()

    /// The first shape index belonging to each row, so a click resolves to a row without a scan.
    var rowIDByShapeIndex: [RowID] {
        shapes.map(\.rowID)
    }

    var isEmpty: Bool { shapes.isEmpty }
}
