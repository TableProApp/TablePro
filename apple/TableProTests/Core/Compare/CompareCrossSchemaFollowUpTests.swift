//
//  CompareCrossSchemaFollowUpTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// Views, routines and triggers were keyed with their schema, so `dbo` against `staging` paired none of them.
struct CompareSourceObjectSchemaPairingTests {
    private let engine = SourceObjectDiffEngine(
        sourceDatabaseType: .mssql, targetDatabaseType: .mssql, targetIndexedKinds: []
    )

    private func read(
        _ name: String,
        kind: CompareObjectKind,
        schema: String,
        signature: String? = nil,
        source: String
    ) -> RoutineSourceRead {
        RoutineSourceRead(name: name, kind: kind, schema: schema, signature: signature, source: source)
    }

    @Test
    func viewsRoutinesAndTriggersOfTwoSchemasPairWhenEachIsItsSidesOwn() {
        let source = [
            read("active_users", kind: .view, schema: "dbo", source: "CREATE VIEW active_users AS SELECT 1 AS id"),
            read("purge", kind: .procedure, schema: "dbo", source: "CREATE PROCEDURE purge AS SELECT 1"),
            read("stamp", kind: .trigger, schema: "dbo", signature: "users", source: "CREATE TRIGGER stamp ON users AFTER INSERT AS SELECT 1")
        ]
        let target = [
            read("active_users", kind: .view, schema: "staging", source: "CREATE VIEW active_users AS SELECT 1 AS id"),
            read("purge", kind: .procedure, schema: "staging", source: "CREATE PROCEDURE purge AS SELECT 1"),
            read("stamp", kind: .trigger, schema: "staging", signature: "users", source: "CREATE TRIGGER stamp ON users AFTER INSERT AS SELECT 1")
        ]

        let results = engine.compare(source: source, target: target, sourceSchema: "dbo", targetSchema: "staging")

        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.status == .identical })
    }

    @Test
    func anotherSchemaInTheListingStillKeysItsOwnObjects() {
        let results = engine.compare(
            source: [
                read("audit", kind: .function, schema: "dbo", source: "CREATE FUNCTION audit() RETURNS INT AS BEGIN RETURN 1 END"),
                read("audit", kind: .function, schema: "history", source: "CREATE FUNCTION audit() RETURNS INT AS BEGIN RETURN 1 END")
            ],
            target: [read("audit", kind: .function, schema: "staging", source: "CREATE FUNCTION audit() RETURNS INT AS BEGIN RETURN 1 END")],
            sourceSchema: "dbo",
            targetSchema: "staging"
        )

        #expect(results.count == 2)
        #expect(results.contains { $0.identity.schema == "dbo" && $0.status == .identical })
        #expect(results.contains { $0.identity.schema == "history" && $0.status == .onlyInSource })
    }
}

// A target table that could not be read across two schemas left the source's table as "only in source", which
// suggested a CREATE of a table already there; a source one unread suggested dropping the target's.
struct CompareUnreadableCounterpartTests {
    private func snapshot(_ name: String, schema: String?) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: name,
            schema: schema,
            columns: [TestFixtures.makeEditableColumn(name: "id", dataType: "INT", isPrimaryKey: true)]
        )
    }

    @Test
    func aTargetTableThatCouldNotBeReadIsNotReportedAsMissing() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "dbo"), snapshot("orders", schema: "dbo")],
            target: [snapshot("orders", schema: "staging")],
            sourceSchema: "dbo",
            targetSchema: "staging",
            unreadableTarget: [(name: "users", schema: "staging")]
        )

        #expect(report.count(of: .onlyInSource) == 0)
        #expect(report.count(of: .identical) == 1)
    }

    @Test
    func aSourceTableThatCouldNotBeReadLeavesNoDropBehind() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("orders", schema: "dbo")],
            target: [snapshot("users", schema: "staging"), snapshot("orders", schema: "staging")],
            sourceSchema: "dbo",
            targetSchema: "staging",
            unreadableSource: [(name: "users", schema: "dbo")]
        )

        #expect(report.count(of: .onlyInTarget) == 0)
        #expect(report.count(of: .identical) == 1)
    }

    @Test
    func aTableWithNoUnreadableCounterpartIsStillOneSided() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "dbo"), snapshot("audit", schema: "dbo")],
            target: [],
            sourceSchema: "dbo",
            targetSchema: "staging",
            unreadableTarget: [(name: "users", schema: "staging")]
        )

        #expect(report.results.map { $0.tableName } == ["audit"])
        #expect(report.count(of: .onlyInSource) == 1)
    }
}

// A timestamptz on one side and a datetime on the other compared as instants, so the wall clock the copy wrote read as
// a change.
struct ResultComparisonWallClockTests {
    private func side(_ rows: [[String?]], atType: ColumnType) -> ResultComparisonSide {
        ResultComparisonSide(
            title: "Result",
            detail: "Query 1",
            columns: ["id", "at"],
            columnTypes: [.integer(rawType: nil), atType],
            rows: ContiguousArray(rows.enumerated().map { index, values in
                Row(id: .existing(index), values: ContiguousArray(values.map { $0.map(PluginCellValue.text) ?? .null }))
            })
        )
    }

    private func compare(_ left: ResultComparisonSide, _ right: ResultComparisonSide, key: [String]) throws -> ResultComparison {
        let pairing = ResultColumnPairing(left: left.columns, right: right.columns)
        let keyPairs = key.compactMap { name in pairing.pairs.firstIndex { $0.name == name } }
        return try ResultComparisonEngine.compare(left: left, right: right, pairing: pairing, keyPairs: keyPairs)
    }

    private let zoned = ColumnType.timestamp(rawType: "timestamptz")
    private let naive = ColumnType.datetime(rawType: "datetime")

    @Test
    func aZonedColumnAndTheWallClockOfItAreTheSameRows() throws {
        let left = side([["1", nil], ["2", "2024-01-01 10:00:00+07"]], atType: zoned)
        let right = side([["1", nil], ["2", "2024-01-01 10:00:00"]], atType: naive)

        #expect(try compare(left, right, key: []).differenceCount == 0)
        #expect(try compare(left, right, key: ["id"]).differenceCount == 0)
        #expect(try compare(left, right, key: ["at"]).differenceCount == 0)
    }

    @Test
    func anotherWallClockAgainstAZonedColumnIsAChange() throws {
        let left = side([["1", "2024-01-01 10:00:00+07"]], atType: zoned)
        let right = side([["1", "2024-01-01 03:00:00"]], atType: naive)

        #expect(try compare(left, right, key: ["id"]).count(of: .changed) == 1)
    }

    @Test
    func twoZonedColumnsStillCompareInstants() throws {
        let left = side([["1", "2024-01-01 10:00:00+07"]], atType: zoned)
        let right = side([["1", "2024-01-01 03:00:00+00:00"]], atType: zoned)

        #expect(try compare(left, right, key: ["id"]).differenceCount == 0)
    }
}
