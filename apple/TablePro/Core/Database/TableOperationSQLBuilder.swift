//
//  TableOperationSQLBuilder.swift
//  TablePro
//

import Foundation

@MainActor
struct TableOperationSQLBuilder {
    let driverProvider: () -> DatabaseDriver?

    init(driverProvider: @escaping () -> DatabaseDriver?) {
        self.driverProvider = driverProvider
    }

    /// Every statement is built from the queued reference alone.
    ///
    /// Throws rather than skipping a ref the engine has no statement for. The menus already keep
    /// one off the queue, but a driver answers from live session state, so a queued Redis truncate
    /// can stop being expressible between staging and Save. Dropping it silently would run the
    /// rest of the plan and report every staged object as done, including the one nothing touched.
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
    ) throws -> [String] {
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
            guard let staged = truncateStatements(ref, options: options[ref] ?? TableOperationOptions()) else {
                throw DataWriteError.objectOperationUnsupported(ref.table.name)
            }
            statements.append(contentsOf: staged)
        }

        for ref in sortedDeletes {
            guard let stmt = dropObjectStatement(ref, options: options[ref] ?? TableOperationOptions()) else {
                throw DataWriteError.objectOperationUnsupported(ref.table.name)
            }
            guard !stmt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            statements.append(stmt)
        }

        if needsDisableFK {
            statements.append(contentsOf: foreignKeyEnableStatements())
        }

        return statements
    }

    func foreignKeyDisableStatements() -> [String] {
        driverProvider()?.foreignKeyDisableStatements() ?? []
    }

    func foreignKeyEnableStatements() -> [String] {
        driverProvider()?.foreignKeyEnableStatements() ?? []
    }

    private func truncateStatements(
        _ ref: DatabaseTreeTableRef, options: TableOperationOptions
    ) -> [String]? {
        guard let driver = driverProvider() else { return nil }
        return driver.truncateTableStatements(
            table: ref.table.name, schema: ref.qualifyingSchema, cascade: options.cascade
        )
    }

    private func dropObjectStatement(
        _ ref: DatabaseTreeTableRef, options: TableOperationOptions
    ) -> String? {
        guard let driver = driverProvider() else { return nil }
        return driver.dropObjectStatement(
            name: ref.table.name,
            objectType: TableObjectKeyword.forDDL(ref.table.type),
            schema: ref.qualifyingSchema,
            cascade: options.cascade
        )
    }
}
