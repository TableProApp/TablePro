import Foundation

public protocol PluginExportDataSource: AnyObject, Sendable {
    var databaseTypeId: String { get }
    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error>
    func fetchTableDDL(table: String, databaseName: String) async throws -> String
    func execute(query: String) async throws -> PluginQueryResult
    func quoteIdentifier(_ identifier: String) -> String
    func escapeStringLiteral(_ value: String) -> String
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int?
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo]
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo]
    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo]
    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]]
    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo]
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]]
    var tableDDLIncludesForeignKeys: Bool { get }

    /// The CREATE statement for any exportable object, routines, triggers, views and user types
    /// included. One method rather than one per kind, because the caller already knows the kind and
    /// every driver answers the same question: what would recreate this.
    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String

    /// The GRANT statements that recreate one principal's privileges, rendered by the engine's own
    /// grant builder. `host` is the MySQL-style host part, which is what separates two principals
    /// that share a name. Empty on an engine with no principal management.
    func fetchGrantStatements(principal: String, host: String?) async throws -> [String]

    /// The engine's own DROP for an object. Only the driver knows that PostgreSQL's `DROP TRIGGER`
    /// takes an `ON <table>` clause and MySQL's does not, or that MySQL has no `DROP ROUTINE` at
    /// all. Nil means the caller should fall back to its own generic shape.
    func dropStatement(for object: PluginExportTable) -> String?

    /// The object's rows, narrowed to its `rowScope`. Reading the whole object is what the default
    /// does, so a format that has not adopted row scope keeps behaving as it did.
    func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error>
}

public extension PluginExportDataSource {
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] { [] }
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] { [] }
    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] { [] }
    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] { [:] }
    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] { [:] }

    /// Mirrors `PluginDatabaseDriver.tableDDLIncludesForeignKeys` for the export side: `true` means
    /// `fetchTableDDL` already declares them, so a format that defers foreign keys must not add
    /// them a second time.
    var tableDDLIncludesForeignKeys: Bool { false }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
    }

    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] { [] }

    func dropStatement(for object: PluginExportTable) -> String? { nil }

    func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
        streamRows(table: object.name, databaseName: object.databaseName)
    }
}
