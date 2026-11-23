//
//  CompareCrossSchemaScriptingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class ScriptingDriver: PluginDriverStub, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var currentSchema: String? { "staging" }
}

// A view paired across `dbo` and `staging` kept the source's identity and text, so an Alter dropped `dbo.v`, the
// source's own view on a compare within one database, and ran a definition that can name `dbo` again.
struct CompareCrossSchemaSourceObjectTests {
    private let engine = SourceObjectDiffEngine(
        sourceDatabaseType: .mssql, targetDatabaseType: .mssql, targetIndexedKinds: []
    )

    private func view(_ schema: String, _ body: String) -> RoutineSourceRead {
        RoutineSourceRead(name: "v", kind: .view, schema: schema, signature: nil, source: "CREATE VIEW \(schema).v AS \(body)")
    }

    @Test
    func aPairAcrossTwoSchemasIsShownButNeverScripted() throws {
        let results = engine.compare(
            source: [view("dbo", "SELECT 1 AS a")],
            target: [view("staging", "SELECT 2 AS a")],
            sourceSchema: "dbo",
            targetSchema: "staging"
        )

        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.status == .differs)
        #expect(result.suggestedAction == .skip)
        #expect(result.availableActions == [.skip])
        #expect(result.notes.contains { $0.contains("not scripted") })
        let builder = SourceObjectSyncBuilder(targetDriver: ScriptingDriver(), targetDatabaseType: .mssql, indexSchema: "staging")
        #expect(throws: CompareSyncError.self) { try builder.build(for: result, action: .alter) }
    }

    @Test
    func anObjectOnlyInTheSourceIsNotCreatedFromAnotherSchemasText() throws {
        let results = engine.compare(
            source: [view("dbo", "SELECT 1 AS a")],
            target: [],
            sourceSchema: "dbo",
            targetSchema: "staging"
        )

        let result = try #require(results.first)
        #expect(result.status == .onlyInSource)
        #expect(result.suggestedAction == .skip)
    }

    @Test
    func theSameSchemaOnBothSidesStillScripts() throws {
        let results = engine.compare(
            source: [view("dbo", "SELECT 1 AS a")],
            target: [view("dbo", "SELECT 2 AS a")],
            sourceSchema: "dbo",
            targetSchema: "dbo"
        )

        let result = try #require(results.first)
        #expect(result.suggestedAction == .alter)
        #expect(result.scriptRefusal == nil)
    }

    @Test
    func aTargetOnlyObjectIsStillDroppedByItsOwnName() throws {
        let results = engine.compare(source: [], target: [view("staging", "SELECT 1 AS a")], sourceSchema: "dbo", targetSchema: "staging")

        let result = try #require(results.first)
        #expect(result.suggestedAction == .drop)
        #expect(result.identity.schema == "staging")
    }
}

// A child paired across `dbo` and `staging` compared its key to `dbo.parent` with the target's key to `staging.parent`,
// so it dropped the key and added one that pointed the target's table at the source's parent.
struct CompareCrossSchemaForeignKeyTests {
    private func child(_ schema: String, referencing referencedSchema: String?) -> TableStructureSnapshot {
        var foreignKeys: [EditableForeignKeyDefinition] = []
        if let referencedSchema {
            var key = TestFixtures.makeEditableForeignKey(name: "child_parent", columns: ["parent_id"], refTable: "parent")
            key.referencedSchema = referencedSchema
            foreignKeys = [key]
        }
        return TableStructureSnapshot(
            name: "child",
            schema: schema,
            columns: [
                TestFixtures.makeEditableColumn(name: "id", dataType: "INT", isPrimaryKey: true),
                TestFixtures.makeEditableColumn(name: "parent_id", dataType: "INT")
            ],
            foreignKeys: foreignKeys
        )
    }

    private func compare(_ source: TableStructureSnapshot, _ target: TableStructureSnapshot) -> StructureDiffReport {
        StructureDiffEngine().compare(source: [source], target: [target], sourceSchema: "dbo", targetSchema: "staging")
    }

    private func addedKeys(_ report: StructureDiffReport) -> [EditableForeignKeyDefinition] {
        report.results.flatMap(\.changes).compactMap { change in
            guard case .addForeignKey(let key) = change else { return nil }
            return key
        }
    }

    @Test
    func aKeyToEachSidesOwnSchemaIsTheSameKey() {
        let report = compare(child("dbo", referencing: "dbo"), child("staging", referencing: "staging"))

        #expect(report.count(of: .identical) == 1)
    }

    @Test
    func anAddedKeyPointsAtTheTargetsOwnTable() {
        let report = compare(child("dbo", referencing: "dbo"), child("staging", referencing: nil))

        #expect(addedKeys(report).map { $0.referencedSchema } == ["staging"])
    }

    @Test
    func aKeyToAThirdSchemaKeepsPointingThere() {
        let report = compare(child("dbo", referencing: "shared"), child("staging", referencing: nil))

        #expect(addedKeys(report).map { $0.referencedSchema } == ["shared"])
    }

