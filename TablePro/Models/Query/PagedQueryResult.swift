import Foundation

struct PagedQueryResult {
    let columns: [String]
    let columnTypes: [ColumnType]
    let rows: [[String?]]
    let executionTime: TimeInterval
    let hasMore: Bool
    let nextOffset: Int
}
