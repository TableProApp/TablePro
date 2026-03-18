import Foundation

public struct PluginTableMetadata: Codable, Sendable {
    public let tableName: String
    public let dataSize: Int64?
    public let indexSize: Int64?
    public let totalSize: Int64?
    public let rowCount: Int64?
    public let comment: String?
    public let engine: String?

    public init(
        tableName: String,
        dataSize: Int64? = nil,
        indexSize: Int64? = nil,
        totalSize: Int64? = nil,
        rowCount: Int64? = nil,
        comment: String? = nil,
        engine: String? = nil
    ) {
        self.tableName = tableName
        self.dataSize = dataSize
        self.indexSize = indexSize
        self.totalSize = totalSize
        self.rowCount = rowCount
        self.comment = comment
        self.engine = engine
    }
}
