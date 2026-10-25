//
//  CreateTableDraft.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

internal struct CreateTableCompositionKey: Hashable {
    let scope: DatabaseScope
    let tableName: String
    let options: CreateTableOptions
    let columns: [EditableColumnDefinition]
    let indexes: [EditableIndexDefinition]
    let foreignKeys: [EditableForeignKeyDefinition]
}

@MainActor
internal final class CreateTableDraft: ObservableObject {
    internal let changeManager = StructureChangeManager()

    @Published internal var tableName = "" {
        didSet {
            guard tableName != oldValue else { return }
            form?.clearSubmissionError()
        }
    }
    @Published internal var tableOptions = CreateTableOptions()
    @Published internal var form: CreateTableFormState?
    @Published internal private(set) var hasResolvedForm = false

    internal func resolveForm(from spec: @autoclosure () -> PluginCreateTableFormSpec?) {
        guard !hasResolvedForm else { return }
        hasResolvedForm = true
        form = spec().map(CreateTableFormState.init(spec:))
    }

    @Published internal private(set) var composed: CreateTableStatements?
    @Published internal private(set) var compositionFailure: String?

    // Made on the first mount, which knows the connection; held here so the grid outlives the view.
    internal private(set) var gridAdapter: CreateTableGridAdapter?

    private var composedKey: CreateTableCompositionKey?
    private var compositionGeneration = 0
    private var changeManagerForwarding: AnyCancellable?

    internal init() {
        changeManagerForwarding = changeManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    internal var holdsWork: Bool {
        !tableName.isEmpty
            || ObjectCommentDraft.normalized(tableOptions.comment) != nil
            || form?.holdsWork == true
            || changeManager.workingColumns.contains { !$0.name.isEmpty }
            || changeManager.workingIndexes.contains { !$0.name.isEmpty || !$0.columns.isEmpty }
            || changeManager.workingForeignKeys.contains {
                !$0.name.isEmpty || !$0.columns.isEmpty || !$0.referencedTable.isEmpty
            }
    }

    internal func gridAdapter(for connection: DatabaseConnection) -> CreateTableGridAdapter {
        if let gridAdapter { return gridAdapter }
        let adapter = CreateTableGridAdapter(structureChangeManager: changeManager, connection: connection)
        gridAdapter = adapter
        return adapter
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
            includesEngineOptions: Self.offersEngineOptions(for: databaseType),
            suppliesItsOwnKey: PluginManager.shared.defaultPrimaryKeyColumn(for: databaseType) != nil
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

extension CreateTableDraft: ActiveGridModelProviding {
    // The definition grid, unless the driver supplied a form of its own.
    var activeGridModel: DataGridModel? {
        guard hasResolvedForm, form == nil else { return nil }
        return gridAdapter?.model
    }
}
