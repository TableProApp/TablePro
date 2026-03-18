import Foundation

public struct PluginTableInfo: Codable, Sendable {
    public let name: String
    public let type: String
    public let rowCount: Int?

    public init(name: String, type: String = "TABLE", rowCount: Int? = nil) {
        self.name = name
        self.type = type
        self.rowCount = rowCount
    }
}
