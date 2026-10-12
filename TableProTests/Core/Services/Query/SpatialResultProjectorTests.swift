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

// An SRID is an identifier rather than a quantity, so it is named once here: written as a literal
// it reads as a four-digit number and the thousand-separator rule asks for `4_326`, which is not
// how anyone spells one.
// swiftlint:disable number_separator
private let wgs84: Int32 = 4326
private let webMercator: Int32 = 3857
// swiftlint:enable number_separator

private func typedRows(_ values: [String?], type: ColumnType, columnName: String = "geom") -> TableRows {
    let built = values.enumerated().map { index, value in
        Row(id: .existing(index), values: [PluginCellValue.fromOptional(value)])
    }
    return TableRows(
        rows: ContiguousArray(built),
        columns: [columnName],
        columnTypes: [type]
    )
}

private func cellRows(_ cells: [PluginCellValue], columnName: String = "geom") -> TableRows {
    let built = cells.enumerated().map { index, cell in
        Row(id: .existing(index), values: [cell])
    }
    return TableRows(
        rows: ContiguousArray(built),
        columns: [columnName],
        columnTypes: [.spatial(rawType: "geometry")]
    )
}

private func bytes(hex: String) -> PluginCellValue {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
        index = next
    }
    return .bytes(data)
}

/// The point `hexIsDrawn` reads as text, here as the bytes a driver hands over.
private let ewkbPoint = "0101000020E610000050FC1873D79A5EC0D0D556EC2FE34240"

