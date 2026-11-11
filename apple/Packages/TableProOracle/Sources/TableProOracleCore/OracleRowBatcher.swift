import Foundation

// Groups decoded rows into stream elements, so a long read pays its stream hops once per batch rather than once per row.
public struct OracleRowBatcher: Sendable {
    public static let batchRows = 5_000

    private let rowsPerBatch: Int
    // The rows a capped reader takes before it stops. The batch that completes them goes out at once, so the reader
    // never waits on rows past its cap.
    private let rowBudget: Int?
    private var delivered = 0
    private var pending: [[OracleRawCell]] = []

    public init(rowsPerBatch: Int, rowBudget: Int? = nil) {
        self.rowsPerBatch = max(1, rowsPerBatch)
        self.rowBudget = rowBudget.map { max(1, $0) }
    }

    public mutating func append(_ row: [OracleRawCell]) -> [[OracleRawCell]]? {
        if pending.isEmpty, delivered > 0 { pending.reserveCapacity(nextBatchCapacity) }
        pending.append(row)
        // The first row goes out alone, since a reader times it as the moment the server began to answer.
        let isFirstRow = delivered == 0
        guard isFirstRow || pending.count >= rowsPerBatch || rowBudget == delivered + pending.count else { return nil }
        return take()
    }

    public mutating func remainder() -> [[OracleRawCell]]? {
        pending.isEmpty ? nil : take()
    }

    private var nextBatchCapacity: Int {
        guard let rowBudget, rowBudget > delivered else { return rowsPerBatch }
        return min(rowsPerBatch, rowBudget - delivered)
    }

    private mutating func take() -> [[OracleRawCell]] {
        let batch = pending
        delivered += batch.count
        pending = []
        return batch
    }
}
