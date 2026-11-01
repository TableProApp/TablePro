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
    let checkConstraints: [EditableCheckConstraintDefinition]
}

internal enum CreateTablePane: Hashable, CaseIterable {
    case definition
    case ddl
}

// One Create Table tab: the definition it drafts over an empty baseline, its table options, and the commands the
// toolbar and menus send it. The coordinator holds it by tab id, so the work outlives the view.
@MainActor
internal final class CreateTableDraft: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CreateTableDraft")

    internal let connection: DatabaseConnection
    // The tab's own database and schema: the table is created there, and the reference menus read there.
    internal let scope: DatabaseScope?
    internal let changeManager = StructureChangeManager()
    internal let editor: StructureDefinitionEditor

    @Published internal var tableName = "" {
        didSet {
            guard tableName != oldValue else { return }
            form?.clearSubmissionError()
        }
    }
    @Published internal var tableOptions = CreateTableOptions()
    @Published internal var form: CreateTableFormState?
    @Published internal var pane: CreateTablePane = .definition
    @Published internal private(set) var hasResolvedForm = false
    @Published internal private(set) var isCreating = false

    // Server-wide: the character sets, collations and engines the inspector and the column cells offer.
    @Published internal private(set) var optionsCatalog: MetadataLoadState<TableOptionsCatalog?> = .idle
    // Per target database, so a pick is compared with the defaults of the database the table goes in.
    @Published internal private(set) var optionDefaults = CreateTableOptionDefaults()

    @Published internal private(set) var composed: CreateTableStatements?
    @Published internal private(set) var compositionFailure: String?

    internal var executionGate: any ExecutionGate = ExecutionGateProvider.shared

    private var focusesNameOnAppear = true
    private var optionDefaultsScope: DatabaseScope?
    private var optionsCatalogRead: Task<Void, Never>?
    private var composedKey: CreateTableCompositionKey?
    private var compositionGeneration = 0
    private var cancellables: Set<AnyCancellable> = []

    internal init(connection: DatabaseConnection, scope: DatabaseScope?) {
        self.connection = connection
        self.scope = scope
        editor = StructureDefinitionEditor(
            manager: changeManager,
            context: .newTable(
                connection: connection,
                databaseName: scope?.database ?? connection.database,
                schemaName: scope?.schema
            )
        )
        editor.characterSetContextProvider = { [weak self] in
            ColumnCharacterSetMenus.Context(
                catalog: self?.optionsCatalog ?? .idle,
                tableCharacterSet: self?.tableOptions.charset
            )
        }
        editor.characterSetCatalogReader = { [weak self] in
            self?.readOptionsCatalogIfNeeded()
        }
        changeManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        $optionsCatalog
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.editor.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - Setup

    // Runs on every appearance; each step skips what is done.
    internal func prepare(coordinator: MainContentCoordinator?) {
        editor.coordinator = coordinator
        editor.serverSupport = StructureServerSupport.forConnection(connection.id)
        resolveForm(from: DatabaseManager.shared.driver(for: connection.id)?.createTableFormSpec(schema: scope?.schema))
    }

    internal func resolveForm(from spec: @autoclosure () -> PluginCreateTableFormSpec?) {
        guard !hasResolvedForm else { return }
        hasResolvedForm = true
        form = spec().map(CreateTableFormState.init(spec:))
        if form == nil, changeManager.workingColumns.isEmpty {
            changeManager.addNewColumn()
            editor.refresh()
        }
    }

    // The Name field takes focus when the tab first shows, not on every return to it.
    internal func claimNameFocus() -> Bool {
        guard focusesNameOnAppear else { return false }
        focusesNameOnAppear = false
        return true
    }

    // MARK: - State

    internal var holdsWork: Bool {
        !tableName.isEmpty
            || ObjectCommentDraft.normalized(tableOptions.comment) != nil
            || form?.holdsWork == true
            || changeManager.workingColumns.contains { !$0.name.isEmpty }
            || changeManager.workingIndexes.contains { !$0.name.isEmpty || !$0.columns.isEmpty }
            || changeManager.workingForeignKeys.contains {
                !$0.name.isEmpty || !$0.columns.isEmpty || !$0.referencedTable.isEmpty
            }
            || changeManager.workingCheckConstraints.contains { !$0.name.isEmpty || !$0.expression.isEmpty }
    }

    internal var hasChanges: Bool { holdsWork }

    // The composed statement adds what the driver refuses; until it catches up with the draft, the plan's own.
    internal var issues: [SchemaDraftIssue] {
        currentComposedIssues ?? plan().issues
    }

    internal var isReadyToCreate: Bool {
        guard hasResolvedForm, !isCreating else { return false }
        if let form {
            return form.issues(tableName: tableName).isEmpty
        }
        let plan = plan()
        return plan.definition != nil && (currentComposedIssues ?? plan.issues).isEmpty
    }

    private var currentComposedIssues: [SchemaDraftIssue]? {
        guard let composed, let composedKey, composedKey == compositionKey else { return nil }
        return composed.issues
    }

    // The definition the issue names, when it names one row.
    internal func entityID(for issue: SchemaDraftIssue) -> UUID? {
        guard let row = issue.row else { return nil }
        let ids = StructureGridEdits.entityIDs(in: issue.section, manager: changeManager)
        return ids.indices.contains(row) ? ids[row] : nil
    }

    internal func reveal(_ issue: SchemaDraftIssue) {
        guard let id = entityID(for: issue) else { return }
        pane = .definition
        editor.reveal(section: issue.section, entity: id)
    }

    // MARK: - Commands

    // The section commands act on: the one holding the selection, else Columns.
    internal var commandSection: StructureSection { editor.commandSection }

    private var editsDefinition: Bool { hasResolvedForm && form == nil }

    internal var canUndo: Bool { editsDefinition && changeManager.canUndo }
    internal var canRedo: Bool { editsDefinition && changeManager.canRedo }
    internal var undoMenuItemTitle: String { changeManager.undoMenuItemTitle }
    internal var redoMenuItemTitle: String { changeManager.redoMenuItemTitle }

    internal func undo() {
        guard canUndo else { return }
        commitOpenEdits()
        changeManager.undo()
        editor.refresh()
    }

    internal func redo() {
        guard canRedo else { return }
        commitOpenEdits()
        changeManager.redo()
        editor.refresh()
    }

    internal var canAddRow: Bool { editsDefinition && pane == .definition && editor.canAdd(commandSection) }

    internal func addRow() {
        guard canAddRow else { return }
        editor.add(commandSection)
    }

    internal var canRemoveRows: Bool {
        editsDefinition && pane == .definition && editor.canRemoveSelection(in: commandSection)
    }

    internal func removeSelectedRows() {
        guard canRemoveRows else { return }
        editor.removeSelection(in: commandSection)
    }

    internal func commitOpenEdits() {
        editor.commitPendingEdits()
    }

    // MARK: - Table options

    // The driver's catalog decides, never the engine's type: a driver without one has no table options.
    internal var catalog: TableOptionsCatalog? {
        guard case .loaded(let catalog) = optionsCatalog else { return nil }
        return catalog
    }

    internal var offersEngineOptions: Bool { catalog != nil }

    // A driver's own form names everything its table takes.
    internal var offersTableComment: Bool {
        guard editsDefinition else { return false }
        let support = DatabaseObjectToolEligibility.Support.of(DatabaseManager.shared.driver(for: connection.id))
        return support.commentableTypes.contains(.table)
    }

    internal func selectCharacterSet(_ charset: String?) {
        guard charset != tableOptions.charset else { return }
        tableOptions = tableOptions.selectingCharacterSet(
            charset,
            collation: TableOptionsForm.defaultCollation(of: charset, in: catalog)
        )
    }

    // Idempotent: a remount skips what is loaded, and a read a switch cancelled runs again on return.
    internal func loadTableOptions(provider: any ScopedMetadataProviding = DatabaseManager.shared) async {
        guard let scope else { return }
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
    private func readOptionsCatalogIfNeeded() {
        switch optionsCatalog {
        case .idle, .failed:
            Task { await loadTableOptions() }
        case .loading, .loaded:
            break
        }
    }

    private func loadOptionsCatalog(using loader: TableStructureLoader) async {
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

    // MARK: - Composition

    internal func plan() -> CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: tableName,
            options: tableOptions,
            columns: changeManager.workingColumns,
            indexes: changeManager.workingIndexes,
            foreignKeys: changeManager.workingForeignKeys,
            checkConstraints: changeManager.workingCheckConstraints,
            dialect: ForeignKeyDialect.forType(connection.type),
            includesEngineOptions: offersEngineOptions,
            defaults: optionDefaults,
            suppliesItsOwnKey: PluginManager.shared.defaultPrimaryKeyColumn(for: connection.type) != nil
        )
    }

    internal var compositionKey: CreateTableCompositionKey? {
        guard let scope else { return nil }
        return CreateTableCompositionKey(
            scope: scope,
            tableName: tableName,
            options: tableOptions,
            offersEngineOptions: offersEngineOptions,
            optionDefaults: optionDefaults,
            columns: changeManager.workingColumns,
            indexes: changeManager.workingIndexes,
            foreignKeys: changeManager.workingForeignKeys,
            checkConstraints: changeManager.workingCheckConstraints
        )
    }

    // Keeps the last good statement on screen until the next one lands, and through a failure.
    internal func recompose() async {
        guard let scope, let key = compositionKey, key != composedKey else { return }

        compositionGeneration += 1
        let generation = compositionGeneration
        do {
            let statements = try await DatabaseManager.shared.createTableStatements(plan: plan(), scope: scope)
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

    internal func formStatements(for request: PluginCreateTableRequest) throws -> [String] {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw PluginCreateTableFormError(message: String(localized: "Not connected to database"))
        }
        return try driver.createTableStatements(for: request, schema: scope?.schema)
    }

    internal var formPreview: CreateTableFormState.Preview? {
        form?.preview(tableName: tableName) { request in try formStatements(for: request) }
    }

    // MARK: - Preview SQL

    // Refuses what Create Table refuses, so the statements shown are the ones it would run.
    internal func previewSQL(coordinator: MainContentCoordinator) {
        guard hasResolvedForm, coordinator.activeSheet == nil else { return }
        commitOpenEdits()
        if let formState = form {
            let formIssues = formState.issues(tableName: tableName)
            guard formIssues.isEmpty else {
                reportIncomplete(formIssues.map(\.qualifiedMessage), on: coordinator)
                return
            }
            do {
                let statements = try formStatements(for: formState.request(tableName: tableName))
                presentPreview(statements, on: coordinator)
            } catch {
                reportPreviewFailure(error, on: coordinator)
            }
            return
        }

        let plan = plan()
        guard plan.issues.isEmpty else {
            reportIncomplete(plan.issues.map(\.qualifiedMessage), on: coordinator)
            return
        }
        guard let scope else { return }
        Task {
            do {
                let composed = try await DatabaseManager.shared.createTableStatements(plan: plan, scope: scope)
                guard composed.issues.isEmpty, !composed.statements.isEmpty else {
                    reportIncomplete(composed.issues.map(\.qualifiedMessage), on: coordinator)
                    return
                }
                presentPreview(composed.statements, on: coordinator)
            } catch {
                reportPreviewFailure(error, on: coordinator)
            }
        }
    }

    private func presentPreview(_ statements: [String], on coordinator: MainContentCoordinator) {
        guard coordinator.activeSheet == nil, coordinator.activeCreateTableDraft === self else { return }
        coordinator.toolbarState.previewStatements = statements
        coordinator.activeSheet = .sqlPreview
    }

    private func reportIncomplete(_ messages: [String], on coordinator: MainContentCoordinator) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Some Changes Are Incomplete"),
            message: messages.joined(separator: "\n"),
            window: coordinator.contentWindow
        )
    }

    private func reportPreviewFailure(_ error: any Error, on coordinator: MainContentCoordinator) {
        Self.logger.error("Create Table preview failed: \(error.publicLogShape, privacy: .public)")
        AlertHelper.showErrorSheet(
            title: String(localized: "Preview SQL"),
            message: error.localizedDescription,
            window: coordinator.contentWindow
        )
    }

    // MARK: - Create

    // What Cmd+S and the toolbar's Create Table run.
    internal func create(coordinator: MainContentCoordinator) {
        guard hasResolvedForm, !isCreating else { return }
        commitOpenEdits()
        if form != nil {
            createFromForm(coordinator: coordinator)
        } else {
            createFromDefinition(coordinator: coordinator)
        }
    }

    private func createFromDefinition(coordinator: MainContentCoordinator) {
        let plan = plan()
        guard plan.issues.isEmpty else {
            reportFailure(plan.issues.map(\.qualifiedMessage).joined(separator: "\n"), on: coordinator)
            return
        }
        guard let scope else {
            reportFailure(String(localized: "Not connected to database"), on: coordinator)
            return
        }

        isCreating = true
        Task {
            defer { isCreating = false }
            do {
                let composed = try await DatabaseManager.shared.createTableStatements(plan: plan, scope: scope)
                guard composed.issues.isEmpty, !composed.statements.isEmpty else {
                    reportFailure(composed.issues.map(\.qualifiedMessage).joined(separator: "\n"), on: coordinator)
                    return
                }
                try await run(
                    composed.statements,
                    creating: composed.tableName ?? tableName,
                    in: scope,
                    coordinator: coordinator
                )
            } catch {
                Self.logger.error("Create table failed: \(error.publicLogShape, privacy: .public)")
                reportFailure(error.localizedDescription, on: coordinator)
            }
        }
    }

    private func createFromForm(coordinator: MainContentCoordinator) {
        guard let formState = form else { return }
        let formIssues = formState.issues(tableName: tableName)
        guard formIssues.isEmpty else {
            reportFailure(formIssues.map(\.qualifiedMessage).joined(separator: "\n"), on: coordinator)
            return
        }
        guard let scope else {
            reportFailure(String(localized: "Not connected to database"), on: coordinator)
            return
        }

        let request = formState.request(tableName: tableName)
        let schema = scope.schema
        isCreating = true
        form?.clearSubmissionError()

        Task {
            defer { isCreating = false }
            do {
                let statements = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                    try driver.createTableStatements(for: request, schema: schema)
                }
                guard !statements.isEmpty else {
                    form?.recordSubmissionError(PluginCreateTableFormError(
                        message: String(localized: "The form produced no statements to run.")
                    ))
                    return
                }
                try await run(statements, creating: request.tableName, in: scope, coordinator: coordinator)
            } catch let formError as PluginCreateTableFormError {
                form?.recordSubmissionError(formError)
            } catch {
                Self.logger.error("Create table failed: \(error.publicLogShape, privacy: .public)")
                reportFailure(error.localizedDescription, on: coordinator)
            }
        }
    }

    // The draft keeps its work after a create, so the tab stays open; the new table opens in its own tab.
    private func run(
        _ statements: [String],
        creating name: String,
        in scope: DatabaseScope,
        coordinator: MainContentCoordinator
    ) async throws {
        do {
            try await DatabaseManager.shared.executeCreateTable(
                statements: statements,
                databaseType: connection.type,
                scope: scope,
                gate: executionGate
            )
        } catch let incomplete as CreateTableIncompleteError {
            openCreatedTable(name, in: scope, showStructure: true, coordinator: coordinator)
            AlertHelper.showErrorSheet(
                title: String(localized: "Table Created with Errors"),
                message: incomplete.message,
                recoverySuggestion: String(
                    localized: "The table exists, but a statement after CREATE TABLE failed. Finish the change in its Structure tab."
                ),
                window: coordinator.contentWindow
            )
            return
        }
        openCreatedTable(name, in: scope, showStructure: false, coordinator: coordinator)
    }

    private func openCreatedTable(
        _ name: String,
        in scope: DatabaseScope,
        showStructure: Bool,
        coordinator: MainContentCoordinator
    ) {
        coordinator.openTableTab(
            name,
            schema: scope.schema,
            database: scope.database.nilIfEmpty,
            showStructure: showStructure
        )
        AppCommands.shared.objectChanged.send(
            DatabaseObjectChange(connectionId: connection.id, scope: scope, name: name, kind: .rows)
        )
    }

    private func reportFailure(_ message: String, on coordinator: MainContentCoordinator) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Create Table Failed"),
            message: message,
            window: coordinator.contentWindow
        )
    }
}

extension CreateTableDraft: ActiveGridModelProviding {
    // The section holding the selection while the Definition page is on screen; a driver's form has no grid.
    var activeGridModel: DataGridModel? {
        guard editsDefinition, pane == .definition else { return nil }
        return editor.focusedModel ?? editor.adapter(for: .columns).model
    }
}
