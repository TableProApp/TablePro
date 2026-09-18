//
//  DuckDBTypeRenderingTests.swift
//  TableProTests
//
//  The renderability table mirrors what duckdb_value_varchar actually returns for
//  the linked libduckdb. scripts/check-duckdb-value-api.sh re-measures it.
//

import Foundation
import Testing

@Suite("DuckDB type rendering")
struct DuckDBTypeRenderingTests {
    @Test("Timestamp flavors the value API cannot decode need a text projection")
    func undecodableTimestampsRequireProjection() {
        #expect(DuckDBLogicalType.requiresTextProjection(.timestampSeconds))
        #expect(DuckDBLogicalType.requiresTextProjection(.timestampMilliseconds))
        #expect(DuckDBLogicalType.requiresTextProjection(.timestampNanoseconds))
        #expect(DuckDBLogicalType.requiresTextProjection(.timestampTz))
        #expect(DuckDBLogicalType.requiresTextProjection(.timeTz))
    }

    @Test("Types the value API renders directly are left alone")
    func decodableTypesAreNotProjected() {
        #expect(!DuckDBLogicalType.requiresTextProjection(.timestamp))
        #expect(!DuckDBLogicalType.requiresTextProjection(.date))
        #expect(!DuckDBLogicalType.requiresTextProjection(.time))
        #expect(!DuckDBLogicalType.requiresTextProjection(.timeNs))
        #expect(!DuckDBLogicalType.requiresTextProjection(.interval))
        #expect(!DuckDBLogicalType.requiresTextProjection(.varchar))
        #expect(!DuckDBLogicalType.requiresTextProjection(.blob))
        #expect(!DuckDBLogicalType.requiresTextProjection(.decimal))
        #expect(!DuckDBLogicalType.requiresTextProjection(.hugeint))
        #expect(!DuckDBLogicalType.requiresTextProjection(.uhugeint))
    }

    @Test("Nested and extension types the value API cannot decode need a text projection")
    func undecodableComplexTypesRequireProjection() {
        #expect(DuckDBLogicalType.requiresTextProjection(.list))
        #expect(DuckDBLogicalType.requiresTextProjection(.array))
        #expect(DuckDBLogicalType.requiresTextProjection(.structure))
        #expect(DuckDBLogicalType.requiresTextProjection(.map))
        #expect(DuckDBLogicalType.requiresTextProjection(.union))
        #expect(DuckDBLogicalType.requiresTextProjection(.enumeration))
        #expect(DuckDBLogicalType.requiresTextProjection(.uuid))
        #expect(DuckDBLogicalType.requiresTextProjection(.bit))
        #expect(DuckDBLogicalType.requiresTextProjection(.bignum))
        #expect(DuckDBLogicalType.requiresTextProjection(.geometry))
    }

    @Test("An unknown type is projected rather than trusted")
    func unknownTypeRequiresProjection() {
        #expect(DuckDBLogicalType.requiresTextProjection(nil))
    }

    @Test("A result needs projecting when any single column does")
    func anyColumnDrivesProjection() {
        #expect(!DuckDBLogicalType.requiresTextProjection(anyOf: [.integer, .varchar, .timestamp]))
        #expect(DuckDBLogicalType.requiresTextProjection(anyOf: [.integer, .timestampMilliseconds]))
        #expect(DuckDBLogicalType.requiresTextProjection(anyOf: [.integer, nil]))
        #expect(!DuckDBLogicalType.requiresTextProjection(anyOf: []))
    }

    @Test("Display names match the names DuckDB reports for each type")
    func displayNames() {
        #expect(DuckDBLogicalType.timestampMilliseconds.displayName == "TIMESTAMP_MS")
        #expect(DuckDBLogicalType.timestampSeconds.displayName == "TIMESTAMP_S")
        #expect(DuckDBLogicalType.timestampNanoseconds.displayName == "TIMESTAMP_NS")
        #expect(DuckDBLogicalType.timestampTz.displayName == "TIMESTAMPTZ")
        #expect(DuckDBLogicalType.timeTz.displayName == "TIMETZ")
        #expect(DuckDBLogicalType.structure.displayName == "STRUCT")
        #expect(DuckDBLogicalType.enumeration.displayName == "ENUM")
    }

