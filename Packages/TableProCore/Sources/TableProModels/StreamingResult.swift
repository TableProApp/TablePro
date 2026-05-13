import Foundation

public enum StreamElement: Sendable {
    case columns([ColumnInfo])
    case row(Row)
    case rowsAffected(Int)
    case statusMessage(String)
    case truncated(reason: TruncationReason)
}

public enum TruncationReason: Sendable {
    case rowCap(Int)
    case memoryPressure
    case cancelled
    case driverLimit(String)
}

public struct StreamOptions: Sendable {
    public let textTruncationBytes: Int
    public let inlineBinary: Bool
    public let maxRows: Int
    public let lazyContext: LazyContext?

    public init(
        textTruncationBytes: Int = 4_096,
        inlineBinary: Bool = false,
        maxRows: Int = 100_000,
        lazyContext: LazyContext? = nil
    ) {
        self.textTruncationBytes = textTruncationBytes
        self.inlineBinary = inlineBinary
        self.maxRows = maxRows
        self.lazyContext = lazyContext
    }

    public static let `default` = StreamOptions()
}

public struct LazyContext: Sendable {
    public let table: String
    public let primaryKeyColumns: [String]

    public init(table: String, primaryKeyColumns: [String]) {
        self.table = table
        self.primaryKeyColumns = primaryKeyColumns
    }
}
