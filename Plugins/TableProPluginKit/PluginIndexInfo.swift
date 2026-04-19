import Foundation

public struct PluginIndexInfo: Codable, Sendable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    public let type: String
    public let columnPrefixes: [String: Int]?
    public let whereClause: String?

    public init(
        name: String,
        columns: [String],
        isUnique: Bool = false,
        isPrimary: Bool = false,
        type: String = "BTREE",
        columnPrefixes: [String: Int]? = nil,
        whereClause: String? = nil
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.type = type
        self.columnPrefixes = columnPrefixes
        self.whereClause = whereClause
    }
}
