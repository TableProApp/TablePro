import Foundation

public struct PluginPagedResult: Sendable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let rows: [[String?]]
    public let executionTime: TimeInterval
    public let hasMore: Bool
    public let nextOffset: Int

    public init(
        columns: [String],
        columnTypeNames: [String],
        rows: [[String?]],
        executionTime: TimeInterval,
        hasMore: Bool,
        nextOffset: Int
    ) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
        self.executionTime = executionTime
        self.hasMore = hasMore
        self.nextOffset = nextOffset
    }
}
