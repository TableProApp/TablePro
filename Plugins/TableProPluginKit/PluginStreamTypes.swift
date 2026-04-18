import Foundation

public typealias PluginRow = [String?]

public struct PluginStreamHeader: Sendable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let estimatedRowCount: Int?

    public init(columns: [String], columnTypeNames: [String], estimatedRowCount: Int? = nil) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.estimatedRowCount = estimatedRowCount
    }
}

public enum PluginStreamElement: Sendable {
    case header(PluginStreamHeader)
    case rows([PluginRow])
}
