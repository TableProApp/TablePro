import Foundation

public struct BigtableFilterSpec: Codable, Sendable, Equatable {
    public let column: String
    public let op: String
    public let value: String
    public let secondValue: String?
    public let isCaseSensitive: Bool

    public init(column: String, op: String, value: String, secondValue: String? = nil, isCaseSensitive: Bool = true) {
        self.column = column
        self.op = op.uppercased()
        self.value = value
        self.secondValue = secondValue
        self.isCaseSensitive = isCaseSensitive
    }
}

/// A page of one table as the grid asked for it. Bigtable reads rows in key order and has no
/// offset, so a later page starts after the last key of the page before it.
public struct BigtableBrowseSpec: Codable, Sendable, Equatable {
    public let table: String
    public let filters: [BigtableFilterSpec]
    public let logicMode: String
    public let descending: Bool
    /// Kept so a sort Bigtable cannot do is refused rather than silently ignored.
    public let sortColumn: String?
    public let limit: Int
    public let offset: Int

    public init(
        table: String,
        filters: [BigtableFilterSpec] = [],
        logicMode: String = "AND",
        descending: Bool = false,
        sortColumn: String? = nil,
        limit: Int,
        offset: Int
    ) {
        self.table = table
        self.filters = filters
        self.logicMode = logicMode
        self.descending = descending
        self.sortColumn = sortColumn
        self.limit = limit
        self.offset = offset
    }

    public var usesOr: Bool {
        logicMode.uppercased() == "OR"
    }

    /// The spec without its page, so pages of the same view share one cursor cache.
    public var viewKey: String {
        let filterText = filters.map {
            [$0.column, $0.op, $0.value, $0.secondValue ?? "", $0.isCaseSensitive ? "cs" : "ci"].joined(separator: "\u{1}")
        }.joined(separator: "\u{2}")
        return [table, logicMode.uppercased(), descending ? "desc" : "asc", filterText].joined(separator: "\u{3}")
    }

    public static func viewKeyPrefix(table: String) -> String {
        table + "\u{3}"
    }
}
