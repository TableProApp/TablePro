//
//  StructureEditingSession+Baseline.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension StructureEditingSession {
    // PostgreSQL leaves `isPrimaryKey` false on every column, so the primary index decides first.
    func adoptLoadedBaseline() {
        serverSupport = StructureServerSupport.forConnection(connection.id)
        let pkFromIndexes = indexes.first(where: { $0.isPrimary })?.columns ?? []
        let pkFromColumns = columns.filter { $0.isPrimaryKey }.map { $0.name }
        let primaryKey = pkFromIndexes.isEmpty ? pkFromColumns : pkFromIndexes

        changeManager.loadSchema(
            tableName: tableName,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            checkConstraints: checkConstraints,
            primaryKey: primaryKey,
            tableComment: loadedTableComment,
            tableOptions: loadedTableOptions,
            autoIncrementConfirmed: autoIncrementRead == .confirmed
        )
    }

    // Reads what the Structure tab's first mount reads, so an edit staged without the tab composes
    // the statements the tab would.
    func loadEditingBaseline(provider: any ScopedMetadataProviding = DatabaseManager.shared) async throws {
        let loader = TableStructureLoader(scope: scope, tableName: tableName, provider: provider)
        serverSupport = StructureServerSupport.forConnection(connection.id)
        columns = try await loader.columns()
        indexes = try await loader.indexes()
        foreignKeys = try await loader.foreignKeys()
        if availableTabs.contains(.checkConstraints) {
            checkConstraints = try await loader.checkConstraints()
        }
        adoptLoadedBaseline()
        hasLoaded = true
    }
}
