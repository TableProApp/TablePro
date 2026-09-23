//
//  CreateTableDraft.swift
//  TablePro
//

import Combine
import Foundation

internal struct CreateTableCompositionKey: Hashable {
    let scope: DatabaseScope
    let tableName: String
    let options: CreateTableOptions
    let columns: [EditableColumnDefinition]
    let indexes: [EditableIndexDefinition]
    let foreignKeys: [EditableForeignKeyDefinition]
}

/// A table definition in progress, held outside the view that edits it.
///
/// A Create Table tab's whole content is unsaved by definition: nothing exists on the server until
/// the user presses Create. `MainEditorContentView` builds only the selected tab, so leaving the
/// definition in the view's `@State` meant switching to any other tab and back threw away the table
/// name, the options and every column the user had defined, with no prompt and nothing in Undo.
@MainActor
internal final class CreateTableDraft: ObservableObject {
    internal let changeManager = StructureChangeManager()

    @Published internal var tableName = ""
    @Published internal var tableOptions = CreateTableOptions()

    @Published internal private(set) var composed: CreateTableStatements?
    @Published internal private(set) var compositionFailure: String?

    private var composedKey: CreateTableCompositionKey?
    private var compositionGeneration = 0
    private var changeManagerForwarding: AnyCancellable?

    internal init() {
        changeManagerForwarding = changeManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Whether the draft holds anything worth losing. A tab that has only just opened does not: the
    /// editor seeds one blank column so the grid has a row to show, which registers as a pending
    /// change without the user having typed anything.
    ///
    /// Indexes and foreign keys count for the same reason columns do. While they did not, a tab
    /// holding nothing but foreign keys closed on Cmd+W with no prompt and the draft was dropped.
    internal var holdsWork: Bool {
        !tableName.isEmpty
            || changeManager.workingColumns.contains { !$0.name.isEmpty }
            || changeManager.workingIndexes.contains { !$0.name.isEmpty || !$0.columns.isEmpty }
            || changeManager.workingForeignKeys.contains {
                !$0.name.isEmpty || !$0.columns.isEmpty || !$0.referencedTable.isEmpty
            }
    }

    internal static func offersEngineOptions(for databaseType: DatabaseType) -> Bool {
        databaseType == .mysql || databaseType == .mariadb
    }

    internal func plan(for databaseType: DatabaseType) -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: tableName,
            options: tableOptions,
            columns: changeManager.workingColumns,
            indexes: changeManager.workingIndexes,
            foreignKeys: changeManager.workingForeignKeys,
            dialect: ForeignKeyDialect.forType(databaseType),
            includesEngineOptions: Self.offersEngineOptions(for: databaseType)
        )
    }

    internal func compositionKey(scope: DatabaseScope) -> CreateTableCompositionKey {
        CreateTableCompositionKey(
            scope: scope,
            tableName: tableName,
            options: tableOptions,
            columns: changeManager.workingColumns,
            indexes: changeManager.workingIndexes,
            foreignKeys: changeManager.workingForeignKeys
        )
    }

    internal func recompose(databaseType: DatabaseType, scope: DatabaseScope) async {
        let key = compositionKey(scope: scope)
        guard key != composedKey else { return }

        compositionGeneration += 1
        let generation = compositionGeneration
        do {
            let statements = try await DatabaseManager.shared.createTableStatements(
                plan: plan(for: databaseType),
                scope: scope
            )
            guard generation == compositionGeneration else { return }
            composed = statements
            composedKey = key
            compositionFailure = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == compositionGeneration else { return }
            compositionFailure = error.localizedDescription
        }
    }
}
