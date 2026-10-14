import Foundation
import TableProSQLGrammar
import Testing

@Suite("SQL statement batches")
struct SQLStatementBatchTests {
    private static let sqlServer = SQLLexicalReadings.resolve(
        databaseTypeId: "SQL Server",
        declared: nil,
        session: nil
    ).execution

    private func batches(_ text: String, sourceOffset: Int = 0) -> [SQLStatementBatch] {
        SQLStatementScanner.batches(
            in: text,
            statements: SQLStatementScanner.executableStatements(in: text, grammar: Self.sqlServer),
            separators: SQLStatementScanner.batchSeparators(in: text, grammar: Self.sqlServer),
            sourceOffset: sourceOffset
        )
    }

    @Test("A script with no GO line is one batch holding every statement and the text between them")
    func noSeparatorIsOneBatch() throws {
        let text = "DECLARE @n int = 1;\nSELECT @n;"
        let result = batches(text)
        #expect(result.count == 1)
        let batch = try #require(result.first)
        #expect(batch.statements.map(\.sql) == ["DECLARE @n int = 1", "SELECT @n"])
        #expect(batch.sql == "DECLARE @n int = 1;\nSELECT @n")
        #expect(batch.repeatCount == 1)
    }

    @Test("GO lines end batches, and a GO count belongs to the batch before it")
    func separatorsSplitAndRepeat() {
        let text = "CREATE TABLE t (id int)\nGO\nINSERT INTO t VALUES (1)\nGO 3\nSELECT * FROM t"
        let result = batches(text)
        #expect(result.map(\.sql) == ["CREATE TABLE t (id int)", "INSERT INTO t VALUES (1)", "SELECT * FROM t"])
        #expect(result.map(\.repeatCount) == [1, 3, 1])
    }

    @Test("A GO line with nothing before it makes no empty batch")
    func leadingSeparatorMakesNoBatch() {
        let result = batches("GO\nSELECT 1\nGO\nGO\n")
        #expect(result.map(\.sql) == ["SELECT 1"])
    }

    @Test("Statements and the batch range move by the source offset")
    func sourceOffsetShiftsRanges() throws {
        let text = "SELECT 1;\nSELECT 2"
        let batch = try #require(batches(text, sourceOffset: 100).first)
        #expect(batch.statements.map(\.range.location) == [100, 110])
        #expect(batch.range == NSRange(location: 100, length: 18))
    }
}
