import Foundation

public struct PluginForeignKeyInfo: Codable, Sendable {
    public let name: String
    public let column: String
    public let referencedTable: String
    public let referencedColumn: String
    /// The database the referenced table lives in, when the engine names objects in three parts and
    /// the key points outside the one it was read from. Nil everywhere else, including on an engine
    /// with no schema layer, which names its referenced database in `referencedSchema` because that
    /// is the column its catalog puts it in.
    public let referencedDatabase: String?
    public let referencedSchema: String?
    public let onDelete: String
    public let onUpdate: String

    public init(
        name: String,
        column: String,
        referencedTable: String,
        referencedColumn: String,
        referencedDatabase: String?,
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.name = name
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.referencedDatabase = referencedDatabase
        self.referencedSchema = referencedSchema
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }

    /// The signature every already-built plugin links against, kept byte for byte.
    ///
    /// Adding a parameter to a published initializer replaces its mangled symbol and every plugin
    /// compiled against the old one fails to load; 0.49.0 shipped exactly that when
    /// `PluginQueryResult` gained `columnMeta:`. So the new field arrives on a second initializer
    /// and this one stays, marked `@_disfavoredOverload` so new code resolves to the full one.
    @_disfavoredOverload
    public init(
        name: String,
        column: String,
        referencedTable: String,
        referencedColumn: String,
        referencedSchema: String? = nil,
        onDelete: String = "NO ACTION",
        onUpdate: String = "NO ACTION"
    ) {
        self.init(
            name: name,
            column: column,
            referencedTable: referencedTable,
            referencedColumn: referencedColumn,
            referencedDatabase: nil,
            referencedSchema: referencedSchema,
            onDelete: onDelete,
            onUpdate: onUpdate
        )
    }
}