    @Test
    func aTableCreatedInAnotherSchemaTakesItsOwnKeysWithIt() {
        let options = StructureCompareOptions.default
        let own = child("dbo", referencing: "dbo").placingReferences(from: "dbo", into: "staging", options: options)
        let third = child("dbo", referencing: "shared").placingReferences(from: "dbo", into: "staging", options: options)
        let same = child("dbo", referencing: "dbo").placingReferences(from: "dbo", into: "dbo", options: options)

        #expect(own.foreignKeys.map { $0.referencedSchema } == ["staging"])
        #expect(third.foreignKeys.map { $0.referencedSchema } == ["shared"])
        #expect(same.foreignKeys.map { $0.referencedSchema } == ["dbo"])
    }
}

// A transfer pressed while the schema list was loading took a scope with no schema, and its writes went to whatever
// schema the destination session was on.
struct TableTransferDestinationScopeTests {
    private let connection = DatabaseConnection(name: "Warehouse", database: "app", type: .postgresql)

    @Test
    func whileTheDestinationLoadsThereIsNoScopeToTransferInto() {
        #expect(TableTransferSheet.destinationScope(
            connection: connection, database: "app", schema: "", isResolving: true
        ) == nil)
    }

    @Test
    func aResolvedDestinationNamesItsSchema() {
        let scope = TableTransferSheet.destinationScope(
            connection: connection, database: "app", schema: "sales", isResolving: false
        )

        #expect(scope == DatabaseScope(connectionId: connection.id, database: "app", schema: "sales"))
        #expect(TableTransferSheet.destinationScope(connection: nil, database: "app", schema: "sales", isResolving: false) == nil)
    }
}

// Each side keys every value one way per column: on the wall clock when one side's values all carry an offset and the
// other's none, and on the instant otherwise. A pairwise rule matched `10:00+07` with `10:00` and `10:00` with `10:00Z`
// but not `10:00+07` with `10:00Z`, so equal multisets reported differences, and NULL layouts multiplied its indexes.
struct ResultComparisonMixedZoneTests {
    private func side(_ columns: [String], _ rows: [[String?]]) -> ResultComparisonSide {
        ResultComparisonSide(
            title: "Result",
            detail: "Query 1",
            columns: columns,
            columnTypes: columns.map { $0 == "id" ? .integer(rawType: nil) : .timestamp(rawType: nil) },
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

    @Test
    func aReorderedMultisetOfMixedValuesIsTheSameRows() throws {
        let values = ["2024-01-01 10:00:00+07", "2024-01-01 10:00:00", "2024-01-01 10:00:00Z"]
        let left = side(["at"], values.map { [$0] as [String?] })

        for order in [[1, 2, 0], [2, 1, 0], [0, 1, 2]] {
            let right = side(["at"], order.map { [values[$0]] as [String?] })
            #expect(try compare(left, right, key: []).differenceCount == 0, "order \(order)")
        }
    }

    @Test
    func aColumnMixingZonedAndUnzonedValuesComparesInstants() throws {
        let left = side(["id", "at"], [["1", "2024-01-01 10:00:00+07"], ["2", "2024-01-01 10:00:00+07"]])
        let right = side(["id", "at"], [["1", "2024-01-01 10:00:00"], ["2", "2024-01-01 03:00:00+00:00"]])

        #expect(try compare(left, right, key: ["id"]).entries.map { $0.kind } == [.changed, .same])
    }

    @Test
    func nullableZonedColumnsAgainstTheirWallClocksAreTheSameRows() throws {
        let left = side(["id", "at", "seen"], [
            ["1", nil, "2024-01-01 10:00:00+07"],
            ["2", "2024-01-02 10:00:00+07", nil],
            ["3", nil, nil],
            ["4", "2024-01-03 10:00:00+07", "2024-01-03 11:00:00+07"]
        ])
        let right = side(["id", "at", "seen"], [
            ["4", "2024-01-03 10:00:00", "2024-01-03 11:00:00"],
            ["3", nil, nil],
            ["2", "2024-01-02 10:00:00", nil],
            ["1", nil, "2024-01-01 10:00:00"]
        ])

        #expect(try compare(left, right, key: ["id"]).differenceCount == 0)
        #expect(try compare(left, right, key: []).differenceCount == 0)
    }

    @Test
    func rowOrderDoesNotChangeTheAnswer() throws {
        let left: [[String?]] = [["1", "2024-01-01 10:00:00+07"], ["2", "2024-01-02 10:00:00+07"]]
        let right: [[String?]] = [["1", "2024-01-01 10:00:00"], ["2", "2024-01-02 10:00:00"]]

        for key in [["id"], [], ["at"]] {
            #expect(try compare(side(["id", "at"], left), side(["id", "at"], Array(right.reversed())), key: key).differenceCount == 0)
            #expect(try compare(side(["id", "at"], Array(left.reversed())), side(["id", "at"], right), key: key).differenceCount == 0)
        }
    }
}
