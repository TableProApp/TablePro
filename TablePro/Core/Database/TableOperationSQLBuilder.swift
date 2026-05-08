//
//  TableOperationSQLBuilder.swift
//  TablePro
//

import Foundation

@MainActor
struct TableOperationSQLBuilder {
    let connectionId: UUID
    let databaseType: DatabaseType
    let viewNamesProvider: () -> Set<String>
    let adapterProvider: () -> PluginDriverAdapter?

    init(
        connectionId: UUID,
        databaseType: DatabaseType,
        viewNamesProvider: @escaping () -> Set<String>,
        adapterProvider: @escaping () -> PluginDriverAdapter?
    ) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.viewNamesProvider = viewNamesProvider
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

        for tableName in sortedTruncates {
            let tableOptions = options[tableName] ?? TableOperationOptions()
            statements.append(contentsOf: truncateStatements(
                tableName: tableName, options: tableOptions
            ))
        }

        let viewNames = viewNamesProvider()

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
        tableName: String, options: TableOperationOptions
    ) -> [String] {
        guard let adapter = adapterProvider() else { return [] }
        return adapter.truncateTableStatements(
            table: tableName, schema: nil, cascade: options.cascade
        )
    }

    private func dropTableStatement(
        tableName: String, isView: Bool, options: TableOperationOptions
    ) -> String {
        let keyword = isView ? "VIEW" : "TABLE"
        guard let adapter = adapterProvider() else { return "" }
        return adapter.dropObjectStatement(
            name: tableName, objectType: keyword, schema: nil, cascade: options.cascade
        )
    }
}
