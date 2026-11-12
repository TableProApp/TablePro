//
//  RewindPlannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RewindPlannerTests {
    private let columns = ["id", "name"]
    private let target = DataWriteTarget(database: "shop", schema: nil, table: "users")
    private let sqliteQueryBuilder = TableQueryBuilder(
        databaseType: .sqlite,
        dialect: PluginManager.shared.sqlDialect(for: .sqlite),
        pagination: .offset,
        dialectQuote: SQLEscaping.quoteIdentifier
    )

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

    private func planner(operations: [RowWriteOperation], writtenThroughView: Bool? = nil) -> RewindPlanner {
        let record = RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .sqlite,
            target: target,
            capturedAt: Date(timeIntervalSince1970: 0),
            generatedColumns: [],
            identityColumns: [],
            operations: operations,
            writtenThroughView: writtenThroughView
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
            queryBuilder: sqliteQueryBuilder
        )
    }

    @Test("A row deleted through a view is not restored, while an edit through it still is")
    func viewDeleteIsRefused() throws {
        let delete = operation(kind: .delete, preImage: ["7", "Ada"], postImage: nil, writtenColumns: columns)
        let update = operation(
            kind: .update, preImage: ["8", "Ada"], postImage: ["8", "Grace"], writtenColumns: ["name"]
        )
        let plan = try planner(operations: [delete, update], writtenThroughView: true)
            .plan(currentRows: [RewindCurrentRow(values: ["8", "Grace"])])

        #expect(plan.rows.map { $0.outcome } == [.notReversible(.deletedThroughView), .willRestore])
        #expect(plan.record.reversibleOperations.map { $0.kind } == [.update])
    }

    @Test("A record written through a view stores no refusal an older build cannot read")
    func viewRecordStaysReadable() throws {
        let delete = operation(
            kind: .delete,
            preImage: ["7", "Ada"],
            postImage: nil,
            writtenColumns: columns,
            refusal: .identityNotPreservable
        )
        let record = planner(operations: [delete], writtenThroughView: true).record
        let encoded = try JSONEncoder().encode(record)

        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!text.contains("deletedThroughView"))
        #expect(!text.contains("rowLeftView"))
        let decoded = try JSONDecoder().decode(RewindRecord.self, from: encoded)
        #expect(decoded.refusal(of: delete) == .deletedThroughView)
        #expect(decoded.blanketRefusal == .deletedThroughView)
    }

    @Test("Undoing an insert through a view records a delete older builds refuse to restore")
    func inverseOfAViewInsertRefusesItsDelete() throws {
        let insert = operation(kind: .insert, preImage: nil, postImage: ["9", "Lin"], writtenColumns: columns)
        let plan = try planner(operations: [insert], writtenThroughView: true)
            .plan(currentRows: [RewindCurrentRow(values: ["9", "Lin"])])

        let inverse = RewindExecutor.inverseOperations(of: plan)

        #expect(inverse.map { $0.kind } == [.delete])
        #expect(inverse.first?.refusal == .identityNotPreservable)
    }

    @Test("A row a view no longer shows is refused, not reported as restored or gone")
    func rowThatLeftTheViewIsRefused() throws {
        let insert = operation(kind: .insert, preImage: nil, postImage: ["9", "Lin"], writtenColumns: columns)
        let update = operation(
            kind: .update, preImage: ["8", "Ada"], postImage: ["8", "Grace"], writtenColumns: ["name"]
        )
        let throughView = try planner(operations: [insert, update], writtenThroughView: true).plan(currentRows: [])
        #expect(throughView.rows.map { $0.outcome } == [.notReversible(.rowLeftView), .notReversible(.rowLeftView)])

        let throughTable = try planner(operations: [insert, update]).plan(currentRows: [])
        #expect(throughTable.rows.map { $0.outcome } == [.alreadyRestored, .rowMissing])
    }

    @Test("A row still holding what the save wrote is restored")
    func unchangedRowRestores() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [RewindCurrentRow(values: ["7", "Grace"])])

        #expect(plan.rows.first?.outcome == .willRestore)
        #expect(plan.restorableCount == 1)
        #expect(plan.statements.count == 1)
    }

    @Test("An edit's restore reads its row again inside the write and holds it to what the save left")
    func restoredEditHoldsTheRowAsReviewed() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [RewindCurrentRow(values: ["7", "Grace"])])

        let lookup = try #require(plan.lookups.first ?? nil)
        #expect(lookup.rowCount == 1)
        #expect(lookup.heldValues == [1: "Grace"])
        #expect(lookup.query.sql.contains("\"id\""))
        #expect(lookup.query.sql.contains("'7'"))
    }

    @Test("Removing an inserted row holds it to what the save wrote; restoring a deleted one does not read")
    func insertAndDeleteRestoreLookups() throws {
        let insert = operation(kind: .insert, preImage: nil, postImage: ["9", "Lin"], writtenColumns: columns)
        let delete = operation(kind: .delete, preImage: ["7", "Ada"], postImage: nil, writtenColumns: columns)
        let plan = try planner(operations: [insert, delete]).plan(currentRows: [RewindCurrentRow(values: ["9", "Lin"])])

        #expect(plan.statements.count == 2)
        let held = plan.lookups.compactMap { $0?.heldValues }
        #expect(held == [[0: "9", 1: "Lin"]])
    }

    @Test("A row someone else changed is left alone, and no statement is generated for it")
    func changedRowIsSkipped() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [RewindCurrentRow(values: ["7", "Hopper"])])

        #expect(plan.rows.first?.outcome == .changedSinceSave)
        #expect(plan.restorableCount == 0)
        #expect(plan.statements.isEmpty)
        #expect(plan.canApply == false)
    }

    @Test("A row already back at its old value is reported as such, so a half-finished rewind can be re-run")
    func alreadyRestoredRowIsIdempotent() throws {
        let plan = try planner(operations: [
            operation(kind: .update, preImage: ["7", "Ada"], postImage: ["7", "Grace"], writtenColumns: ["name"]),
        ]).plan(currentRows: [RewindCurrentRow(values: ["7", "Ada"])])

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
            generatedColumns: [], identityColumns: [], operations: [stamped]
        )
        let planner = RewindPlanner(
            record: record,
            factory: RowChangeStatementFactory(
                tableName: target.table, schemaName: nil, columns: ["id", "name", "updated_at"],
                primaryKeyColumns: ["id"], databaseType: .sqlite, pluginDriver: nil
            ),
            queryBuilder: sqliteQueryBuilder
        )

        let plan = try planner.plan(currentRows: [RewindCurrentRow(values: ["7", "Grace", "2026-06-30"])])
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

        let occupied = try planner(operations: [deleted])
            .plan(currentRows: [RewindCurrentRow(values: ["7", "Someone else"])])
        #expect(occupied.rows.first?.outcome == .rowAlreadyPresent)
        #expect(occupied.statements.isEmpty)
    }

    @Test("An added row is removed again")
    func insertInverse() throws {
        let plan = try planner(operations: [
            operation(kind: .insert, preImage: nil, postImage: ["7", "Ada"], writtenColumns: columns),
        ]).plan(currentRows: [RewindCurrentRow(values: ["7", "Ada"])])

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
        ]).plan(currentRows: [RewindCurrentRow(values: ["7", "Grace"])])

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
            generatedColumns: [], identityColumns: [], operations: [binaryKeyed]
        )
        let planner = RewindPlanner(
            record: record,
            factory: RowChangeStatementFactory(
                tableName: target.table, schemaName: nil, columns: ["id", "name"],
                primaryKeyColumns: ["id"], databaseType: .sqlite, pluginDriver: nil
            ),
            queryBuilder: sqliteQueryBuilder
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

    @Test("An edit that changed the key is read and restored under the key the save gave it")
    func movedKeyIsFoundUnderItsNewKey() throws {
        let moved = operation(kind: .update, preImage: ["k5", "Ada"], postImage: ["k6", "Ada"], writtenColumns: ["id"])
        let rewind = planner(operations: [moved])

        let query = try #require(rewind.readQueries().first)
        #expect(query.contains("k6"))
        #expect(query.contains("k5"))

        let plan = try rewind.plan(currentRows: [RewindCurrentRow(values: ["k6", "Ada"])])
        #expect(plan.rows.map { $0.outcome } == [.willRestore])
        #expect(plan.statements.first?.sql.hasPrefix("UPDATE") == true)
        #expect(plan.statements.first?.parameters.compactMap { $0 as? String } == ["k5", "k6"])
    }

    @Test("A moved row a rewind already put back reads as restored, and another row on its old key does not")
    func movedKeyAlreadyRestored() throws {
        let moved = operation(
            kind: .update, preImage: ["k5", "Ada"], postImage: ["k6", "Grace"], writtenColumns: ["id", "name"]
        )

        let restored = try planner(operations: [moved]).plan(currentRows: [RewindCurrentRow(values: ["k5", "Ada"])])
        #expect(restored.rows.map { $0.outcome } == [.alreadyRestored])
        #expect(restored.statements.isEmpty)

        let taken = try planner(operations: [moved]).plan(currentRows: [RewindCurrentRow(values: ["k5", "Bo"])])
        #expect(taken.rows.map { $0.outcome } == [.rowMissing])
        #expect(taken.statements.isEmpty)
    }

    @Test("A row that took the key a save moved to is left alone, though the save wrote only the key")
    func rowOnTheMovedKeyIsNotRewritten() throws {
        let moved = operation(kind: .update, preImage: ["k5", "Ada"], postImage: ["k6", "Ada"], writtenColumns: ["id"])

        let plan = try planner(operations: [moved]).plan(currentRows: [RewindCurrentRow(values: ["k6", "Bo"])])

        #expect(plan.rows.map { $0.outcome } == [.changedSinceSave])
        #expect(plan.statements.isEmpty)
    }

    @Test("A moved row is not held to a column the server computes")
    func movedKeyIgnoresGeneratedColumns() throws {
        let columns = ["id", "name", "updated_at"]
        let moved = RowWriteOperation(
            kind: .update, target: target, columns: columns, primaryKeyColumns: ["id"],
            preImage: ["k5", "Ada", "2026-01-01"], postImage: ["k6", "Ada", "2026-01-01"],
            writtenColumns: ["id"], refusal: nil
        )
        let record = RewindRecord(
            id: UUID(), historyId: nil, connectionId: UUID(), databaseType: .sqlite,
            target: target, capturedAt: Date(timeIntervalSince1970: 0),
            generatedColumns: ["updated_at"], identityColumns: [], operations: [moved]
        )
        let planner = RewindPlanner(
            record: record,
            factory: RowChangeStatementFactory(
                tableName: target.table, schemaName: nil, columns: columns, primaryKeyColumns: ["id"],
                generatedColumns: ["updated_at"], databaseType: .sqlite, pluginDriver: nil
            ),
            queryBuilder: sqliteQueryBuilder
        )

        let plan = try planner.plan(currentRows: [RewindCurrentRow(values: ["k6", "Ada", "2026-06-30"])])

        #expect(plan.rows.map { $0.outcome } == [.willRestore])
    }

    @Test("Undoing a restore takes back what the restore did last first")
    func inverseRecordRunsBackwards() throws {
        let deleted = operation(kind: .delete, preImage: ["7", "Ada"], postImage: nil, writtenColumns: columns)
        let inserted = operation(kind: .insert, preImage: nil, postImage: ["8", "Ada"], writtenColumns: columns)
        let plan = try planner(operations: [deleted, inserted])
            .plan(currentRows: [RewindCurrentRow(values: ["8", "Ada"])])

        let inverse = RewindExecutor.inverseOperations(of: plan)
        #expect(inverse.map { $0.kind } == [.delete, .insert])

        let undo = try planner(operations: inverse).plan(currentRows: [RewindCurrentRow(values: ["7", "Ada"])])
        #expect(undo.statements.map { String($0.sql.prefix(6)) } == ["DELETE", "INSERT"])
    }

    private func recordedOperations(_ edits: (inout PendingChanges) -> Void) -> [RowWriteOperation] {
        var pending = PendingChanges()
        edits(&pending)
        return RowWriteOperationBuilder.operations(
            from: pending.changes,
            insertedRowData: pending.insertedRowData,
            deletedRowIDs: pending.deletedRowIDs,
            insertedRowIDs: pending.insertedRowIDs,
            target: target,
            columns: columns,
            primaryKeyColumns: ["id"],
            generatedColumns: [],
            containsTableOperation: false
        )
    }

    // A.name a to tmp, B.name b to a, A.name tmp to b: valid step by step on a unique `name`.
    private func swapOperations() -> [RowWriteOperation] {
        recordedOperations { pending in
            pending.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name", oldValue: "a", newValue: "tmp",
                originalRow: ["k1", "a"]
            )
            pending.recordCellChange(
                rowID: .existing(1), columnIndex: 1, columnName: "name", oldValue: "b", newValue: "a",
                originalRow: ["k2", "b"]
            )
            pending.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name", oldValue: "tmp", newValue: "b",
                originalRow: ["k1", "tmp"]
            )
        }
    }

    private func bound(_ statements: [ParameterizedStatement]) -> [[String]] {
        statements.map { statement in statement.parameters.compactMap { $0 as? String } }
    }

    @Test("A swap rewinds its newest step first, so no step takes a value another still holds")
    func aSwapRewindsNewestStepFirst() throws {
        let plan = try planner(operations: swapOperations()).plan(currentRows: [
            RewindCurrentRow(values: ["k1", "b"]), RewindCurrentRow(values: ["k2", "a"])
        ])

        #expect(plan.rows.map { $0.outcome } == [.willRestore, .willRestore])
        #expect(bound(plan.statements) == [["tmp", "k1"], ["b", "k2"], ["a", "k1"]])
    }

    @Test("Undoing the rewind of a swap replays the save in its own order")
    func undoingASwapRewindReplaysTheSave() throws {
        let rewind = try planner(operations: swapOperations()).plan(currentRows: [
            RewindCurrentRow(values: ["k1", "b"]), RewindCurrentRow(values: ["k2", "a"])
        ])

        let undo = try planner(operations: RewindExecutor.inverseOperations(of: rewind)).plan(currentRows: [
            RewindCurrentRow(values: ["k1", "a"]), RewindCurrentRow(values: ["k2", "b"])
        ])

        #expect(bound(undo.statements) == [["tmp", "k1"], ["a", "k2"], ["b", "k1"]])
    }

    @Test("A key moved in an earlier step is rewound under the key each step left")
    func aKeyMovedInTheFirstStepRewindsUnderEachStepsKey() throws {
        let operations = recordedOperations { pending in
            pending.recordCellChange(
                rowID: .existing(0), columnIndex: 0, columnName: "id", oldValue: "k5", newValue: "k6",
                originalRow: ["k5", "Ada"]
            )
            pending.recordRowDeletion(rowID: .existing(1), originalRow: ["k7", "Bo"])
            pending.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name", oldValue: "Ada", newValue: "Grace",
                originalRow: ["k6", "Ada"]
            )
        }

        let plan = try planner(operations: operations).plan(currentRows: [RewindCurrentRow(values: ["k6", "Grace"])])
        let verbs = plan.statements.map { String($0.sql.prefix(6)) }

        #expect(plan.rows.map { $0.outcome } == [.willRestore, .willRestore])
        #expect(verbs == ["UPDATE", "INSERT", "UPDATE"])
        #expect(bound(plan.statements).first == ["Ada", "k6"])
        #expect(bound(plan.statements).last == ["k5", "k6"])
    }

    @Test("A step that wrote SQL refuses the row, though a later step replaced it with a value")
    func aStepThatWroteSQLRefusesTheRow() throws {
        let operations = recordedOperations { pending in
            pending.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name", oldValue: "Ada", newValue: "now()",
                originalRow: ["k1", "Ada"], isExpression: true
            )
            pending.recordRowDeletion(rowID: .existing(1), originalRow: ["k2", "Bo"])
            pending.recordCellChange(
                rowID: .existing(0), columnIndex: 1, columnName: "name", oldValue: "now()", newValue: "Grace",
                originalRow: ["k1", "now()"]
            )
        }

        let update = try #require(operations.first { $0.kind == .update })
        #expect(update.refusal == .serverComputedValue)
        let plan = try planner(operations: operations).plan(currentRows: [RewindCurrentRow(values: ["k1", "Grace"])])
        #expect(plan.rows.first?.outcome == .notReversible(.serverComputedValue))
    }

    @Test("A record saved before steps were kept rewinds newest first by list position")
    func aRecordWithoutStepsRewindsAsBefore() throws {
        let first = operation(kind: .update, preImage: ["k1", "Ada"], postImage: ["k1", "Grace"], writtenColumns: ["name"])
        let second = operation(kind: .update, preImage: ["k2", "Bo"], postImage: ["k2", "Cy"], writtenColumns: ["name"])

        let plan = try planner(operations: [first, second]).plan(currentRows: [
            RewindCurrentRow(values: ["k1", "Grace"]), RewindCurrentRow(values: ["k2", "Cy"])
        ])

        #expect(bound(plan.statements) == [["Bo", "k2"], ["Ada", "k1"]])
    }

    @Test("A deleted row comes back once the new row that took its key is removed, and not while that row was changed")
    func aDeletedRowComesBackAfterTheNewRowThatTookItsKey() throws {
        let operations = recordedOperations { pending in
            pending.recordRowDeletion(rowID: .existing(0), originalRow: ["k5", "Ada"])
            pending.recordRowInsertion(rowID: .inserted(UUID()), values: ["k5", "Bo"])
        }

        let plan = try planner(operations: operations).plan(currentRows: [RewindCurrentRow(values: ["k5", "Bo"])])
        let verbs = plan.statements.map { String($0.sql.prefix(6)) }
        #expect(plan.rows.map { $0.outcome } == [.willRestore, .willRestore])
        #expect(verbs == ["DELETE", "INSERT"])

        let changed = try planner(operations: operations).plan(currentRows: [RewindCurrentRow(values: ["k5", "Cy"])])
        #expect(changed.rows.map { $0.outcome } == [.rowAlreadyPresent, .changedSinceSave])
        #expect(changed.statements.isEmpty)
    }

    @Test("The inverse runs newest first, so a value one row freed is not taken before the other gives it up")
    func inverseRunsInReverseOrder() throws {
        let first = operation(kind: .delete, preImage: ["7", "Ada"], postImage: nil, writtenColumns: columns)
        let second = operation(kind: .insert, preImage: nil, postImage: ["8", "Grace"], writtenColumns: columns)

        let plan = try planner(operations: [first, second])
            .plan(currentRows: [RewindCurrentRow(values: ["8", "Grace"])])

        #expect(plan.statements.count == 2)
        #expect(plan.statements.first?.sql.hasPrefix("DELETE") == true)
        #expect(plan.statements.last?.sql.hasPrefix("INSERT") == true)
    }
}
