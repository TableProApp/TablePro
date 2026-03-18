import Foundation

public struct PluginForeignKeyInfo: Codable, Sendable {
    public let name: String
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String
    public let onDelete: String
    public let onUpdate: String

    public init(
        name: String,
        column: String,
        referencedTable: String,
        referencedColumn: String,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}
