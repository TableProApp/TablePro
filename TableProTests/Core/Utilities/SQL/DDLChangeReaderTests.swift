//
//  DDLChangeReaderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("DDLChangeReader")
struct DDLChangeReaderTests {
    private func preview(_ sql: String, type: DatabaseType = .mysql) -> SchemaChangePreview {
        DDLChangeReader.preview(id: "s", sql: sql, databaseType: type)
    }

    @Test("CREATE TABLE adds the table")
    func createTableAdds() {
        let result = preview("CREATE TABLE orders (id INT PRIMARY KEY, total DECIMAL(10,2))")

        #expect(result.target == "orders")
        #expect(result.lines.map(\.kind) == [.adds])
        #expect(result.lines.map(\.text) == ["TABLE orders"])
        #expect(!result.isDestructive)
    }

    @Test("CREATE INDEX adds the index, not the table it covers")
    func createIndexAdds() {
        let result = preview("CREATE INDEX idx_orders_total ON orders (total)")

        #expect(result.lines.map(\.text) == ["INDEX idx_orders_total"])
    }

    @Test("ALTER TABLE ADD COLUMN adds that column")
    func alterAddColumn() {
        let result = preview("ALTER TABLE orders ADD COLUMN shipped_at DATETIME NULL")

        #expect(result.target == "orders")
        #expect(result.lines.map(\.kind) == [.adds])
        #expect(result.lines.map(\.text) == ["COLUMN shipped_at"])
    }

    @Test("An implicit column kind is still read as a column")
    func alterAddImplicitColumn() {
        let result = preview("ALTER TABLE orders ADD shipped_at DATETIME")

        #expect(result.lines.map(\.text) == ["COLUMN shipped_at"])
    }

    @Test("ALTER TABLE DROP COLUMN is marked as a removal")
    func alterDropColumnIsDestructive() {
        let result = preview("ALTER TABLE orders DROP COLUMN shipped_at")

        #expect(result.lines.map(\.kind) == [.removes])
        #expect(result.lines.filter(\.isDestructive).count == result.lines.count)
        #expect(result.isDestructive)
    }

    @Test("An ALTER with two clauses reads both")
    func alterWithTwoClauses() {
        let result = preview("ALTER TABLE orders ADD COLUMN a INT, DROP COLUMN b")

        #expect(result.lines.map(\.kind) == [.adds, .removes])
        #expect(result.lines.map(\.text) == ["COLUMN a", "COLUMN b"])
    }

    @Test("DROP TABLE removes the table")
    func dropTableRemoves() {
        let result = preview("DROP TABLE IF EXISTS orders")

        #expect(result.lines.map(\.kind) == [.removes])
        #expect(result.lines.map(\.text) == ["TABLE orders"])
        #expect(result.isDestructive)
    }

    @Test("TRUNCATE names the rows, not the table")
    func truncateNamesRows() {
        let result = preview("TRUNCATE TABLE orders")

        #expect(result.lines.map(\.kind) == [.removes])
        #expect(result.lines.first?.text.contains("orders") == true)
    }

    @Test("A quoted identifier is reported unquoted")
    func quotedIdentifierIsUnquoted() {
        let result = preview("DROP TABLE `order items`")

        #expect(result.target == "order items")
    }

    @Test("A keyword inside a string literal is not read as a clause")
    func keywordInsideLiteralIsIgnored() {
        let result = preview("ALTER TABLE orders ADD COLUMN note TEXT DEFAULT 'DROP COLUMN total'")

        #expect(result.lines.map(\.kind) == [.adds])
        #expect(result.lines.map(\.text) == ["COLUMN note"])
    }

    @Test("A statement the reader cannot be sure about yields no lines")
    func unparseableStatementYieldsNoLines() {
        let result = preview("ALTER TABLE orders ENGINE = InnoDB")

        #expect(result.lines.isEmpty)
        #expect(result.sql == "ALTER TABLE orders ENGINE = InnoDB")
    }

    @Test("A leading comment does not hide the statement")
    func leadingCommentIsStripped() {
        let result = preview("-- migrate\nDROP TABLE orders")

        #expect(result.lines.map(\.text) == ["TABLE orders"])
        #expect(result.sql == "DROP TABLE orders")
    }

    @Test("A SELECT is not DDL")
    func selectIsNotDDL() {
        #expect(!DDLChangeReader.looksLikeDDL("SELECT 1"))
        #expect(DDLChangeReader.looksLikeDDL("create table t (id int)"))
    }
}
