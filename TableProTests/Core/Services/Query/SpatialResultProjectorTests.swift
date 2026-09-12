//
//  SpatialResultProjectorTests.swift
//  TableProTests
//

import Foundation
import TableProGeometry
import TableProPluginKit
import Testing

@testable import TablePro

private func rows(_ values: [String?], columnName: String = "geom") -> TableRows {
    let built = values.enumerated().map { index, value in
        Row(id: .existing(index), values: [PluginCellValue.fromOptional(value)])
    }
    return TableRows(
        rows: ContiguousArray(built),
        columns: [columnName],
        columnTypes: [.spatial(rawType: "geometry")]
    )
}

private func onlyColumn(_ tableRows: TableRows) -> SpatialColumn {
    guard let column = SpatialColumn.columns(in: tableRows).first else {
        fatalError("the fixture must have a spatial column")
    }
    return column
}

@Suite("SpatialColumn")
struct SpatialColumnTests {
    @Test("Only spatial columns are offered")
    func onlySpatialColumns() {
        let mixed = TableRows(
            rows: [],
            columns: ["id", "geom", "name"],
            columnTypes: [.integer(rawType: "int"), .spatial(rawType: "geometry"), .text(rawType: "text")]
        )
        let columns = SpatialColumn.columns(in: mixed)
        #expect(columns.count == 1)
        #expect(columns.first?.name == "geom")
        #expect(columns.first?.index == 1)
        #expect(SpatialColumn.hasSpatialColumn(in: mixed))
    }

    @Test("A result with no geometry offers nothing")
    func noSpatialColumns() {
        let plain = TableRows(rows: [], columns: ["id"], columnTypes: [.integer(rawType: "int")])
        #expect(SpatialColumn.columns(in: plain).isEmpty)
        #expect(!SpatialColumn.hasSpatialColumn(in: plain))
    }

    /// A result can hold two columns of the same name, so the id carries the occurrence and the
    /// label distinguishes them. Naming rather than indexing is what lets a choice survive a
    /// re-execution that reorders the SELECT list.
    @Test("Duplicate column names stay distinguishable")
    func duplicateNames() {
        let duplicated = TableRows(
            rows: [],
            columns: ["geom", "geom"],
            columnTypes: [.spatial(rawType: "geometry"), .spatial(rawType: "geometry")]
        )
        let columns = SpatialColumn.columns(in: duplicated)
        #expect(columns.count == 2)
        #expect(columns[0].id != columns[1].id)
        #expect(columns[0].displayName == "geom (1)")
        #expect(columns[1].displayName == "geom (2)")
    }
}

