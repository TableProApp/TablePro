//
//  SnowflakeStatementTypeTests.swift
//  TableProTests
//
//  Tests for SnowflakeStatementType (compiled via symlink from SnowflakeDriverPlugin).
//

import Foundation
import Testing

@Suite("Snowflake Statement Type")
struct SnowflakeStatementTypeTests {
    private func counts(_ values: [String]) -> [PluginCellValueBox] {
        values.map { .text($0) }
    }

    @Test("The DML range is the one the server documents")
    func testDMLRange() {
        #expect(SnowflakeStatementType.isDML(0x3000))
        #expect(SnowflakeStatementType.isDML(0x3500))
        #expect(SnowflakeStatementType.isDML(0x3200))
        #expect(!SnowflakeStatementType.isDML(0x1000))
        #expect(!SnowflakeStatementType.isDML(0x2FFF))
        #expect(!SnowflakeStatementType.isDML(0x3501))
        #expect(!SnowflakeStatementType.isDML(0xA000))
    }

    @Test("An INSERT or DELETE reports its single count")
    func testSingleCount() {
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: counts(["7"])) == 7
        )
    }

    /// An `UPDATE` returns rows updated and multi-joined rows updated, and a multi-clause `MERGE`
    /// one count per clause. Reading only the first column reported the wrong number, and the guard
    /// that demanded exactly one column reported none at all.
    @Test("An UPDATE or MERGE sums every count column")
    func testMultipleCountsAreSummed() {
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: counts(["12", "0"])) == 12
        )
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: counts(["3", "4", "5"])) == 12
        )
    }

    /// The old check keyed on a column named "number of rows", so this statement reported its own
    /// result as the number of rows it had changed.
    @Test("A SELECT never reports affected rows, whatever its columns are named")
    func testSelectReportsNothing() {
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0x1000, row: counts(["1523"])) == 0
        )
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0xA000, row: counts(["1523"])) == 0
        )
    }

    @Test("A missing or unreadable count reports nothing rather than a guess")
    func testUnreadableCounts() {
        #expect(SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: nil) == 0)
        #expect(SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: []) == 0)
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: counts(["abc"])) == 0
        )
        #expect(
            SnowflakeStatementType.affectedRows(statementTypeId: 0x3000, row: [.null]) == 0
        )
    }
}