/// Names the fixture's column directly rather than going through `SpatialColumn.columns(in:)`.
///
/// The projector's job is to project whatever column it is handed, and which columns are offered is
/// a separate decision with its own tests above. Those two have to stay separate here, because the
/// gate refuses a column no reader can read and that is exactly the fixture several of these need.
private func onlyColumn(_ tableRows: TableRows) -> SpatialColumn {
    SpatialColumn(
        id: SpatialColumnID(name: tableRows.columns[0], occurrence: 1),
        index: 0,
        displayName: tableRows.columns[0],
        type: tableRows.columnTypes[0]
    )
}

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

    /// Oracle reports `SDO_GEOMETRY` and Teradata `ST_GEOMETRY`, and SQL Server's geography arrives
    /// as MS-SSCLRT serialization rather than WKB. All three classify `.spatial`, so a gate reading
    /// the type alone offered Map and then drew nothing at all.
    @Test("A spatial column whose values no reader can read is not offered")
    func unreadableSpatialColumnIsRefused() {
        let oracle = typedRows(
            [
                "MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-122.4,37.8,NULL),NULL,NULL)",
                "MDSYS.SDO_GEOMETRY(2001,4326,MDSYS.SDO_POINT_TYPE(-122.5,37.7,NULL),NULL,NULL)"
            ],
            type: .spatial(rawType: "SDO_GEOMETRY")
        )
        #expect(SpatialColumn.columns(in: oracle).isEmpty)
        #expect(!SpatialColumn.hasSpatialColumn(in: oracle))
    }

    /// The engine's own word is believed when nothing contradicts it, so an empty result and an
    /// all-null column both keep the segment. Taking it away as a page loads would make the mode
    /// appear and vanish under the reader.
    @Test("A spatial column with no values to judge is still offered")
    func emptySpatialColumnIsOffered() {
        #expect(SpatialColumn.hasSpatialColumn(in: typedRows([], type: .spatial(rawType: "geometry"))))
        #expect(SpatialColumn.hasSpatialColumn(in: typedRows([nil, nil], type: .spatial(rawType: "geometry"))))
    }

    /// MongoDB stores GeoJSON in an ordinary document field, which the app types `JSON`, so a gate
    /// reading the type alone never offered Map for the engine whose spatial data is most often
    /// GeoJSON.
    @Test("GeoJSON in a JSON column is offered")
    func geoJSONInAJsonColumnIsOffered() {
        let mongo = typedRows(
            [#"{"type":"Point","coordinates":[-122.4194,37.7749]}"#],
            type: .json(rawType: "JSON"),
            columnName: "location"
        )
        let columns = SpatialColumn.columns(in: mongo)
        #expect(columns.count == 1)
        #expect(columns.first?.name == "location")
    }

    @Test("A JSON column holding no geometry is not offered")
    func plainJsonColumnIsRefused() {
        let documents = typedRows(
            [#"{"name":"Ada","roles":["admin"]}"#, #"{"type":"user","features":[1,2]}"#],
            type: .json(rawType: "JSON")
        )
        #expect(SpatialColumn.columns(in: documents).isEmpty)
    }

    /// A curve is the reader recognizing geometry it cannot draw, which is not the same as text no
    /// reader knows. Counting the two together took the Map segment away from a column of curves,
    /// so the pane never got to say which type it holds.
    @Test("A spatial column of a type the map cannot draw keeps the segment")
    func undrawableTypeKeepsTheSegment() {
        let curves = typedRows(
            Array(repeating: "CIRCULARSTRING(0 0,1 1,2 0)", count: 4),
            type: .spatial(rawType: "geometry")
        )
        #expect(SpatialColumn.hasSpatialColumn(in: curves))
        #expect(SpatialColumn.columns(in: curves).count == 1)

        let curvesThenAPoint = typedRows(
            Array(repeating: "CIRCULARSTRING(0 0,1 1,2 0)", count: 4) + ["POINT(1 2)"],
            type: .spatial(rawType: "geometry")
        )
        #expect(SpatialColumn.hasSpatialColumn(in: curvesThenAPoint))
    }

    @Test("A column of curves reaches the pane's explanation of which type it holds")
    func undrawableTypeIsExplained() async throws {
        let curves = typedRows(
            Array(repeating: "CIRCULARSTRING(0 0,1 1,2 0)", count: 4),
            type: .spatial(rawType: "geometry")
        )
        let column = try #require(SpatialColumn.columns(in: curves).first)
        let projection = await SpatialResultProjector.shared.project(
            tableRows: curves,
            displayIDs: nil,
            column: column
        )
        #expect(projection.isEmpty)
        #expect(projection.diagnostics.emptyReason.contains("CIRCULARSTRING"))
    }

    /// A JSON column still has to hold a value that reads, and the wide reader still decides that:
    /// MongoDB's legacy coordinate pairs draw through it. An undrawable type is not a reading.
    @Test("The JSON gate is unchanged")
    func jsonGateIsUnchanged() {
        let pairs = typedRows(["[-73.97, 40.77]", "[-73.88, 40.78]"], type: .json(rawType: "JSON"))
        #expect(SpatialColumn.hasSpatialColumn(in: pairs))

        let curves = typedRows(["CIRCULARSTRING(0 0,1 1,2 0)"], type: .json(rawType: "JSON"))
        #expect(!SpatialColumn.hasSpatialColumn(in: curves))
    }

    /// Bytes used to be read through their hex spelling, and the hex of one to four bytes is a
    /// valid geohash: a column of short blobs earned the segment and drew a marker per row.
    @Test("A short blob in a spatial column is not read as a geohash")
    func shortBlobsAreNotGeohashes() {
        let blobs = cellRows([bytes(hex: "12"), bytes(hex: "1234"), bytes(hex: "12345678")])
        #expect(!SpatialColumn.hasSpatialColumn(in: blobs))
        #expect(SpatialColumn.columns(in: blobs).isEmpty)
    }

    @Test("A spatial column of WKB bytes is offered")
    func wkbBytesAreOffered() {
        let binary = cellRows([.null, bytes(hex: ewkbPoint)])
        #expect(SpatialColumn.hasSpatialColumn(in: binary))
        #expect(SpatialColumn.columns(in: binary).count == 1)
    }

    @Test("An empty blob says nothing about the column")
    func emptyBlobIsNotJudged() {
        #expect(SpatialColumn.hasSpatialColumn(in: cellRows([.bytes(Data())])))
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
        #expect(projection.diagnostics.drawnSRID == wgs84)
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
        #expect(projection.diagnostics.drawnSRID == wgs84)
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
        #expect(SpatialResultProjector.majoritySRID(in: [wgs84: 1, nil: 1]) == wgs84)
        #expect(SpatialResultProjector.majoritySRID(in: [wgs84: 1, webMercator: 2]) == webMercator)
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
        #expect(projection.diagnostics.drawnSRID == wgs84)
    }

    @Test("WKB bytes are drawn and a short blob beside them is counted as unreadable")
    func bytesAreReadAsWKB() async {
        let table = cellRows([bytes(hex: "1234"), bytes(hex: ewkbPoint), bytes(hex: "12345678"), .bytes(Data())])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 1)
        #expect(projection.shapes.first?.rowID == .existing(1))
        #expect(projection.diagnostics.drawnSRID == wgs84)
        #expect(projection.diagnostics.unreadableRows == 2)
        #expect(projection.diagnostics.emptyRows == 1)
    }

    /// The budget used to be checked once per row, so the first row alone could put any number of
    /// shapes on the map: one MULTIPOINT or GEOMETRYCOLLECTION is a single row and has no bound of
    /// its own.
    @Test("One geometry cannot spend more than the whole budget")
    func budgetIsSpentWithinAGeometry() async {
        let many = (0 ..< 40).map { "\(-122.0 + Double($0) / 100) 37.5" }.joined(separator: ",")
        let tableRows = rows(["MULTIPOINT(\(many))"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: tableRows,
            displayIDs: nil,
            column: onlyColumn(tableRows),
            budget: SpatialResultProjector.ShapeBudget(shapes: 5, vertices: 1_000)
        )
        #expect(projection.shapes.count == 5)
        #expect(projection.diagnostics.cappedRows == 1)
    }

    @Test("The vertex budget stops a run that the shape budget would allow")
    func vertexBudgetStopsALongRun() async {
        let run = (0 ..< 30).map { "\(-122.0 + Double($0) / 100) 37.5" }.joined(separator: ",")
        let tableRows = rows(["LINESTRING(\(run))", "LINESTRING(\(run))"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: tableRows,
            displayIDs: nil,
            column: onlyColumn(tableRows),
            budget: SpatialResultProjector.ShapeBudget(shapes: 100, vertices: 30)
        )
        #expect(projection.shapes.count == 1)
        #expect(projection.diagnostics.cappedRows == 1)
    }

    /// The first polygon crosses longitude 181, which a geographic system does not have. It used to
    /// be skipped with the row reported as drawn and nothing said about the missing half.
    @Test("A member the map cannot place is counted while the rest of the row is drawn")
    func droppedPartsAreCounted() async {
        let table = rows([
            "SRID=4326;MULTIPOLYGON(((179 50,181 50,181 51,179 50)),((10 10,11 10,11 11,10 10)))",
            "SRID=4326;POINT(1 2)",
        ])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 2)
        #expect(projection.diagnostics.drawnRows == 2)
        #expect(projection.diagnostics.droppedParts == 1)
        #expect(projection.diagnostics.unreadableRows == 0)
        #expect(projection.diagnostics.hasAnythingToReport)
    }

    /// Such a row is already counted whole. Counting its parts too would report it twice.
    @Test("A row that draws nothing is counted as a row, not as parts")
    func undrawnRowIsNotCountedAsParts() async {
        let table = rows([
            "SRID=4326;MULTIPOINT(181 50,182 50)",
            "SRID=4326;POINT(1 2)",
        ])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: table,
            displayIDs: nil,
            column: onlyColumn(table)
        )
        #expect(projection.shapes.count == 1)
        #expect(projection.diagnostics.unreadableRows == 1)
        #expect(projection.diagnostics.droppedParts == 0)
    }

    /// The pane asks `readableRows` before it blames the coordinate system, because
    /// `projectability` reports `.unsupported(srid: nil)` from its own default whenever nothing
    /// parsed. Without this the pane told a column of curves that its coordinates were out of range.
    @Test("A column nothing could read reports no readable rows")
    func unreadableColumnReportsItself() async {
        let tableRows = rows(["CIRCULARSTRING(0 0,1 1,2 0)", "CIRCULARSTRING(3 3,4 4,5 3)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: tableRows,
            displayIDs: nil,
            column: onlyColumn(tableRows)
        )
        #expect(projection.isEmpty)
        #expect(projection.diagnostics.readableRows == 0)
        #expect(projection.diagnostics.unsupportedTypes["CIRCULARSTRING"] == 2)
    }

    @Test("A drawable column reports the rows it read")
    func drawableColumnReportsReadableRows() async {
        let tableRows = rows(["SRID=4326;POINT(-122.4 37.8)", nil, "SRID=4326;POINT(-122.5 37.7)"])
        let projection = await SpatialResultProjector.shared.project(
            tableRows: tableRows,
            displayIDs: nil,
            column: onlyColumn(tableRows)
        )
        #expect(projection.diagnostics.readableRows == 2)
    }
}
