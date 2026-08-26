//
//  RewindPlannerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Rewind planning")
@MainActor
struct RewindPlannerTests {
    private let columns = ["id", "name"]
    private let target = DataWriteTarget(database: "shop", schema: nil, table: "users")

    private func operation(
        kind: RowWriteKind,
        preImage: [PluginCellValue]?,
        postImage: [PluginCellValue]?,
        writtenColumns: [String],
        refusal: RewindRefusal? = nil
    ) -> RowWriteOperation {
        RowWriteOperation(
            kind: kind,
            target: target,
            columns: columns,
            primaryKeyColumns: ["id"],
            preImage: preImage,
            postImage: postImage,
            writtenColumns: writtenColumns,
            refusal: refusal
        )
    }

    private func planner(operations: [RowWriteOperation]) -> RewindPlanner {
        let record = RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .sqlite,
            target: target,
            capturedAt: Date(timeIntervalSince1970: 0),
            generatedColumns: [],
            operations: operations
        )
        return RewindPlanner(
            record: record,
            factory: RowChangeStatementFactory(
                tableName: target.table,
                schemaName: nil,
                columns: columns,
                primaryKeyColumns: ["id"],
                databaseType: .sqlite,
                pluginDriver: nil
            ),
            queryBuilder: TableQueryBuilder(databaseType: .sqlite)
        )
    }

    @Test("A row still holding what the save wrote is restored")
    func unchangedRowRestores() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [["7", "Grace"]])

        #expect(plan.rows.first?.outcome == .willRestore)
        #expect(plan.restorableCount == 1)
        #expect(plan.statements.count == 1)
    }

    @Test("A row someone else changed is left alone, and no statement is generated for it")
    func changedRowIsSkipped() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [["7", "Hopper"]])

        #expect(plan.rows.first?.outcome == .changedSinceSave)
        #expect(plan.restorableCount == 0)
        #expect(plan.statements.isEmpty)
        #expect(plan.canApply == false)
    }

    @Test("A row already back at its old value is reported as such, so a half-finished rewind can be re-run")
    func alreadyRestoredRowIsIdempotent() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [["7", "Ada"]])

        #expect(plan.rows.first?.outcome == .alreadyRestored)
        #expect(plan.statements.isEmpty)
    }

    @Test("A column the save never wrote does not count as a conflict")
    func untouchedColumnIsNotAConflict() throws {
        let stamped = RowWriteOperation(
            kind: .update,
            target: target,
            columns: ["id", "name", "updated_at"],
            primaryKeyColumns: ["id"],
            preImage: ["7", "Ada", "2026-01-01"],
            postImage: ["7", "Grace", "2026-01-01"],
            writtenColumns: ["name"],
            refusal: nil
        )
        let record = RewindRecord(
            id: UUID(), historyId: nil, connectionId: UUID(), databaseType: .sqlite,
            target: target, capturedAt: Date(timeIntervalSince1970: 0),
            generatedColumns: [], operations: [stamped]
        )
        let planner = RewindPlanner(
            record: record,
            factory: RowChangeStatementFactory(
                tableName: target.table, schemaName: nil, columns: ["id", "name", "updated_at"],
                primaryKeyColumns: ["id"], databaseType: .sqlite, pluginDriver: nil
            ),
            queryBuilder: TableQueryBuilder(databaseType: .sqlite)
        )

        let plan = try planner.plan(currentRows: [["7", "Grace", "2026-06-30"]])
        #expect(plan.rows.first?.outcome == .willRestore)
    }

    @Test("A row that is gone cannot have its values restored")
    func missingRowIsReported() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [])

        #expect(plan.rows.first?.outcome == .rowMissing)
        #expect(plan.statements.isEmpty)
    }

    @Test("A deleted row is put back, unless something already occupies its key")
    func deleteInverse() throws {
        let deleted = operation(kind: .delete, preImage: ["7", "Ada"], postImage: nil, writtenColumns: columns)

        let restored = try planner(operations: [deleted]).plan(currentRows: [])
        #expect(restored.rows.first?.outcome == .willRestore)
        #expect(restored.statements.first?.sql.hasPrefix("INSERT") == true)

        let occupied = try planner(operations: [deleted]).plan(currentRows: [["7", "Someone else"]])
        #expect(occupied.rows.first?.outcome == .rowAlreadyPresent)
        #expect(occupied.statements.isEmpty)
    }

    @Test("An added row is removed again")
    func insertInverse() throws {
        let plan = try planner(operations: [
            operation(kind: .insert, preImage: nil, postImage: ["7", "Ada"], writtenColumns: columns),
        ]).plan(currentRows: [["7", "Ada"]])

        #expect(plan.rows.first?.outcome == .willRestore)
        #expect(plan.statements.first?.sql.hasPrefix("DELETE") == true)
    }

    @Test("A refused row never reaches the statements, whatever the database now holds")
    func refusedRowIsCarriedThrough() throws {
        let plan = try planner(operations: [
            operation(
                kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"],
                writtenColumns: ["name"], refusal: .noPrimaryKey
            ),
        ]).plan(currentRows: [["7", "Grace"]])

        #expect(plan.rows.first?.outcome == .notReversible(.noPrimaryKey))
        #expect(plan.statements.isEmpty)
    }

    @Test("A binary key cannot be matched, so the row is refused rather than written blind")
    func binaryKeyIsRefused() throws {
        let target = DataWriteTarget(database: "shop", schema: nil, table: "sessions")
        let binaryKeyed = RowWriteOperation(
            kind: .delete,
            target: target,
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            preImage: [.bytes(Data([0x01, 0x02])), "Ada"],
            postImage: nil,
            writtenColumns: ["id", "name"],
            refusal: nil
        )
        let record = RewindRecord(
            id: UUID(), historyId: nil, connectionId: UUID(), databaseType: .sqlite,
            target: target, capturedAt: Date(timeIntervalSince1970: 0),
            generatedColumns: [], operations: [binaryKeyed]
        )
        let planner = RewindPlanner(
            record: record,
            factory: RowChangeStatementFactory(
                tableName: target.table, schemaName: nil, columns: ["id", "name"],
                primaryKeyColumns: ["id"], databaseType: .sqlite, pluginDriver: nil
            ),
            queryBuilder: TableQueryBuilder(databaseType: .sqlite)
        )

        #expect(planner.readQueries().isEmpty)
        let plan = try planner.plan(currentRows: [])
        #expect(plan.rows.first?.outcome == .notReversible(.keyNotComparable))
        #expect(plan.statements.isEmpty)
    }

    @Test("The read projects the recorded columns by name rather than leaving the order to SELECT *")
    func readProjectsRecordedColumns() {
        let queries = planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).readQueries()

        #expect(queries.count == 1)
        #expect(queries.first?.contains("SELECT \"id\", \"name\"") == true)
        #expect(queries.first?.contains("SELECT *") == false)
    }

    @Test("The inverse runs newest first, so a value one row freed is not taken before the other gives it up")
    func inverseRunsInReverseOrder() throws {
        let first = operation(kind: .delete, preImage: ["7", "Ada"], postImage: nil, writtenColumns: columns)
        let second = operation(kind: .insert, preImage: nil, postImage: ["8", "Grace"], writtenColumns: columns)

        let plan = try planner(operations: [first, second]).plan(currentRows: [["8", "Grace"]])

        #expect(plan.statements.count == 2)
        #expect(plan.statements.first?.sql.hasPrefix("DELETE") == true)
        #expect(plan.statements.last?.sql.hasPrefix("INSERT") == true)
    }
}
