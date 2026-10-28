//
//  TableStructureLoader.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Reads a table's structure against the scope its tab is bound to.
///
/// The tab outlives the sidebar's selection, so the database and schema come from the
/// tab and are fixed for the life of the loader. Resolving them from the session instead
/// is what made a structure tab report that its own table does not exist once the
/// sidebar moved to another database.
@MainActor
struct TableStructureLoader {
    let scope: DatabaseScope
    let tableName: String
    private let provider: any ScopedMetadataProviding

    init(
        scope: DatabaseScope,
        tableName: String,
        provider: any ScopedMetadataProviding = DatabaseManager.shared
    ) {
        self.scope = scope
        self.tableName = tableName
        self.provider = provider
    }

    struct CoreTabs: Sendable {
        let columns: [ColumnInfo]
        let indexes: [IndexInfo]
        let foreignKeys: [ForeignKeyInfo]
        /// Nil when the comment was not asked for.
        let tableComment: MetadataFetchOutcome<String?>?
        /// Nil when the options were not asked for.
        let tableOptions: MetadataFetchOutcome<TableOptions?>?
    }

    func columns() async throws -> [ColumnInfo] {
        let table = tableName
        let schema = scope.schema
        return try await perform { try await $0.fetchColumns(table: table, schema: schema) }
    }

    func indexes() async throws -> [IndexInfo] {
        let table = tableName
        let schema = scope.schema
        return try await perform { try await $0.fetchIndexes(table: table, schema: schema) }
    }

    func foreignKeys() async throws -> [ForeignKeyInfo] {
        let table = tableName
        let schema = scope.schema
        return try await perform { try await $0.fetchForeignKeys(table: table, schema: schema) }
    }

    func checkConstraints() async throws -> [CheckConstraintInfo] {
        let table = tableName
        let schema = scope.schema
        return try await perform { try await $0.fetchCheckConstraints(table: table, schema: schema) }
    }

    func triggers() async throws -> [TriggerInfo] {
        let table = tableName
        let schema = scope.schema
        return try await perform { try await $0.fetchTriggers(table: table, schema: schema) }
    }

    func tableComment() async throws -> String? {
        let table = tableName
        return try await perform { try await $0.fetchObjectComment(tableName: table) }
    }

    func tableOptions() async throws -> TableOptions? {
        let table = tableName
        return try await perform { try await $0.fetchTableOptions(tableName: table) }
    }

    func tableOptionsCatalog() async throws -> TableOptionsCatalog? {
        try await perform { try await $0.fetchTableOptionsCatalog() }
    }

    /// What a new table in this scope's schema takes when it names no character set.
    func defaultTableOptions() async throws -> TableOptions? {
        let schema = scope.schema
        return try await perform { try await $0.fetchDefaultTableOptions(schema: schema) }
    }

    func concurrentRefreshAvailability() async throws -> PluginConcurrentRefreshAvailability? {
        try await MaterializedViewRefreshing.concurrentRefreshAvailability(
            of: DatabaseObjectTarget(name: tableName, type: .materializedView, schema: scope.schema, scope: scope),
            provider: provider
        )
    }

    /// A comment or options read that fails is reported in the result, so the columns still land.
    func coreTabs(
        includingForeignKeys: Bool,
        includingTableComment: Bool,
        includingTableOptions: Bool = false
    ) async throws -> CoreTabs {
        let table = tableName
        let schema = scope.schema
        return try await perform { driver in
            let columns = try await driver.fetchColumns(table: table, schema: schema)
            let indexes = try await driver.fetchIndexes(table: table, schema: schema)
            let foreignKeys = includingForeignKeys ? try await driver.fetchForeignKeys(table: table, schema: schema) : []
            let comment: MetadataFetchOutcome<String?>? = includingTableComment
                ? await Self.outcome { try await driver.fetchObjectComment(tableName: table) }
                : nil
            let options: MetadataFetchOutcome<TableOptions?>? = includingTableOptions
                ? await Self.outcome { try await driver.fetchTableOptions(tableName: table) }
                : nil
            return CoreTabs(
                columns: columns, indexes: indexes, foreignKeys: foreignKeys, tableComment: comment, tableOptions: options
            )
        }
    }

    nonisolated private static func outcome<Value: Sendable>(
        of read: () async throws -> Value
    ) async -> MetadataFetchOutcome<Value> {
        do {
            return .fetched(try await read())
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func perform<T: Sendable>(
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await provider.withMetadataDriver(scope: scope, workload: .interactive, body)
    }
}
