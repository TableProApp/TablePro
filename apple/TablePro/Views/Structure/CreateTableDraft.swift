//
//  CreateTableDraft.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

internal struct CreateTableCompositionKey: Hashable {
    let scope: DatabaseScope
    let tableName: String
    let options: CreateTableOptions
    let offersEngineOptions: Bool
    let optionDefaults: CreateTableOptionDefaults
    let columns: [EditableColumnDefinition]
    let indexes: [EditableIndexDefinition]
    let foreignKeys: [EditableForeignKeyDefinition]
}

@MainActor
internal final class CreateTableDraft: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CreateTableDraft")

    internal let changeManager = StructureChangeManager()

    @Published internal var tableName = "" {
        didSet {
            guard tableName != oldValue else { return }
            form?.clearSubmissionError()
        }
    }
    @Published internal var tableOptions = CreateTableOptions()
    @Published internal var form: CreateTableFormState?

    // Server-wide: the character sets, collations and engines the pickers and the column cells offer.
    @Published internal private(set) var optionsCatalog: MetadataLoadState<TableOptionsCatalog?> = .idle
    // Per target database, so a draft compares a pick with the defaults of the database it creates the table in.
    @Published internal private(set) var optionDefaults = CreateTableOptionDefaults()
    private var optionDefaultsScope: DatabaseScope?
    private var optionsScope: DatabaseScope?
    private var optionsCatalogRead: Task<Void, Never>?
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
        adapter.draft = self
        gridAdapter = adapter
        return adapter
    }

    // The driver's catalog decides, never the engine's type: a driver without one has no table options.
    internal var catalog: TableOptionsCatalog? {
        guard case .loaded(let catalog) = optionsCatalog else { return nil }
        return catalog
    }

    internal var offersEngineOptions: Bool { catalog != nil }

    internal func selectCharacterSet(_ charset: String?) {
        guard charset != tableOptions.charset else { return }
        tableOptions = tableOptions.selectingCharacterSet(
            charset,
            collation: TableOptionsForm.defaultCollation(of: charset, in: catalog)
        )
    }

    // Idempotent: a remount skips what is loaded, and a read a switch cancelled runs again on return.
    internal func loadTableOptions(scope: DatabaseScope, provider: any ScopedMetadataProviding = DatabaseManager.shared) async {
        let loader = TableStructureLoader(scope: scope, tableName: "", provider: provider)
        await loadOptionsCatalog(using: loader)
        guard catalog != nil, optionDefaultsScope != scope else { return }
        do {
            let defaults = try await loader.defaultTableOptions()
            optionDefaults = CreateTableOptionDefaults(
                characterSet: defaults?.characterSet,
                collation: defaults?.collation,
                engine: catalog?.defaultEngine
            )
            optionDefaultsScope = scope
            tableOptions = tableOptions.seeded(with: optionDefaults)
        } catch {
            guard StructureFetchFailure(error, taskIsCancelled: Task.isCancelled) != .cancelled else { return }
            // Without the database's defaults every pick is written out, so the table still gets what the user chose.
            Self.logger.error("Failed to read the default table options: \(error.publicLogShape, privacy: .public)")
        }
    }

    // Opening a column's Charset or Collation menu is the retry.
    internal func retryOptionsCatalog() {
        guard case .failed = optionsCatalog, let optionsScope else { return }
        Task { await loadTableOptions(scope: optionsScope) }
    }

    private func loadOptionsCatalog(using loader: TableStructureLoader) async {
        optionsScope = loader.scope
        if case .loaded = optionsCatalog { return }
        // The draft owns the read, so a view task cancelled by a tab switch leaves it running for the view that returns.
        if let optionsCatalogRead {
            await optionsCatalogRead.value
            return
        }
        optionsCatalog = optionsCatalog.enteringLoad
        let read = Task { [weak self] in
            let outcome: MetadataFetchOutcome<TableOptionsCatalog?>
            do {
                outcome = .fetched(try await loader.tableOptionsCatalog())
            } catch {
                switch StructureFetchFailure(error, taskIsCancelled: Task.isCancelled) {
                case .cancelled:
                    outcome = .cancelled
                case .failed(let message):
                    Self.logger.error("Failed to read the table options catalog: \(error.publicLogShape, privacy: .public)")
                    outcome = .failed(message)
                }
            }
            guard let self else { return }
            optionsCatalog = optionsCatalog.settled(by: outcome, discardingValue: false)
            optionsCatalogRead = nil
        }
        optionsCatalogRead = read
        await read.value
    }

    internal func plan(for databaseType: DatabaseType) -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: tableName,
            options: tableOptions,
            columns: changeManager.workingColumns,
            indexes: changeManager.workingIndexes,
            foreignKeys: changeManager.workingForeignKeys,
            dialect: ForeignKeyDialect.forType(databaseType),
            includesEngineOptions: offersEngineOptions,
            defaults: optionDefaults,
            suppliesItsOwnKey: PluginManager.shared.defaultPrimaryKeyColumn(for: databaseType) != nil
        )
    }

    internal func compositionKey(scope: DatabaseScope) -> CreateTableCompositionKey {
        CreateTableCompositionKey(
            scope: scope,
            tableName: tableName,
            options: tableOptions,
            offersEngineOptions: offersEngineOptions,
            optionDefaults: optionDefaults,
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
