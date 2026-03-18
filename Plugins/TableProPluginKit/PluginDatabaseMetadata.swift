import Foundation

public struct PluginDatabaseMetadata: Codable, Sendable {
    public let name: String
    public let tableCount: Int?
    public let sizeBytes: Int64?
    public let isSystemDatabase: Bool

    public init(
        name: String,
        tableCount: Int? = nil,
        sizeBytes: Int64? = nil,
        isSystemDatabase: Bool = false
    ) {
        self.name = name
        self.tableCount = tableCount
        self.sizeBytes = sizeBytes
        self.isSystemDatabase = isSystemDatabase
    }
}
