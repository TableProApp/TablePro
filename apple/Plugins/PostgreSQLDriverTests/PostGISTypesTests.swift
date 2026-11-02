//
//  PostGISTypesTests.swift
//  PostgreSQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

struct PostGISTypesTests {
    // Another role's `CREATE TYPE evil.geometry AS ENUM (...)` holds no EWKB.
    @Test("The probe takes only base types the postgis extension owns")
    func probeTakesOnlyThePostgisExtensionsBaseTypes() {
        let probe = PostGISTypes.probeQuery
        #expect(probe.contains("t.typtype = 'b'"))
        #expect(probe.contains("d.deptype = 'e'"))
        #expect(probe.contains("JOIN pg_catalog.pg_extension x ON x.oid = d.refobjid"))
        #expect(probe.contains("x.extname = 'postgis'"))
    }

    @Test("Probe rows map each oid to its type name")
    func namesFromProbeRows() {
        let names = PostGISTypes.names(fromProbeRows: [["17000", "geometry"], ["17001", "geography"]])
        #expect(names == [17_000: "geometry", 17_001: "geography"])
    }

    @Test("A row without a numeric oid or a name is skipped")
    func malformedRowsAreSkipped() {
        let names = PostGISTypes.names(fromProbeRows: [["x", "geometry"], [nil, "geography"], ["17002", nil], ["17003"]])
        #expect(names.isEmpty)
    }

    private static func result(oids: [UInt32], rows: [[PluginCellValue]]) -> LibPQPluginQueryResult {
        LibPQPluginQueryResult(
            columns: oids.map { "c\($0)" },
            columnOids: oids,
            columnTypeNames: oids.map { _ in "unknown" },
            rows: rows,
            affectedRows: 0,
            commandTag: "SELECT 2",
            isTruncated: false
        )
    }

    @Test("A PostGIS column is written as EWKT and named; NULL, other text and other columns stay")
    func renderingRewritesSpatialCells() {
        let point = "0101000020E6100000000000000000F03F0000000000000040"
        let raw = Self.result(oids: [23, 17_000], rows: [
            [.text("1"), .text(point)],
            [.text(point), .null],
            [.text("2"), .text("not ewkb")]
        ])

        let rendered = PostGISTypes.rendering(raw, types: [17_000: "geometry"])

        #expect(rendered.columnTypeNames == ["unknown", "geometry"])
        #expect(rendered.rows == [
            [.text("1"), .text("SRID=4326;POINT(1 2)")],
            [.text(point), .null],
            [.text("2"), .text("not ewkb")]
        ])
        #expect(rendered.commandTag == "SELECT 2")
    }

    @Test("A result with no PostGIS column comes back as it was")
    func renderingLeavesOtherResults() {
        let raw = Self.result(oids: [23], rows: [[.text("0101000020E6100000000000000000F03F0000000000000040")]])
        let rendered = PostGISTypes.rendering(raw, types: [17_000: "geometry"])
        #expect(rendered.rows == raw.rows)
        #expect(rendered.columnTypeNames == raw.columnTypeNames)
    }
}
