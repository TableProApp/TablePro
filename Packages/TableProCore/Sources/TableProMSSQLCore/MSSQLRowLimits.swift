import Foundation

public enum MSSQLRowLimits {
    /// Rows one request may keep across all of its result sets.
    public static let emergencyMax = 5_000_000
    public static let streamBatchSize = 5_000

    /// Result sets one batch keeps. A loop that selects on every pass can return thousands, and past this many the
    /// rest are read and dropped rather than each becoming a grid.
    public static let batchResultSetLimit = 100
}