    @Test("Every type name is distinct")
    func displayNamesAreUnique() {
        let names = DuckDBLogicalType.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test("A projected column is read back through DuckDB's own VARCHAR cast")
    func castProjectionUsesPositionalAlias() {
        let sql = DuckDBProjectedQuery.projection(for: .timestampMilliseconds, at: 0, column: "open_ts")
        #expect(sql == "CASE WHEN c1 IS NULL THEN NULL ELSE CAST(c1 AS VARCHAR) END AS \"open_ts\"")
    }

    @Test("Geometry is projected through ST_AsText rather than a plain cast")
    func geometryProjection() {
        let sql = DuckDBProjectedQuery.projection(for: .geometry, at: 2, column: "shape")
        #expect(sql == "CASE WHEN c3 IS NULL THEN NULL ELSE ST_AsText(c3) END AS \"shape\"")
    }

    @Test("A directly readable column passes through by position")
    func passthroughProjection() {
        #expect(DuckDBProjectedQuery.projection(for: .integer, at: 1, column: "id") == "c2 AS \"id\"")
    }

    @Test("Column aliases are quoted and embedded quotes escaped")
    func aliasQuoting() {
        let sql = DuckDBProjectedQuery.projection(for: .integer, at: 0, column: "we\"ird")
        #expect(sql == "c1 AS \"we\"\"ird\"")
    }

    @Test("The wrapper names the subquery's columns by position, so duplicates stay distinct")
    func wrapperUsesDerivedTableAliasList() {
        let sql = DuckDBProjectedQuery.build(
            originalQuery: "SELECT a.ts, b.ts FROM a, b",
            columns: [("ts", .timestampMilliseconds), ("ts", .timestampMilliseconds)]
        )
        #expect(sql == """
        SELECT CASE WHEN c1 IS NULL THEN NULL ELSE CAST(c1 AS VARCHAR) END AS "ts", \
        CASE WHEN c2 IS NULL THEN NULL ELSE CAST(c2 AS VARCHAR) END AS "ts" \
        FROM (SELECT a.ts, b.ts FROM a, b
        ) AS _tp_cast(c1, c2)
        """)
    }

    @Test("The closing parenthesis starts a new line so a trailing comment cannot swallow it")
    func wrapperTerminatesTrailingComment() {
        let sql = DuckDBProjectedQuery.build(
            originalQuery: "SELECT ts FROM bars -- latest",
            columns: [("ts", .timestampMilliseconds)]
        )
        #expect(sql?.contains("-- latest\n) AS _tp_cast(c1)") == true)
    }

    @Test("A trailing semicolon is dropped before wrapping")
    func wrapperStripsTrailingSemicolon() {
        let sql = DuckDBProjectedQuery.build(
            originalQuery: "SELECT ts FROM bars;  ",
            columns: [("ts", .timestampMilliseconds)]
        )
        #expect(sql?.contains("FROM (SELECT ts FROM bars\n) AS _tp_cast(c1)") == true)
    }

    @Test("Mixed results only cast the columns that need it")
    func wrapperMixesCastAndPassthrough() {
        let sql = DuckDBProjectedQuery.build(
            originalQuery: "SELECT id, ts FROM bars",
            columns: [("id", .integer), ("ts", .timestampMilliseconds)]
        )
        #expect(sql == """
        SELECT c1 AS "id", CASE WHEN c2 IS NULL THEN NULL ELSE CAST(c2 AS VARCHAR) END AS "ts" \
        FROM (SELECT id, ts FROM bars
        ) AS _tp_cast(c1, c2)
        """)
    }

    @Test("A result with no columns cannot be wrapped")
    func wrapperRejectsEmptyColumns() {
        #expect(DuckDBProjectedQuery.build(originalQuery: "SELECT 1", columns: []) == nil)
    }

    @Test("A statement that is only a semicolon cannot be wrapped")
    func wrapperRejectsEmptyStatement() {
        #expect(DuckDBProjectedQuery.build(originalQuery: " ; ", columns: [("a", .integer)]) == nil)
    }
}
