//
//  TableOperationSQLBuilder.swift
//  TablePro
//

import Foundation
import os

@MainActor
struct TableOperationSQLBuilder {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TableOperationSQLBuilder")

    let connectionId: UUID
    let databaseType: DatabaseType
    let tableInfoProvider: () -> [String: TableInfo]
    let adapterProvider: () -> PluginDriverAdapter?

    init(
        connectionId: UUID,
        databaseType: DatabaseType,
        tableInfoProvider: @escaping () -> [String: TableInfo],
        adapterProvider: @escaping () -> PluginDriverAdapter?
    ) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.tableInfoProvider = tableInfoProvider
        self.adapterProvider = adapterProvider
    }

    func generate(
        truncates: Set<String>,
        deletes: Set<String>,
        options: [String: TableOperationOptions],
        includeFKHandling: Bool = true
    ) -> [String] {
        var statements: [String] = []
        let sortedTruncates = truncates.sorted()
        let sortedDeletes = deletes.sorted()

        let needsDisableFK = includeFKHandling && truncates.union(deletes).contains { tableName in
            options[tableName]?.ignoreForeignKeys == true
        }

        if needsDisableFK {
            statements.append(contentsOf: foreignKeyDisableStatements())
        }

        let tableLookup = tableInfoProvider()

        for tableName in sortedTruncates {
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(contentsOf: truncateStatements(
                tableName: tableName, schema: tableLookup[tableName]?.schema, options: tableOptions
            ))
        }

        for tableName in sortedDeletes {
            let tableOptions = options[tableName] ?? TableOperationOptions()
            let stmt = dropObjectStatement(
                tableName: tableName, tableInfo: tableLookup[tableName], options: tableOptions
            )
            if !stmt.isEmpty {
                statements.append(stmt)
            }
        }

        if needsDisableFK {
            statements.append(contentsOf: foreignKeyEnableStatements())
        }

        return statements
    }

    func foreignKeyDisableStatements() -> [String] {
        adapterProvider()?.foreignKeyDisableStatements() ?? []
    }

    func foreignKeyEnableStatements() -> [String] {
        adapterProvider()?.foreignKeyEnableStatements() ?? []
    }

    private func truncateStatements(
        tableName: String, schema: String?, options: TableOperationOptions
    ) -> [String] {
        guard let adapter = adapterProvider() else { return [] }
        return adapter.truncateTableStatements(
            table: tableName, schema: schema, cascade: options.cascade
        )
    }

    private func dropObjectStatement(
        tableName: String, tableInfo: TableInfo?, options: TableOperationOptions
    ) -> String {
        guard let adapter = adapterProvider() else { return "" }
        if tableInfo == nil {
            Self.logger.warning("No cached TableInfo for \(tableName, privacy: .public); dropping as TABLE")
        }
        return adapter.dropObjectStatement(
            name: tableName,
            objectType: Self.dropKeyword(for: tableInfo?.type),
            schema: tableInfo?.schema,
            cascade: options.cascade
        )
    }

    private static func dropKeyword(for type: TableInfo.TableType?) -> String {
        switch type {
        case .view:
            return "VIEW"
        case .materializedView:
            return "MATERIALIZED VIEW"
        case .foreignTable:
            return "FOREIGN TABLE"
        case .table, .systemTable, .none:
            return "TABLE"
        }
    }
}
