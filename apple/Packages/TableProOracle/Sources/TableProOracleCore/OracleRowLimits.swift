import Foundation
import OracleNIO

public enum OracleRowLimits {
    public static let emergencyMax = 5_000_000

    // A read that keeps every row asks for them in large batches: at the driver's default of 100 a row,
    // the 50,000 tables of a catalog listing took a thousand round trips.
    static let collectedBatchRows = 1_000

    static func collecting(_ options: StatementOptions) -> StatementOptions {
        var options = options
        options.prefetchRows = collectedBatchRows
        options.arraySize = collectedBatchRows
        return options
    }
}
