import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

// The iOS counterpart of macOS `ExportDataSourceAdapter`: the engine's catalog answers every question about an object,
// and the driver streams its rows.
nonisolated final class MobileExportDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String

    private let catalog: any MobileExportCatalog
    private let driver: any DatabaseDriver
    private let databaseType: DatabaseType
    private let readOnly: Bool
    private let skipsSnapshotStatements: Bool

    // `readOnly`: the connection runs at Read-Only. `skipsSnapshotStatements`: the rows are read on the session that
    // holds the user's transaction.
    init(
        catalog: any MobileExportCatalog,
        driver: any DatabaseDriver,
        databaseType: DatabaseType,
        readOnly: Bool,
        skipsSnapshotStatements: Bool = false
    ) {
        self.catalog = catalog
        self.driver = driver
        self.databaseType = databaseType
        self.readOnly = readOnly
        self.skipsSnapshotStatements = skipsSnapshotStatements
        self.databaseTypeId = catalog.databaseTypeId
    }

    // MARK: - Rows

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginExportStreamElement.cells(streamExportRows(table: table, databaseName: databaseName))
    }

    func streamRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginExportStreamElement.cells(streamExportRows(for: object))
    }

    func streamExportRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        streamExportRows(for: PluginExportTable(
            name: table, databaseName: databaseName, tableType: "table", schema: nil, kind: .table
        ))
    }

    func streamExportRows(for object: PluginExportTable) -> AsyncThrowingStream<PluginExportStreamElement, Error> {
        if object.rowScope.isUnrestricted, let documents = catalog.streamExportRows(for: object) {
            return documents
        }
        guard let rows = driver as? any ExportRowStreaming else {
            return MobileExportStreams.failing(DatabaseDriverCapabilityError.unsupported(.exportRows))
        }
        let query: String
        do {
            query = try rowsQuery(for: object)
        } catch {
            return MobileExportStreams.failing(error)
        }
        return PluginExportStreamElement.wrapping(rows.exportRows(query: query, readOnly: readOnly))
    }

    // The engine's own statement when it has one; otherwise every column of the object by its qualified name, narrowed
    // to the row scope the way the macOS adapter narrows it.
    func rowsQuery(for object: PluginExportTable) throws -> String {
        let scope = object.rowScope
        if scope.isUnrestricted, let custom = catalog.rowsQuery(for: object) {
            return custom
        }
        guard databaseType.speaksSQL else {
            throw PluginExportError.exportFailed(String(
                format: String(localized: "%@ cannot be narrowed to some rows or columns, because this database has no SQL."),
                object.name
            ))
        }
        let projection = scope.columns.isEmpty ? "*" : scope.columns.map { catalog.quoteIdentifier($0) }.joined(separator: ", ")
        var sql = "SELECT \(projection) FROM \(qualifiedName(of: object))"
        if !scope.sanitizedFilter.isEmpty {
            sql += " WHERE \(scope.sanitizedFilter)"
        }
        if let limit = scope.rowLimit {
            sql += " " + SQLBuilder.paginationClause(orderBy: "", limit: max(0, limit), offset: 0, for: databaseType)
        }
        return sql
    }

    // The container the catalog named the object in: its schema, or the database on an engine with no schema layer.
    func qualifiedName(of object: PluginExportTable) -> String {
        let container = [object.schema, object.databaseName].compactMap { $0 }.first { !$0.isEmpty }
        let name = catalog.quoteIdentifier(object.name)
        guard let container else { return name }
        return "\(catalog.quoteIdentifier(container)).\(name)"
    }

    // A statement that counts what `rowsQuery` reads, or nil where only the catalog can say.
    func rowCountQuery(for object: PluginExportTable) -> String? {
        guard databaseType.speaksSQL else { return nil }
        let scope = object.rowScope
        guard scope.isUnrestricted ? catalog.rowsQuery(for: object) == nil : scope.rowLimit == nil else { return nil }
        var sql = "SELECT COUNT(*) FROM \(qualifiedName(of: object))"
        if !scope.sanitizedFilter.isEmpty {
            sql += " WHERE \(scope.sanitizedFilter)"
        }
        return sql
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await MobileExportStreams.execute(
            query, on: driver, readOnly: readOnly, skipsTransactionStatements: skipsSnapshotStatements
        )
    }

    // MARK: - Catalog

    func quoteIdentifier(_ identifier: String) -> String {
        catalog.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        catalog.escapeStringLiteral(value)
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await catalog.fetchTableDDL(table: table, databaseName: databaseName)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? {
        try await catalog.fetchApproximateRowCount(table: table, databaseName: databaseName)
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        try await catalog.fetchDependentSequences(table: table, databaseName: databaseName)
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        try await catalog.fetchDependentTypes(table: table, databaseName: databaseName)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await catalog.fetchColumns(table: table, databaseName: databaseName)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await catalog.fetchAllColumns(databaseName: databaseName)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await catalog.fetchForeignKeys(table: table, databaseName: databaseName)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await catalog.fetchAllForeignKeys(databaseName: databaseName)
    }

    var tableDDLIncludesForeignKeys: Bool {
        catalog.tableDDLIncludesForeignKeys
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await catalog.fetchIndexDDL(table: table, databaseName: databaseName)
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        try await catalog.fetchCommentDDL(table: table, databaseName: databaseName)
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        try await catalog.fetchObjectDDL(object)
    }

    func scriptText(for ddl: String) -> String {
        catalog.scriptText(for: ddl)
    }

    var lexicalFeatures: SQLLexicalFeatures {
        catalog.lexicalFeatures
    }

    func fetchGrantStatements(principal: String, host: String?) async throws -> [String] {
        try await catalog.fetchGrantStatements(principal: principal, host: host)
    }

    var supportsCascadeDrop: Bool {
        catalog.supportsCascadeDrop
    }

    // No guess without the routine's kind: PostgreSQL refuses `DROP FUNCTION` on a procedure.
    func dropStatement(for object: PluginExportTable) -> String? {
        if object.kind == .routine, PluginRoutineKind(rawValue: object.tableType.lowercased()) == nil {
            return nil
        }
        return catalog.dropStatement(for: object)
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await catalog.openSessionScope(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await catalog.closeSessionScope(scope)
    }

    func fetchCreationScope(_ object: PluginExportTable) async throws -> PluginStatementScope? {
        try await catalog.fetchCreationScope(object)
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        try await catalog.fetchIndexes(table: table, databaseName: databaseName)
    }

    func fetchObjectComment(_ object: PluginExportTable) async throws -> String? {
        try await catalog.fetchObjectComment(object)
    }
}
