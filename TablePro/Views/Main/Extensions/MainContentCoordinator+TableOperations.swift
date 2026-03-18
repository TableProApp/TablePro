//
//  MainContentCoordinator+TableOperations.swift
//  TablePro
//
//  SQL generation for table truncate, drop, and FK handling operations.
//

import Foundation

extension MainContentCoordinator {
    // MARK: - Plugin Adapter Access

    /// Returns the current connection's PluginDriverAdapter, if available.
    private var currentPluginDriverAdapter: PluginDriverAdapter? {
        DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter
    }

    // MARK: - Table Operation SQL Generation

    /// Generates SQL statements for table truncate/drop operations.
    /// - Parameters:
    ///   - truncates: Set of table names to truncate
    ///   - deletes: Set of table names to drop
    ///   - options: Per-table options for FK and cascade handling
    ///   - includeFKHandling: Whether to include FK disable/enable statements (set false when caller handles FK)
    /// - Returns: Array of SQL statements to execute
    func generateTableOperationSQL(
        truncates: Set<String>,
        deletes: Set<String>,
        options: [String: TableOperationOptions],
        includeFKHandling: Bool = true
    ) -> [String] {
        var statements: [String] = []
        let dbType = connection.type

        // Sort tables for consistent execution order
        let sortedTruncates = truncates.sorted()
        let sortedDeletes = deletes.sorted()

        let needsDisableFK = includeFKHandling && truncates.union(deletes).contains { tableName in
            options[tableName]?.ignoreForeignKeys == true
        }

        // FK disable must be OUTSIDE transaction to ensure it takes effect even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkDisableStatements(for: dbType))
        }

        for tableName in sortedTruncates {
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(contentsOf: truncateStatements(
                tableName: tableName, options: tableOptions
            ))
        }

        let viewNames: Set<String> = {
            guard let session = DatabaseManager.shared.session(for: connectionId) else { return [] }
            return Set(session.tables.filter { $0.type == .view }.map(\.name))
        }()

        for tableName in sortedDeletes {
            let tableOptions = options[tableName] ?? TableOperationOptions()
            let stmt = dropTableStatement(
                tableName: tableName,
                isView: viewNames.contains(tableName), options: tableOptions
            )
            if !stmt.isEmpty {
                statements.append(stmt)
            }
        }

        // FK re-enable must be OUTSIDE transaction to ensure it runs even on rollback
        if needsDisableFK {
            statements.append(contentsOf: fkEnableStatements(for: dbType))
        }

        return statements
    }

    // MARK: - Foreign Key Handling

    func fkDisableStatements(for dbType: DatabaseType) -> [String] {
        guard let adapter = currentPluginDriverAdapter,
              let stmts = adapter.foreignKeyDisableStatements() else {
            return []
        }
        return stmts
    }

    func fkEnableStatements(for dbType: DatabaseType) -> [String] {
        guard let adapter = currentPluginDriverAdapter,
              let stmts = adapter.foreignKeyEnableStatements() else {
            return []
        }
        return stmts
    }

    // MARK: - Private SQL Builders

    private func truncateStatements(
        tableName: String, options: TableOperationOptions
    ) -> [String] {
        guard let adapter = currentPluginDriverAdapter else { return [] }
        return adapter.truncateTableStatements(
            table: tableName, schema: nil, cascade: options.cascade
        )
    }

    private func dropTableStatement(
        tableName: String, isView: Bool, options: TableOperationOptions
    ) -> String {
        let keyword = isView ? "VIEW" : "TABLE"
        guard let adapter = currentPluginDriverAdapter else { return "" }
        return adapter.dropObjectStatement(
            name: tableName, objectType: keyword, schema: nil, cascade: options.cascade
        )
    }
}
