//
//  DuckDBPositionParserTests.swift
//  TableProTests
//
//  Tests for DuckDBPositionParser (compiled via project.yml from DuckDBDriverPlugin).
//  The settings values below are what the shipped libduckdb 1.5.2 actually reports: empty
//  before any USE, `second.main` after `USE second`, `second.other` after `USE second.other`.
//

import Foundation
import Testing

@Suite("DuckDB position parser")
struct DuckDBPositionParserTests {
    @Test("A connection that has never run USE reports no catalog and the schema setting")
    func freshConnectionHasNoCatalog() {
        let position = DuckDBPositionParser.parse(settings: ["search_path": "", "schema": "main"])
        #expect(position.catalog == nil)
        #expect(position.schema == "main")
    }

    @Test("USE on a catalog is read back as catalog and schema")
    func catalogAndSchemaAreSplit() {
        let position = DuckDBPositionParser.parse(
            settings: ["search_path": "second.main", "schema": "main"]
        )
        #expect(position.catalog == "second")
        #expect(position.schema == "main")
    }

    @Test("USE on a two-part name reports the schema it landed on, not the default")
    func schemaFollowsTheSearchPath() {
        let position = DuckDBPositionParser.parse(
            settings: ["search_path": "second.other", "schema": "other"]
        )
        #expect(position.catalog == "second")
        #expect(position.schema == "other")
    }

    /// `search_path` is a list, and only its first entry is where the connection sits.
    @Test("Only the first search_path entry is read")
    func onlyTheFirstEntryCounts() {
        let position = DuckDBPositionParser.parse(
            settings: ["search_path": "second.other, third.main", "schema": "other"]
        )
        #expect(position.catalog == "second")
        #expect(position.schema == "other")
    }

    /// A schema name may contain a dot, so the split takes the first separator only.
    @Test("A schema name containing a dot is kept whole")
    func schemaWithADotSurvives() {
        let position = DuckDBPositionParser.parse(settings: ["search_path": "db.a.b", "schema": "a.b"])
        #expect(position.catalog == "db")
        #expect(position.schema == "a.b")
    }

    @Test("A search_path with no dot is not mistaken for a catalog")
    func bareSearchPathIsNotACatalog() {
        let position = DuckDBPositionParser.parse(settings: ["search_path": "main", "schema": "main"])
        #expect(position.catalog == nil)
        #expect(position.schema == "main")
    }

    @Test("Missing settings produce no position rather than empty strings")
    func missingSettingsAreNil() {
        let position = DuckDBPositionParser.parse(settings: [:])
        #expect(position.catalog == nil)
        #expect(position.schema == nil)
    }

    @Test("An empty schema setting is absent, not blank")
    func emptySchemaIsNil() {
        let position = DuckDBPositionParser.parse(settings: ["search_path": "", "schema": ""])
        #expect(position.schema == nil)
    }

    /// DuckDB resolves a catalog case-insensitively but echoes the caller's spelling back,
    /// so the parser must not pretend it is canonical. The driver matches it against
    /// duckdb_databases() before anything filters on it.
    @Test("The catalog is reported exactly as DuckDB echoed it")
    func catalogCasingIsNotNormalised() {
        let position = DuckDBPositionParser.parse(
            settings: ["search_path": "FIXTURE.main", "schema": "main"]
        )
        #expect(position.catalog == "FIXTURE")
    }
}
