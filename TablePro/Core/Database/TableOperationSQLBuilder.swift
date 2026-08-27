//
//  TableOperationSQLBuilder.swift
//  TablePro
//

import Foundation

@MainActor
struct TableOperationSQLBuilder {
    let adapterProvider: () -> PluginDriverAdapter?

    init(adapterProvider: @escaping () -> PluginDriverAdapter?) {
        self.adapterProvider = adapterProvider
    }

    /// Every statement is built from the queued reference alone.
    ///
    /// The schema and the object's keyword used to be looked up in the connection's flat table
    /// cache, which publishes nothing at all on an engine whose tree is per-schema: on Oracle,
    /// Dameng, Trino, Snowflake and BigQuery every drop came out unqualified and typed `TABLE`,
    /// so dropping a view raised ORA-00942 and dropping a table reached whatever object of that
    /// name the login schema happened to hold.
    func generate(
        truncates: Set<DatabaseTreeTableRef>,
        deletes: Set<DatabaseTreeTableRef>,
        options: [DatabaseTreeTableRef: TableOperationOptions],
        includeFKHandling: Bool = true
    ) -> [String] {
        var statements: [String] = []
        let sortedTruncates = truncates.sorted { $0.id < $1.id }
        let sortedDeletes = deletes.sorted { $0.id < $1.id }

        let needsDisableFK = includeFKHandling && truncates.union(deletes).contains { ref in
            options[ref]?.ignoreForeignKeys == true
        }

        if needsDisableFK {
            statements.append(contentsOf: foreignKeyDisableStatements())
        }

        for ref in sortedTruncates {
            statements.append(contentsOf: truncateStatements(
                ref, options: options[ref] ?? TableOperationOptions()
            ))
        }

        for ref in sortedDeletes {
            let stmt = dropObjectStatement(ref, options: options[ref] ?? TableOperationOptions())
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
        _ ref: DatabaseTreeTableRef, options: TableOperationOptions
    ) -> [String] {
        guard let adapter = adapterProvider() else { return [] }
        return adapter.truncateTableStatements(
            table: ref.table.name, schema: ref.qualifyingSchema, cascade: options.cascade
        )
    }

    private func dropObjectStatement(
        _ ref: DatabaseTreeTableRef, options: TableOperationOptions
    ) -> String {
        guard let adapter = adapterProvider() else { return "" }
        return adapter.dropObjectStatement(
            name: ref.table.name,
            objectType: Self.dropKeyword(for: ref.table.type),
            schema: ref.qualifyingSchema,
            cascade: options.cascade
        )
    }

    private static func dropKeyword(for type: TableInfo.TableType) -> String {
        switch type {
        case .view:
            return "VIEW"
        case .materializedView:
            return "MATERIALIZED VIEW"
        case .foreignTable:
            return "FOREIGN TABLE"
        case .table, .systemTable, .partitionedTable, .externalTable:
            return "TABLE"
        }
    }
}
