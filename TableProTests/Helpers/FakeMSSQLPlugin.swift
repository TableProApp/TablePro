//
//  FakeMSSQLPlugin.swift
//  TableProTests
//
//  Minimal MSSQL driver stub registered with PluginManager so tests that
//  resolve the SQL Server plugin (queryBuildingDriver, sqlDialect lookups)
//  succeed without bundling the real MSSQLDriverPlugin.
//

import Foundation
import TableProPluginKit
@testable import TablePro

final class FakeMSSQLPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Fake MSSQL Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Test stub for MSSQL plugin lookups"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQL Server"
    static let databaseDisplayName = "SQL Server"
    static let iconName = "mssql-icon"
    static let defaultPort = 1_433
    static let isDownloadable = true
    static let parameterStyle: ParameterStyle = .questionMark
    static let supportsSchemaSwitching = true
    static let defaultSchemaName = "dbo"

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "[",
        keywords: [],
        functions: [],
        dataTypes: [],
        regexSyntax: .unsupported,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .explicit,
        paginationStyle: .offsetFetch,
        autoLimitStyle: .top
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        FakeMSSQLPluginDriver()
    }

    required override init() {
        super.init()
    }
}

final class FakeMSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { true }
    var currentSchema: String? { "dbo" }
    var parameterStyle: ParameterStyle { .questionMark }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "]", with: "]]")
        return "[\(escaped)]"
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let quotedTable = quoteIdentifier(table)
        let orderBy = orderByClause(sortColumns: sortColumns, columns: columns) ?? "ORDER BY (SELECT NULL)"
        return "SELECT * FROM \(quotedTable) \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let quotedTable = quoteIdentifier(table)
        var query = "SELECT * FROM \(quotedTable)"
        let whereClause = whereClause(filters: filters, logicMode: logicMode)
        if !whereClause.isEmpty {
            query += " WHERE \(whereClause)"
        }
        let orderBy = orderByClause(sortColumns: sortColumns, columns: columns) ?? "ORDER BY (SELECT NULL)"
        query += " \(orderBy) OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
        return query
    }

    private func orderByClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> String? {
        let parts = sortColumns.compactMap { sortCol -> String? in
            guard sortCol.columnIndex >= 0, sortCol.columnIndex < columns.count else { return nil }
            let direction = sortCol.ascending ? "ASC" : "DESC"
            return "\(quoteIdentifier(columns[sortCol.columnIndex])) \(direction)"
        }
        guard !parts.isEmpty else { return nil }
        return "ORDER BY " + parts.joined(separator: ", ")
    }

    private func whereClause(
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) -> String {
        let connector = logicMode.lowercased() == "or" ? " OR " : " AND "
        let parts = filters.map { filter in
            "\(quoteIdentifier(filter.column)) \(filter.op) '\(filter.value)'"
        }
        return parts.joined(separator: connector)
    }
}

enum FakeMSSQLPluginRegistration {
    private static var didRegister = false
    private static let lock = NSLock()

    @MainActor
    static func registerIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRegister else { return }
        let manager = PluginManager.shared
        if manager.driverPlugins[FakeMSSQLPlugin.databaseTypeId] != nil {
            didRegister = true
            return
        }
        let instance = FakeMSSQLPlugin()
        manager.driverPlugins[FakeMSSQLPlugin.databaseTypeId] = instance
        didRegister = true
    }
}
