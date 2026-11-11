import Foundation
import TableProOracleCore
import Testing

struct OracleRowBatcherTests {
    private static func row(_ index: Int) -> [OracleRawCell] {
        [.string(String(index))]
    }

    // The batch sizes the stream carries for `count` rows, in order, and the rows they carry.
    private static func drive(_ batcher: OracleRowBatcher, rows count: Int) -> (sizes: [Int], rows: [[OracleRawCell]]) {
        var batcher = batcher
        var sizes: [Int] = []
        var rows: [[OracleRawCell]] = []
        for index in 0..<count {
            if let batch = batcher.append(row(index)) {
                sizes.append(batch.count)
                rows.append(contentsOf: batch)
            }
        }
        if let batch = batcher.remainder() {
            sizes.append(batch.count)
            rows.append(contentsOf: batch)
        }
        return (sizes, rows)
    }

    @Test("A long read crosses the stream once per batch, not once per row")
    func longReadSendsOneElementPerBatch() {
        let result = Self.drive(OracleRowBatcher(rowsPerBatch: OracleRowBatcher.batchRows), rows: 12_001)

        #expect(result.sizes == [1, 5_000, 5_000, 2_000])
        #expect(result.rows == (0..<12_001).map(Self.row))
    }

    @Test("The first row goes out before a batch fills, so the reader can time it")
    func firstRowIsSentAlone() {
        var batcher = OracleRowBatcher(rowsPerBatch: OracleRowBatcher.batchRows)
        let first = batcher.append(Self.row(0))
        let second = batcher.append(Self.row(1))

        #expect(first == [Self.row(0)])
        #expect(second == nil)
    }

    @Test("A capped read gets the batch holding its last row as soon as that row is read")
    func cappedReadIsFlushedAtTheBudget() {
        var batcher = OracleRowBatcher(rowsPerBatch: OracleRowBatcher.batchRows, rowBudget: 1_001)
        var sent = 0
        for index in 0..<1_000 {
            if let batch = batcher.append(Self.row(index)) { sent += batch.count }
        }

        let batch = batcher.append(Self.row(1_000))

        #expect(sent == 1)
        #expect(batch?.count == 1_000)
        #expect(batch?.last == Self.row(1_000))
    }

    @Test("A cap past one batch ends its last batch on the cap")
    func budgetPastOneBatchEndsOnTheCap() {
        let result = Self.drive(
            OracleRowBatcher(rowsPerBatch: OracleRowBatcher.batchRows, rowBudget: 7_001),
            rows: 7_001
        )

        #expect(result.sizes == [1, 5_000, 2_000])
    }

    @Test("Rows read past the cap go back to full batches")
    func rowsPastTheBudgetBatchNormally() {
        let result = Self.drive(OracleRowBatcher(rowsPerBatch: 10, rowBudget: 3), rows: 25)

        #expect(result.sizes == [1, 2, 10, 10, 2])
        #expect(result.rows == (0..<25).map(Self.row))
    }

    @Test("A batch of one sends every row as it is read")
    func singleRowBatchesSendEveryRow() {
        let result = Self.drive(OracleRowBatcher(rowsPerBatch: 1), rows: 4)

        #expect(result.sizes == [1, 1, 1, 1])
    }

    @Test("An empty result sends no row batch")
    func emptyResultSendsNothing() {
        var batcher = OracleRowBatcher(rowsPerBatch: OracleRowBatcher.batchRows, rowBudget: 101)
        let rest = batcher.remainder()

        #expect(rest == nil)
    }
}
