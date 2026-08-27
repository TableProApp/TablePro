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
    }

    func columns() async throws -> [ColumnInfo] {
        let table = tableName
        return try await perform { try await $0.fetchColumns(table: table) }
    }

    func indexes() async throws -> [IndexInfo] {
        let table = tableName
        return try await perform { try await $0.fetchIndexes(table: table) }
    }

    func foreignKeys() async throws -> [ForeignKeyInfo] {
        let table = tableName
        return try await perform { try await $0.fetchForeignKeys(table: table) }
    }

    func checkConstraints() async throws -> [CheckConstraintInfo] {
        let table = tableName
        return try await perform { try await $0.fetchCheckConstraints(table: table) }
    }

    func triggers() async throws -> [TriggerInfo] {
        let table = tableName
        return try await perform { try await $0.fetchTriggers(table: table) }
    }

    func coreTabs(includingForeignKeys: Bool) async throws -> CoreTabs {
        let table = tableName
        return try await perform { driver in
            CoreTabs(
                columns: try await driver.fetchColumns(table: table),
                indexes: try await driver.fetchIndexes(table: table),
                foreignKeys: includingForeignKeys ? try await driver.fetchForeignKeys(table: table) : []
            )
        }
    }

    func perform<T: Sendable>(
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        try await provider.withMetadataDriver(scope: scope, workload: .interactive, body)
    }
}
