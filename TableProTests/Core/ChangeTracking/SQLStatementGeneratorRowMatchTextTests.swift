//
//  SQLStatementGeneratorRowMatchTextTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQL Statement Generator: keyless row match on text")
@MainActor
struct SQLStatementGeneratorRowMatchTextTests {
    private let columns = ["price", "ratio", "doc", "qty"]
    private let originalRow: [PluginCellValue] = ["1.1", "0.3", "{\"a\": 1}", "1"]
    private let lossy: Set<String> = ["price", "ratio", "doc"]

    private func generator(
        primaryKeyColumns: [String] = [],
        textColumns: Set<String>
    ) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "t",
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            databaseType: .mysql,
            rowMatchPolicy: RowMatchPolicy(textColumns: textColumns),
            quoteIdentifier: { "`\($0)`" }
        )
    }

    private func update(_ old: String = "1", _ new: String = "2") -> RowChange {
        RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(columnIndex: 3, columnName: "qty", oldValue: .text(old), newValue: .text(new))
            ],
            originalRow: originalRow
        )
    }

    @Test("A keyless update compares the lossy columns through the server's own rendering")
    func keylessUpdateWrapsLossyColumns() throws {
        let statement = try #require(
            try generator(textColumns: lossy).generateUpdateSQL(for: update())
        )
        #expect(statement.sql == """
            UPDATE `t` SET `qty` = ? WHERE CONCAT(`price`) = ? AND CONCAT(`ratio`) = ? \
            AND CONCAT(`doc`) = ? AND `qty` = ?
            """)
        #expect(statement.parameters.count == 5)
    }

    @Test("A keyed update is untouched, because a primary key compares as it is")
    func keyedUpdateIsUnwrapped() throws {
        let statement = try #require(
            try generator(primaryKeyColumns: ["price"], textColumns: lossy).generateUpdateSQL(for: update())
        )
        #expect(statement.sql == "UPDATE `t` SET `qty` = ? WHERE `price` = ?")
    }

    @Test("An engine that lists no such type keeps the comparison it has always made")
    func noTextColumnsKeepsPlainComparison() throws {
        let statement = try #require(
            try generator(textColumns: []).generateUpdateSQL(for: update())
        )
        #expect(statement.sql == """
            UPDATE `t` SET `qty` = ? WHERE `price` = ? AND `ratio` = ? AND `doc` = ? AND `qty` = ?
            """)
    }

    @Test("A NULL in a lossy column compares through the same rendering")
    func keylessUpdateWrapsNullComparison() throws {
        let change = RowChange(
            rowID: .existing(0),
            type: .update,
            cellChanges: [
                CellChange(columnIndex: 3, columnName: "qty", oldValue: .text("1"), newValue: .text("2"))
            ],
            originalRow: ["1.1", .null, "{\"a\": 1}", "1"]
        )
        let statement = try #require(try generator(textColumns: lossy).generateUpdateSQL(for: change))
        #expect(statement.sql.contains("CONCAT(`ratio`) IS NULL"))
        #expect(statement.parameters.count == 4)
    }

    @Test("A keyless delete compares the same way the update does")
    func keylessDeleteWrapsLossyColumns() throws {
        let change = RowChange(rowID: .existing(0), type: .delete, cellChanges: [], originalRow: originalRow)
        let statements = try generator(textColumns: lossy).generateStatements(
            from: [change], insertedRowData: [:], deletedRowIDs: [.existing(0)], insertedRowIDs: []
        )
        let sql = try #require(statements.first?.sql)
        #expect(sql == """
            DELETE FROM `t` WHERE (CONCAT(`price`) = ? AND CONCAT(`ratio`) = ? \
            AND CONCAT(`doc`) = ? AND `qty` = ?)
            """)
    }

    @Test("An insert never compares a row, so it carries no rendering")
    func insertIsUnaffected() throws {
        let change = RowChange(rowID: .existing(0), type: .insert, cellChanges: [], originalRow: nil)
        let statements = try generator(textColumns: lossy).generateStatements(
            from: [change],
            insertedRowData: [.existing(0): [.text("2.5"), .text("0.3"), .null, .text("1")]],
            deletedRowIDs: [],
            insertedRowIDs: [.existing(0)]
        )
        let sql = try #require(statements.first?.sql)
        #expect(!sql.contains("CONCAT"))
    }
}
