//
//  RowChangeStatementFactoryUniqueMatchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RowChangeStatementFactoryUniqueMatchTests {
    private let columns = ["d", "id", "v"]
    private let row: [PluginCellValue] = ["2026-10-22", "1", "a"]

    private func factory(_ databaseType: DatabaseType, primaryKeyColumns: [String] = ["d"]) -> RowChangeStatementFactory {
        RowChangeStatementFactory(
            tableName: "t",
            schemaName: nil,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: databaseType,
            pluginDriver: nil
        )
    }

    private var edit: RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [CellChange(columnIndex: 2, columnName: "v", oldValue: "a", newValue: "b")],
            originalRow: row
        )
    }

    private var delete: RowChange {
        RowChange(rowID: .existing(0), type: .delete, originalRow: row)
    }

    private func refusal(_ write: () throws -> [ParameterizedStatement]) -> (kind: RowWriteKind?, reason: String)? {
        do {
            let statements = try write()
            Issue.record("Sent \(statements.map(\.sql))")
            return nil
        } catch let DataWriteError.changeRefused(table, kind, reason) {
            #expect(table == "t")
            return (kind, reason)
        } catch {
            Issue.record("Unexpected error: \(error)")
            return nil
        }
    }

    @Test(arguments: [DatabaseType.clickhouse, .snowflake, .trino])
    func aDeleteIsRefusedInsteadOfKeyedOnAKeyTheEngineDoesNotKeepUnique(databaseType: DatabaseType) {
        let refused = refusal {
            try factory(databaseType).statements(for: [delete], deletedRowIDs: [.existing(0)])
        }
        #expect(refused?.kind == .delete)
        #expect(refused?.reason.contains(databaseType.displayName) == true)
        #expect(refused?.reason.contains("SQL statement") == true)
    }

    @Test(arguments: [DatabaseType.clickhouse, .snowflake, .trino])
    func anEditIsRefusedInsteadOfKeyedOnAKeyTheEngineDoesNotKeepUnique(databaseType: DatabaseType) {
        let refused = refusal { try factory(databaseType).statements(for: [edit]) }
        #expect(refused?.kind == .update)
    }

    @Test
    func aNewClickHouseRowIsStillInserted() throws {
        let inserted = RowID.inserted(UUID())
        let statements = try factory(.clickhouse).statements(
            for: [RowChange(rowID: inserted, type: .insert)],
            insertedRowData: [inserted: row],
            insertedRowIDs: [inserted]
        )
        #expect(statements.count == 1)
        #expect(statements.first?.sql.hasPrefix("INSERT") == true)
    }

    @Test
    func aDamengTableWithAPrimaryKeyIsStillWritten() throws {
        let deleted = RowChange(rowID: .existing(1), type: .delete, originalRow: ["2026-10-22", "2", "a"])
        let statements = try factory(.dameng, primaryKeyColumns: ["id"]).statements(
            for: [edit, deleted],
            deletedRowIDs: [.existing(1)]
        )
        #expect(Set(statements.map { String($0.sql.prefix(6)) }) == ["UPDATE", "DELETE"])
    }

    @Test
    func aDamengTableWithoutAPrimaryKeyRefusesADelete() {
        let refused = refusal {
            try factory(.dameng, primaryKeyColumns: []).statements(for: [delete], deletedRowIDs: [.existing(0)])
        }
        #expect(refused?.kind == .delete)
        #expect(refused?.reason.contains("primary key") == true)
    }

    @Test
    func rewindingAClickHouseInsertIsRefused() {
        let target = DataWriteTarget(database: "default", schema: nil, table: "t")
        let record = RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .clickhouse,
            target: target,
            capturedAt: Date(timeIntervalSince1970: 0),
            generatedColumns: [],
            identityColumns: [],
            operations: [
                RowWriteOperation(
                    kind: .insert,
                    target: target,
                    columns: columns,
                    primaryKeyColumns: ["d"],
                    preImage: nil,
                    postImage: row,
                    writtenColumns: columns,
                    refusal: nil
                ),
            ]
        )
        let planner = RewindPlanner(
            record: record,
            factory: factory(.clickhouse),
            queryBuilder: TableQueryBuilder(
                databaseType: .clickhouse,
                dialect: PluginManager.shared.sqlDialect(for: .clickhouse),
                pagination: .offset
            )
        )

        #expect(throws: DataWriteError.self) {
            try planner.plan(currentRows: [RewindCurrentRow(values: row)])
        }
    }
}