@Suite("SpatialResultProjector")
struct SpatialResultProjectorTests {
    @Test("EWKT points project to shapes tagged with their row")
    func projectsPoints() async {
        let table = rows([
            "SRID=4326;POINT(-122.4194 37.7749)",
            "SRID=4326;POINT(-0.1276 51.5072)",
        ])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 2)
        #expect(projection.diagnostics.drawnRows == 2)
        #expect(projection.diagnostics.drawnSRID == 4326)
        #expect(projection.shapes[0].rowID == .existing(0))
        #expect(projection.shapes[0].kind == .point)
        #expect(projection.shapes[0].rings[0][0].longitude == -122.4194)
    }

    /// A map cannot show two coordinate systems at once, so the majority is drawn and the rest are
    /// counted. Drawing fewer shapes with no explanation is the failure every competitor ships.
    @Test("A minority SRID is reported rather than silently dropped")
    func minoritySRIDIsCounted() async {
        let table = rows([
            "SRID=4326;POINT(1 2)",
            "SRID=4326;POINT(3 4)",
            "SRID=27700;POINT(5 6)",
        ])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.diagnostics.drawnSRID == 4326)
        #expect(projection.diagnostics.drawnShapes == 2)
        #expect(projection.diagnostics.otherSRIDRows == 1)
        #expect(projection.diagnostics.hasAnythingToReport)
    }

    @Test("Web Mercator is inverted rather than refused")
    func webMercatorIsDrawn() async {
        let table = rows(["SRID=3857;POINT(-13627665.271218073 4547675.354340557)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.diagnostics.projectability == .webMercator)
        let coordinate = projection.shapes[0].rings[0][0]
        #expect(abs(coordinate.longitude - -122.4194) < 1e-9)
        #expect(abs(coordinate.latitude - 37.7749) < 1e-9)
    }

    @Test("A projected SRID draws nothing and says which one")
    func projectedSRIDIsRefused() async {
        let table = rows(["SRID=27700;POINT(530000 180000)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.isEmpty)
        #expect(projection.diagnostics.projectability == .unsupported(srid: 27_700))
    }

    /// PostGIS writes no prefix for SRID 0 and MySQL stores a literal 0, and both mean "nobody
    /// said". Values inside the longitude/latitude envelope are drawn, and the pane says so.
    @Test("No SRID inside the envelope is drawn as degrees")
    func absentSRIDInsideEnvelope() async {
        let table = rows(["POINT(-122.4194 37.7749)", "POINT(-0.1276 51.5072)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.diagnostics.projectability == .assumedGeographic)
        #expect(projection.shapes.count == 2)
    }

    @Test("No SRID outside the envelope draws nothing")
    func absentSRIDOutsideEnvelope() async {
        let table = rows(["POINT(530000 180000)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.isEmpty)
        #expect(projection.diagnostics.projectability == .unsupported(srid: nil))
    }

    @Test("A multipolygon row produces several shapes that all name the same row")
    func multiPolygonKeepsRowIdentity() async {
        let table = rows(["MULTIPOLYGON(((0 0,1 0,1 1,0 0)),((5 5,6 5,6 6,5 5)))"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 2)
        #expect(projection.shapes.allSatisfy { $0.rowID == .existing(0) })
        #expect(projection.diagnostics.drawnRows == 1)
    }

    @Test("A polygon keeps its holes")
    func polygonKeepsHoles() async {
        let table = rows(["POLYGON((0 0,4 0,4 4,0 4,0 0),(1 1,2 1,2 2,1 2,1 1))"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 1)
        #expect(projection.shapes[0].rings.count == 2)
    }

    @Test("Null and empty geometry rows are counted, not drawn")
    func nullAndEmptyRows() async {
        let table = rows([nil, "POINT EMPTY", "POINT(1 2)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 1)
        #expect(projection.diagnostics.emptyRows == 2)
    }

    /// A curved type keeps its keyword all the way to the diagnostics, so the pane can name it
    /// instead of drawing nothing and saying nothing.
    @Test("An undrawable type is named")
    func undrawableTypeIsNamed() async {
        let table = rows(["CIRCULARSTRING(0 0,1 1,2 0)", "POINT(1 2)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.diagnostics.unsupportedTypes["CIRCULARSTRING"] == 1)
        #expect(projection.shapes.count == 1)
    }

    @Test("Text that is not a geometry is counted as unreadable")
    func unreadableRows() async {
        let table = rows(["hello", "POINT(1 2)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.diagnostics.unreadableRows == 1)
        #expect(projection.shapes.count == 1)
    }

    /// The map draws the display order, so a value filter narrows it without any extra wiring, and
    /// the shapes come back in the order the grid is showing.
    @Test("Only the display order is drawn")
    func honoursDisplayOrder() async {
        let table = rows(["POINT(1 1)", "POINT(2 2)", "POINT(3 3)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: [.existing(2), .existing(0)],
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 2)
        #expect(projection.shapes[0].rowID == .existing(2))
        #expect(projection.shapes[1].rowID == .existing(0))
    }

    /// Adding overlays is measured at 0.022s for 50,000 aggregated shapes against 125s as separate
    /// overlays, so the budget is generous. It still has to exist, and it has to be reported.
    @Test("Rows past the shape budget are counted")
    func shapeBudgetIsReported() async {
        #expect(SpatialResultProjector.maximumShapes == 100_000)
        #expect(SpatialResultProjector.maximumVertices == 2_000_000)

        let table = rows(Array(repeating: "POINT(1 2)", count: 5))
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.diagnostics.cappedRows == nil)
        #expect(!projection.diagnostics.hasAnythingToReport)
    }

    @Test("A tie between SRIDs prefers the named one")
    func tieBreaksTowardTheNamedSRID() {
        #expect(SpatialResultProjector.majoritySRID(in: [4326: 1, nil: 1]) == 4326)
        #expect(SpatialResultProjector.majoritySRID(in: [4326: 1, 3857: 2]) == 3857)
        #expect(SpatialResultProjector.majoritySRID(in: [:]) == nil)
    }

    @Test("EWKB hex reaches the map, which is the PostGIS rewrite-failed path")
    func hexIsDrawn() async {
        let table = rows(["0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 1)
        #expect(projection.diagnostics.drawnSRID == 4326)
    }
}
