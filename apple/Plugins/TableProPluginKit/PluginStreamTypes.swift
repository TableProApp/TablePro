import Foundation

public typealias PluginRow = [PluginCellValue]

public struct PluginStreamHeader: Sendable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let estimatedRowCount: Int?
    // See `PluginQueryResult.columnOrigins`.
    public var columnOrigins: [PluginColumnOrigin?]?
    // The most rows the driver lets this statement return. A stream that ends at it was cut there; nil when nothing cuts it.
    public var rowLimit: Int?

    public init(columns: [String], columnTypeNames: [String], estimatedRowCount: Int? = nil) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.estimatedRowCount = estimatedRowCount
    }
}

@frozen
public enum PluginStreamElement: Sendable {
    case header(PluginStreamHeader)
    case rows([PluginRow])
}
