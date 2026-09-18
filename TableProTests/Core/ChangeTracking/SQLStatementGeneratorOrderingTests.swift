//
//  SQLStatementGeneratorOrderingTests.swift
//  TableProTests
//
//  The generator used to emit every INSERT, then every UPDATE, then every DELETE, whatever order
//  the user worked in. Deleting a row to free a unique value and adding a new row that takes it is
//  a valid save that came out as a constraint violation.
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("SQL statement ordering")
struct SQLStatementGeneratorOrderingTests {
    private let columns = ["id", "email"]

    private func makeGenerator() throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "users",
            columns: columns,
            primaryKeyColumns: ["id"],
            databaseType: .sqlite,
            dialect: nil
        )
    }

    private func update(row: Int, sequence: Int) -> RowChange {
        RowChange(
            rowID: .existing(row),
            type: .update,
            cellChanges: [
                CellChange(columnIndex: 1, columnName: "email", oldValue: "old@b.com", newValue: "new@b.com"),
            ],
            originalRow: [.text("\(row)"), "old@b.com"],
            sequence: sequence
        )
    }

    private func delete(row: Int, sequence: Int) -> RowChange {
        RowChange(rowID: .existing(row), type: .delete, originalRow: [.text("\(row)"), "a@b.com"], sequence: sequence)
    }

    private func insert(row: Int, sequence: Int) -> RowChange {
        RowChange(rowID: .existing(row), type: .insert, sequence: sequence)
    }

    private func verbs(_ statements: [AttributedStatement]) -> [String] {
        statements.map { String($0.statement.sql.prefix(while: { $0 != " " })) }
    }

    @Test("A delete that frees a value runs before the insert that takes it")
    func deleteBeforeInsert() throws {
        let statements = try makeGenerator().generateAttributedStatements(
            from: [delete(row: 0, sequence: 0), insert(row: 1, sequence: 1)],
            insertedRowData: [.existing(1): ["9", "a@b.com"]],
            deletedRowIDs: [.existing(0)],
            insertedRowIDs: [.existing(1)]
        )

        #expect(verbs(statements) == ["DELETE", "INSERT"])
    }

    @Test("Every kind keeps the position the user gave it")
    func mixedOrderIsPreserved() throws {
        let statements = try makeGenerator().generateAttributedStatements(
            from: [update(row: 0, sequence: 0), delete(row: 1, sequence: 1), insert(row: 2, sequence: 2)],
            insertedRowData: [.existing(2): ["9", "c@b.com"]],
            deletedRowIDs: [.existing(1)],
            insertedRowIDs: [.existing(2)]
        )

        #expect(verbs(statements) == ["UPDATE", "DELETE", "INSERT"])
    }

    @Test("Order comes from the sequence, not the array, because a cancelled change is swap-removed")
    func arrayOrderIsNotTrusted() throws {
        let statements = try makeGenerator().generateAttributedStatements(
            from: [insert(row: 2, sequence: 5), delete(row: 1, sequence: 1)],
            insertedRowData: [.existing(2): ["9", "c@b.com"]],
            deletedRowIDs: [.existing(1)],
            insertedRowIDs: [.existing(2)]
        )

        #expect(verbs(statements) == ["DELETE", "INSERT"])
    }

    @Test("Consecutive deletes still batch into one statement")
    func consecutiveDeletesBatch() throws {
        let statements = try makeGenerator().generateAttributedStatements(
            from: [delete(row: 0, sequence: 0), delete(row: 1, sequence: 1), delete(row: 2, sequence: 2)],
            insertedRowData: [:],
            deletedRowIDs: [.existing(0), .existing(1), .existing(2)],
            insertedRowIDs: []
        )

        #expect(statements.count == 1)
        #expect(statements.first?.rowCount == 3)
    }

    @Test("A delete run interrupted by another kind splits at the interruption")
    func interruptedDeleteRunSplits() throws {
        let statements = try makeGenerator().generateAttributedStatements(
            from: [
                delete(row: 0, sequence: 0),
                update(row: 3, sequence: 1),
                delete(row: 1, sequence: 2),
            ],
            insertedRowData: [:],
            deletedRowIDs: [.existing(0), .existing(1)],
            insertedRowIDs: []
        )

        #expect(verbs(statements) == ["DELETE", "UPDATE", "DELETE"])
        #expect(statements.first?.rowCount == 1)
        #expect(statements.last?.rowCount == 1)
    }
}
