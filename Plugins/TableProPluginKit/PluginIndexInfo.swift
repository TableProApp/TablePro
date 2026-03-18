import Foundation

public struct PluginIndexInfo: Codable, Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE"
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
    }
}
