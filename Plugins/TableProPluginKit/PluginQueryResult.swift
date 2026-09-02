import Foundation

public struct PluginQueryResult: Codable, Sendable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let rows: [[PluginCellValue]]
    public let rowsAffected: Int
    public let executionTime: TimeInterval
    public let isTruncated: Bool
    public let statusMessage: String?
    public let columnMeta: [PluginColumnInfo]?
    public let timing: PluginQueryTiming

    public init(
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
        rowsAffected: Int,
        timing: PluginQueryTiming,
        isTruncated: Bool = false,
        statusMessage: String? = nil,
        columnMeta: [PluginColumnInfo]? = nil
    ) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.rows = rows
        self.rowsAffected = rowsAffected
        self.executionTime = timing.total
        self.isTruncated = isTruncated
        self.statusMessage = statusMessage
        self.columnMeta = columnMeta
        self.timing = timing
    }

    /// Kept at its exact published signature. Adding `timing:` to it would replace its mangled
    /// symbol and every already-built plugin would fail to load, which is what shipping a defaulted
    /// `columnMeta:` parameter on this initializer did in 0.49.0.
    @_disfavoredOverload
    public init(
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
        rowsAffected: Int,
        executionTime: TimeInterval,
        isTruncated: Bool = false,
        statusMessage: String? = nil,
        columnMeta: [PluginColumnInfo]? = nil
    ) {
        self.init(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            timing: PluginQueryTiming(total: executionTime),
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: columnMeta
        )
    }

    @_disfavoredOverload
    public init(
        columns: [String],
        columnTypeNames: [String],
        rows: [[PluginCellValue]],
        rowsAffected: Int,
        executionTime: TimeInterval,
        isTruncated: Bool,
        statusMessage: String?
    ) {
        self.init(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            timing: PluginQueryTiming(total: executionTime),
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: nil
        )
    }

    /// A result decoded from a release that predates the split carries only the elapsed number, so
    /// the timing is rebuilt from it rather than failing to decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decode([String].self, forKey: .columns)
        columnTypeNames = try container.decode([String].self, forKey: .columnTypeNames)
        rows = try container.decode([[PluginCellValue]].self, forKey: .rows)
        rowsAffected = try container.decode(Int.self, forKey: .rowsAffected)
        executionTime = try container.decode(TimeInterval.self, forKey: .executionTime)
        isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
        columnMeta = try container.decodeIfPresent([PluginColumnInfo].self, forKey: .columnMeta)
        timing = try container.decodeIfPresent(PluginQueryTiming.self, forKey: .timing)
            ?? PluginQueryTiming(total: executionTime)
    }

    public static let empty = PluginQueryResult(
        columns: [],
        columnTypeNames: [],
        rows: [],
        rowsAffected: 0,
        timing: PluginQueryTiming(total: 0)
    )
}
