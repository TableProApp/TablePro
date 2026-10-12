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
    /// drawn. Counted rather than silently skipped.
    var otherSRIDRows = 0
    /// Keyword to row count, for types no parser turns into line segments.
    var unsupportedTypes: [String: Int] = [:]
    var unreadableRows = 0
    var emptyRows = 0
    /// Rows whose value read as a non-empty geometry, whatever happened to it afterwards. The pane
    /// asks this before it blames the coordinate system: `projectability` carries
    /// `.unsupported(srid: nil)` as its own default, so a column where nothing parsed is
    /// indistinguishable from one whose SRID cannot be projected until this says which.
    var readableRows = 0
    /// Rows past the shape or vertex budget. Nil when nothing was capped.
    var cappedRows: Int?
    /// Members of drawn rows that are not on the map: coordinates that cannot be projected, or too
    /// few vertices for a line or a ring. A row that drew nothing is in `unreadableRows` instead.
    var droppedParts = 0

    var hasAnythingToReport: Bool {
        otherSRIDRows > 0 || !unsupportedTypes.isEmpty || unreadableRows > 0 || cappedRows != nil
            || droppedParts > 0
    }
}

extension ResultMapDiagnostics {
    /// What the map is showing and what it left out, as a sentence rather than a count on its own.
    var statusText: String {
        var parts: [String] = []
        if let srid = drawnSRID {
            parts.append(String(
                format: String(localized: "Drawing %1$d shapes in SRID %2$d."),
                drawnShapes,
                Int(srid)
            ))
        } else if case .assumedGeographic = projectability {
            parts.append(String(
                format: String(localized: "Drawing %d shapes with no SRID, read as longitude and latitude."),
                drawnShapes
            ))
        } else {
            parts.append(String(format: String(localized: "Drawing %d shapes."), drawnShapes))
        }
        if otherSRIDRows > 0 {
            parts.append(String(
                format: String(localized: "%d rows in other coordinate systems are not drawn."),
                otherSRIDRows
            ))
        }
        if let cappedRows {
            parts.append(String(format: String(localized: "%d rows are past the drawing limit."), cappedRows))
        }
        if droppedParts == 1 {
            parts.append(String(localized: "1 part of a multi-part geometry cannot be drawn and is left out."))
        } else if droppedParts > 1 {
            parts.append(String(
                format: String(localized: "%d parts of multi-part geometries cannot be drawn and are left out."),
                droppedParts
            ))
        }
        for (keyword, count) in unsupportedTypes.sorted(by: { $0.key < $1.key }) {
            parts.append(String(
                format: String(localized: "%1$d rows use %2$@, which cannot be drawn."),
                count,
                keyword
            ))
        }
        if unreadableRows > 0 {
            parts.append(String(format: String(localized: "%d rows could not be read."), unreadableRows))
        }
        return parts.joined(separator: " ")
    }

    /// Why a result with a geometry column still drew nothing. Always names the reason, so the
    /// pane is never a blank map.
    var emptyReason: String {
        /// What the values were is asked before what coordinate system they were in, because
        /// `projectability` carries `.unsupported(srid: nil)` as its own default: a column where
        /// nothing parsed reaches here looking exactly like one whose SRID cannot be projected, and
        /// it used to be told it had coordinates outside the range of longitude and latitude.
        if readableRows == 0 {
            if !unsupportedTypes.isEmpty {
                let names = unsupportedTypes.keys.sorted().joined(separator: ", ")
                return String(
                    format: String(localized: "This column holds %@, which the map cannot draw."),
                    names
                )
            }
            if unreadableRows > 0 {
                return String(
                    format: String(localized: """
                    %d values in this column are not in a format the map can read. The grid still \
                    shows them as the database returned them.
                    """),
                    unreadableRows
                )
            }
            return String(localized: "Every geometry in this column is empty or null.")
        }
        if case .unsupported(let srid) = projectability {
            guard let srid else {
                return String(localized: """
                This column carries no SRID and its coordinates are outside the range of longitude and \
                latitude, so the map cannot place them.
                """)
            }
            /// Says what the map can place rather than calling the SRID projected: an unlisted SRID
            /// can be a geographic one.
            return GeometryFieldPreview.Reason.unsupportedSRID(srid).message
                + " " + String(localized: "Query ST_Transform(geom, 4326) to see these shapes.")
        }
        /// The values read and their coordinate system is supported, so they are not empty or null.
        return String(localized: """
        Nothing in this column can be drawn. The coordinates are out of range for their coordinate \
        system, or a line or ring has too few points.
        """)
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
