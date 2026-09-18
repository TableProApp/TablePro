//
//  SQLWriteBatchBudgetTests.swift
//  TableProTests
//
//  The arithmetic that used to live on ObjectCopyRowCopier, plus the byte bound it never had.
//  A bind-parameter count is not a size: one statement is one packet, and a packet over the
//  server's max_allowed_packet is rejected outright.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class SQLWriteBatchBudgetTests: XCTestCase {
    private func generator(_ databaseType: DatabaseType) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: "t", columns: [], primaryKeyColumns: [], databaseType: databaseType)
    }

    // MARK: - Row bounds, ported from ObjectCopyRowCopierTests

    func testTheRowCapNeverExceedsTheEnginesBindParameterCeiling() throws {
        let mssql = try SQLWriteBatchBudget(columnCount: 100, generator: generator(.mssql))
        let sqlite = try SQLWriteBatchBudget(columnCount: 100, generator: generator(.sqlite))

        XCTAssertEqual(mssql.maxRows, 21)
        XCTAssertEqual(sqlite.maxRows, 327)
    }

    /// A one-column table would otherwise put 65,535 rows in one statement, which parses slowly
    /// everywhere and cannot be cancelled part-way.
    func testTheRowCapIsCappedByRowsAsWellAsByParameters() throws {
        let mysql = try SQLWriteBatchBudget(columnCount: 1, generator: generator(.mysql))

        XCTAssertEqual(mysql.maxRows, 1_000)
    }

    /// Oracle before 23c rejects `INSERT … VALUES (…), (…)`, which is the only form the generic
    /// generator emits, so its batches carry one row each however narrow the table is.
    func testOracleTakesOneRowPerStatement() throws {
        let oracle = try SQLWriteBatchBudget(columnCount: 2, generator: generator(.oracle))

        XCTAssertEqual(oracle.maxRows, 1)
    }

    /// A table wider than the ceiling still writes one row at a time rather than none.
    func testAVeryWideTableStillWritesOneRowPerStatement() throws {
        let mssql = try SQLWriteBatchBudget(columnCount: 5_000, generator: generator(.mssql))

        XCTAssertEqual(mssql.maxRows, 1)
    }

    /// An engine with no documented multi-row ceiling keeps the flat thousand rather than taking
    /// its parameter ceiling: a five-column PostgreSQL table would otherwise jump to 13,107.
    func testAnEngineWithNoSyntaxCeilingKeepsTheFlatRowCap() throws {
        let postgres = try SQLWriteBatchBudget(columnCount: 5, generator: generator(.postgresql))

        XCTAssertEqual(SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: "PostgreSQL"), .max)
        XCTAssertEqual(postgres.maxRows, 1_000)
    }

    // MARK: - Byte bounds

    /// The reported defect: 500 rows of three 1 MB values sit inside a three-column table's
    /// 21,845-row parameter ceiling and went out as one ~500 MB statement the server refused.
    func testAByteHeavyRowClosesTheBatchLongBeforeTheRowCap() throws {
        let budget = try SQLWriteBatchBudget(columnCount: 3, generator: generator(.mysql))
        let megabyte = budget.byteCount(
            of: (0 ..< 3).map { _ in PluginCellValue.text(String(repeating: "a", count: 1_048_576)) })

        XCTAssertGreaterThan(budget.maxRows, 500, "the parameter ceiling alone allows far more")
        XCTAssertFalse(budget.hasRoom(for: megabyte, inBatchOf: 1, bytes: megabyte))
    }

    /// A row cannot be split across two statements, so an empty batch takes it whatever it weighs.
    func testAnEmptyBatchTakesARowOverTheWholeBudget() {
        let budget = SQLWriteBatchBudget(maxRows: 500)
        let huge = 10 * SQLWriteBatchBudget.maximumBytes

        XCTAssertTrue(budget.hasRoom(for: huge, inBatchOf: 0, bytes: 0))
        XCTAssertFalse(budget.hasRoom(for: 1, inBatchOf: 1, bytes: huge))
    }

    func testTheRowCapStillClosesABatchOfNarrowRows() {
        let budget = SQLWriteBatchBudget(maxRows: 2)

        XCTAssertTrue(budget.hasRoom(for: 10, inBatchOf: 1, bytes: 10))
        XCTAssertFalse(budget.hasRoom(for: 10, inBatchOf: 2, bytes: 20))
    }

    /// Every value carries a length prefix, a type-array entry and a null-bitmap bit, so a row of
    /// NULLs is not free. Measured against MariaDB 12.3.3, the real per-value cost settles near 6
    /// bytes; 12 is the documented upper bound and over-charging is the safe direction.
    func testEveryValueCostsItsOverheadEvenWhenItCarriesNothing() {
        let budget = SQLWriteBatchBudget(maxRows: 500)

        XCTAssertEqual(budget.byteCount(of: [PluginCellValue.null]), 12)
        XCTAssertEqual(budget.byteCount(of: [PluginCellValue.text("abc")]), 15)
        XCTAssertEqual(
            budget.byteCount(of: [PluginCellValue.bytes(Data(repeating: 0, count: 100))]), 112)
        XCTAssertEqual(budget.byteCount(of: [PluginCellValue]()), 0)
    }

    /// Databend's driver inlines a parameter into the SQL, so binary crosses as hex at two
    /// characters a byte. Charged the bind-parameter rate, the cap bounded nothing on that engine.
    func testAnEngineThatInlinesItsValuesIsChargedDouble() throws {
        let databend = try SQLWriteBatchBudget(columnCount: 1, generator: generator(.databend))
        let mysql = try SQLWriteBatchBudget(columnCount: 1, generator: generator(.mysql))
        let value = [PluginCellValue.bytes(Data(repeating: 0xAB, count: 400_000))]

        XCTAssertTrue(databend.rendersValuesAsLiterals)
        XCTAssertFalse(mysql.rendersValuesAsLiterals)
        XCTAssertEqual(mysql.byteCount(of: value), 400_012)
        XCTAssertEqual(databend.byteCount(of: value), 800_012)
        XCTAssertFalse(
            databend.hasRoom(for: databend.byteCount(of: value), inBatchOf: 1,
                             bytes: databend.byteCount(of: value)),
            "two of these exceed a mebibyte of rendered SQL, so the second must close the batch"
        )
    }

    /// A multi-byte value is charged its UTF-8 length, not its character count: the packet the
    /// server measures carries bytes.
    func testAMultiByteValueIsChargedItsBytes() {
        let emoji = String(repeating: "😀", count: 10)

        XCTAssertEqual(emoji.count, 10)
        XCTAssertEqual(
            SQLWriteBatchBudget(maxRows: 500).byteCount(of: [PluginCellValue.text(emoji)]), 12 + 40)
    }

    // MARK: - The filler

    func testTheFillerClosesABatchBeforeTheRowThatWouldCrossTheBudget() {
        var filler = SQLWriteBatchFiller<Int>(budget: SQLWriteBatchBudget(maxRows: 100, maxBytes: 100))

        XCTAssertNil(filler.append(1, bytes: 60))
        let closed = filler.append(2, bytes: 60)
        XCTAssertEqual(closed, [1], "the first row goes out alone rather than the pair overflowing")
        XCTAssertEqual(filler.take(), [2], "the row that closed the batch is held, never dropped")
        XCTAssertNil(filler.take())
    }

    func testTheFillerNeverDropsARow() {
        var filler = SQLWriteBatchFiller<Int>(budget: SQLWriteBatchBudget(maxRows: 2, maxBytes: 1_000))
        var written: [Int] = []

        for row in 1 ... 5 {
            if let batch = filler.append(row, bytes: 1) { written.append(contentsOf: batch) }
        }
        if let batch = filler.take() { written.append(contentsOf: batch) }

        XCTAssertEqual(written, [1, 2, 3, 4, 5])
    }
}
