//
//  CompareSchemaPairingTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

// SQL Server spells the listed schema on every table, so `app.dbo` against `app.staging` paired nothing: each table
// was listed as only in the source and again as only in the target.
struct CompareSchemaPairingTests {
    private func snapshot(_ name: String, schema: String?) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: name,
            schema: schema,
            columns: [TestFixtures.makeEditableColumn(name: "id", dataType: "INT", isPrimaryKey: true)]
        )
    }

    @Test
    func tablesOfTwoSchemasPairWhenEachIsItsSidesOwn() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "dbo"), snapshot("orders", schema: "dbo")],
            target: [snapshot("users", schema: "staging"), snapshot("orders", schema: "staging")],
            sourceSchema: "dbo",
            targetSchema: "staging"
        )

        #expect(report.count(of: .identical) == 2)
        #expect(report.count(of: .onlyInSource) == 0)
        #expect(report.count(of: .onlyInTarget) == 0)
    }

    // A window opened from a connection has no schema on its source, and SQL Server still lists `dbo` on each table.
    @Test
    func aSourceWithNoSchemaPairsThroughTheSchemaItsListingCarries() {
        let source = [snapshot("users", schema: "dbo")]
        let target = [snapshot("users", schema: "dbo")]

        let report = StructureDiffEngine().compare(
            source: source,
            target: target,
            sourceSchema: StructureCompareOptions.listedSchema(endpoint: nil, tableSchemas: source.map(\.schema)),
            targetSchema: StructureCompareOptions.listedSchema(endpoint: "dbo", tableSchemas: target.map(\.schema))
        )

        #expect(report.count(of: .identical) == 1)
    }

    @Test
    func anotherSchemaInTheListingStillKeysItsOwnTables() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "public"), snapshot("users", schema: "audit")],
            target: [snapshot("users", schema: "public")],
            sourceSchema: "public",
            targetSchema: "public"
        )

        #expect(report.count(of: .identical) == 1)
        #expect(report.count(of: .onlyInSource) == 1)
    }

    @Test
    func theListedSchemaIsTheEndpointsOrTheOneTheListingCarries() {
        #expect(StructureCompareOptions.listedSchema(endpoint: "staging", tableSchemas: ["dbo"]) == "staging")
        #expect(StructureCompareOptions.listedSchema(endpoint: nil, tableSchemas: ["dbo", "dbo"]) == "dbo")
        #expect(StructureCompareOptions.listedSchema(endpoint: nil, tableSchemas: ["public", "audit"]) == nil)
        #expect(StructureCompareOptions.listedSchema(endpoint: nil, tableSchemas: [nil, nil]) == nil)
        #expect(StructureCompareOptions.listedSchema(endpoint: "", tableSchemas: []) == nil)
    }

    @Test
    func theListedSchemaFoldsLikeTheNameWhenCaseIsIgnored() {
        var options = StructureCompareOptions.default

        #expect(options.matchKey(name: "Users", schema: "DBO", listedIn: "dbo") == options.matchKey("users"))
        options.ignoreIdentifierCase = false
        #expect(options.matchKey(name: "Users", schema: "DBO", listedIn: "dbo") != options.matchKey("Users"))
    }
}
