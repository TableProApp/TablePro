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
}

public extension PluginExportDataSource {
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] { [] }
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] { [] }
    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] { [] }
    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] { [:] }
    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] { [:] }
}
