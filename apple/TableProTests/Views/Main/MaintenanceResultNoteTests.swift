//
//  MaintenanceResultNoteTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MaintenanceResultNoteTests {
    private func result(
        columns: [String] = [],
        rows: [[PluginCellValue]] = [],
        statusMessage: String? = nil
    ) -> QueryResult {
        var result = QueryResult(
            columns: columns,
            columnTypes: [],
            rows: rows,
            rowsAffected: 0,
            executionTime: 0,
            error: nil
        )
        result.statusMessage = statusMessage
        return result
    }

    private let mysqlColumns = ["Table", "Op", "Msg_type", "Msg_text"]

    @Test("MySQL's OPTIMIZE note on InnoDB reaches the person, its OK row does not")
    func keepsTheOptimizeNote() {
        let optimize = result(columns: mysqlColumns, rows: [
            [.text("shop.orders"), .text("optimize"), .text("note"),
             .text("Table does not support optimize, doing recreate + analyze instead")],
            [.text("shop.orders"), .text("optimize"), .text("status"), .text("OK")]
        ])

        #expect(MaintenanceResultNote.note(from: [optimize])
            == "Table does not support optimize, doing recreate + analyze instead")
    }

    @Test("A plain OK from the server is no note")
    func plainOKIsNoNote() {
        let analyze = result(columns: mysqlColumns, rows: [
            [.text("shop.orders"), .text("analyze"), .text("status"), .text("OK")]
        ])
        let integrity = result(columns: ["integrity_check"], rows: [[.text("ok")]])

        #expect(MaintenanceResultNote.note(from: [analyze, integrity]) == nil)
        #expect(MaintenanceResultNote.note(from: [result(statusMessage: "OK")]) == nil)
    }

    @Test("A statement that returns nothing is no note")
    func silentStatementIsNoNote() {
        #expect(MaintenanceResultNote.note(from: [result(), result(statusMessage: "  ")]) == nil)
    }

    @Test("Every problem SQLite's integrity check lists is kept")
    func keepsIntegrityProblems() {
        let integrity = result(columns: ["integrity_check"], rows: [
            [.text("row 4 missing from index idx_orders_total")],
            [.text("wrong # of entries in index idx_orders_total")]
        ])

        #expect(MaintenanceResultNote.note(from: [integrity])
            == "row 4 missing from index idx_orders_total\nwrong # of entries in index idx_orders_total")
    }

    @Test("A driver's status message is kept beside the rows of the other statements")
    func keepsTheStatusMessage() {
        let first = result(statusMessage: "Table status: UPDATING")
        let second = result(columns: mysqlColumns, rows: [
            [.text("shop.orders"), .text("repair"), .text("note"),
             .text("The storage engine for the table doesn't support repair")]
        ])

        #expect(MaintenanceResultNote.note(from: [first, second])
            == "Table status: UPDATING\nThe storage engine for the table doesn't support repair")
    }

    @Test("Rows of an unrelated shape are not read as notes")
    func ignoresOtherColumns() {
        let response = result(columns: ["TableName", "Status"], rows: [[.text("orders"), .text("ACTIVE")]])

        #expect(MaintenanceResultNote.note(from: [response]) == nil)
    }
}
