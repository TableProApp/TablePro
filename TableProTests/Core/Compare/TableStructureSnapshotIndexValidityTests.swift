//
//  TableStructureSnapshotIndexValidityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct TableStructureSnapshotIndexValidityTests {
    private static let table = PluginTableInfo(name: "orders", type: "TABLE", schema: "public", comment: nil)

    private static func index(_ name: String, column: String = "code", valid: Bool?) -> PluginIndexInfo {
        PluginIndexInfo(
            name: name, columns: [column], isUnique: true, expressions: nil, includedColumns: nil,
            ddlMethodAndKeys: nil, ddlWhereClause: nil, isValid: valid
        )
    }

    private static func read(_ indexes: [PluginIndexInfo]) -> TableStructureRead {
        TableStructureRead(
            table: table,
            columns: [
                PluginColumnInfo(name: "code", dataType: "integer"),
                PluginColumnInfo(name: "day", dataType: "date")
            ],
            indexes: indexes,
            foreignKeys: [],
            metadata: nil,
            failure: nil
        )
    }

    private static func addedIndexes(_ changes: [SchemaChange]) -> [String] {
        changes.compactMap { change in
            guard case .addIndex(let index) = change else { return nil }
            return index.name
        }
    }

    private static func deletedIndexes(_ changes: [SchemaChange]) -> [String] {
        changes.compactMap { change in
            guard case .deleteIndex(let index) = change else { return nil }
            return index.name
        }
    }

    @Test("A source read leaves out an invalid index and keeps every other one")
    func sourceSnapshotDropsInvalidIndexes() throws {
        let read = Self.read([
            Self.index("orders_code_key", valid: false),
            Self.index("orders_day_key", column: "day", valid: true),
            Self.index("orders_legacy", column: "day", valid: nil)
        ])
        let source = try #require(read.sourceSnapshot)
        let whole = try #require(read.snapshot)
        let sourceNames = source.indexes.map(\.name)
        let wholeNames = whole.indexes.map(\.name)
        #expect(sourceNames == ["orders_day_key", "orders_legacy"])
        #expect(wholeNames == ["orders_code_key", "orders_day_key", "orders_legacy"])
    }

    @Test("An invalid source index is not added to the target and not rendered in its definition")
    func invalidSourceIndexIsNotSynced() throws {
        let source = try #require(Self.read([Self.index("orders_code_key", valid: false)]).sourceSnapshot)
        let target = try #require(Self.read([]).snapshot)

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        let definition = TableDefinitionRenderer.lines(for: source)
        #expect(Self.addedIndexes(result.changes).isEmpty)
        #expect(!definition.contains { $0.contains("orders_code_key") })
    }

    @Test("A target's invalid twin of a source index is left alone")
    func targetInvalidTwinIsNotReAdded() throws {
        let source = try #require(Self.read([Self.index("orders_code_key", valid: true)]).sourceSnapshot)
        let target = try #require(Self.read([Self.index("orders_code_key", valid: false)]).snapshot)

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        #expect(Self.addedIndexes(result.changes).isEmpty)
        #expect(Self.deletedIndexes(result.changes).isEmpty)
    }

    @Test("A target's invalid index the source does not have is still offered for dropping")
    func orphanTargetInvalidIndexIsDropped() throws {
        let source = try #require(Self.read([]).sourceSnapshot)
        let target = try #require(Self.read([Self.index("orders_code_key", valid: false)]).snapshot)

        let result = StructureDiffEngine().compareTable(source: source, target: target)

        #expect(Self.deletedIndexes(result.changes) == ["orders_code_key"])
    }

    @Test("Object Copy creates no invalid index on the target")
    func objectCopyLeavesInvalidIndexOut() throws {
        let read = Self.read([
            Self.index("orders_code_key", valid: false),
            Self.index("orders_day_key", column: "day", valid: true)
        ])
        let snapshot = try #require(read.sourceSnapshot)
        let draft = ObjectCopyTableDraft(
            selection: ObjectCopySelection(kind: .table, name: "orders", schema: "public"),
            read: read,
            snapshot: snapshot,
            targetSnapshot: nil,
            existsInTarget: false,
            sourceSchema: "public",
            targetSchema: "archive",
            targetServerVersion: nil,
            request: ObjectCopyRequest(
                source: Self.endpoint(),
                destination: .existing(Self.endpoint()),
                objects: [],
                content: .structure,
                existingPolicy: .skip
            )
        )
        let targetIndexes = draft.targetStructure.indexes.map(\.name)
        #expect(targetIndexes == ["orders_day_key"])
    }

    private static func endpoint() -> DatabaseEndpoint {
        DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: "public"),
            connectionName: "PostgreSQL",
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
    }
}
