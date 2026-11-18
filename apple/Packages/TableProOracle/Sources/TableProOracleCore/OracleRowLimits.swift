import Foundation
import OracleNIO

public enum OracleRowLimits {
    public static let emergencyMax = 5_000_000

    // Rows per fetch for every read: at the driver's default of 50 a row, 10,000 rows took 201 round trips.
    static let fetchBatchRows = 1_000

    // What the first response may carry, so a large capped read still answers Stop and the query deadline.
    static let maximumPrefetchRows = 10_000

    // The first response asks for one row past the rows wanted, because a response that ends exactly on the last
    // row wanted cannot report the end of the result and costs another round trip. `rowBudget` already counts that
    // row: a capped reader stops at it.
    static func fetching(_ options: StatementOptions, rowBudget: Int? = nil) -> StatementOptions {
        var options = options
        options.prefetchRows = min(rowBudget ?? (fetchBatchRows + 1), maximumPrefetchRows)
        options.arraySize = fetchBatchRows
        return options
    }
}
