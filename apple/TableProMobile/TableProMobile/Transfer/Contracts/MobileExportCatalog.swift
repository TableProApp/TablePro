import Foundation
import TableProPluginKit

// One engine's answers to everything an export asks besides the rows. The names and defaults are the
// `PluginExportDataSource` ones, so `MobileExportDataSource` forwards each call unchanged.
nonisolated protocol MobileExportCatalog: Sendable {
    var databaseTypeId: String { get }

    // Every object the engine's macOS export lists for this database and schema, tables included, each kind
    // filled the way macOS fills it (a routine's `tableType` is its `PluginRoutineKind.rawValue`).
    func exportObjects(database: String, schema: String?) async throws -> [PluginExportTable]

    // The SELECT that reads an object's rows, or nil to let the host write `SELECT * FROM <qualified name>`.
    func rowsQuery(for object: PluginExportTable) -> String?

    // An engine whose rows are not SQL rows (MongoDB documents) streams them itself; nil uses the driver's
    // `ExportRowStreaming`.
    func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error>?

    func quoteIdentifier(_ identifier: String) -> String
    func escapeStringLiteral(_ value: String) -> String
    func fetchTableDDL(table: String, databaseName: String) async throws -> String
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int?
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo]
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo]
    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo]
    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]]
    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo]
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]]
    var tableDDLIncludesForeignKeys: Bool { get }
    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String]
    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String]
    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String
    func scriptText(for ddl: String) -> String
    var lexicalFeatures: SQLLexicalFeatures { get }
    func fetchGrantStatements(principal: String, host: String?) async throws -> [String]
    var supportsCascadeDrop: Bool { get }
    func dropStatement(for object: PluginExportTable) -> String?
    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope?
    func closeSessionScope(_ scope: PluginSessionScope) async throws
    func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope?
    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo]
    func fetchObjectComment(_ object: PluginExportTable) async throws -> String?
}

nonisolated extension MobileExportCatalog {
    func rowsQuery(for object: PluginExportTable) -> String? { nil }
    func streamExportRows(for object: PluginExportTable)
        -> AsyncThrowingStream<PluginExportStreamElement, Error>? { nil }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] { [] }
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] { [] }
    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] { [] }
    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] { [:] }
    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] { [:] }
    var tableDDLIncludesForeignKeys: Bool { false }
    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] { [] }
    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] { [] }
    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        try await fetchTableDDL(table: object.name, databaseName: object.databaseName)
    }
    func scriptText(for ddl: String) -> String {
        ddl.hasSuffix(";") ? ddl : ddl + ";"
    }
    var lexicalFeatures: SQLLexicalFeatures { [] }
    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] { [] }
    var supportsCascadeDrop: Bool { false }
    func dropStatement(for object: PluginExportTable) -> String? { nil }
    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? { nil }
    func closeSessionScope(_ scope: PluginSessionScope) async throws {}
    func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope? { nil }
    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] { [] }
    func fetchObjectComment(_ object: PluginExportTable) async throws -> String? { nil }
}
