//
//  CreateTableView.swift
//  TablePro
//
//  Self-contained view for creating a new database table.
//  Uses StructureChangeManager and DataGridView for column/index/FK editing.
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit

private enum CreateTableTab: CaseIterable {
    case columns
    case indexes
    case foreignKeys
    case sqlPreview

    var displayName: String {
        switch self {
        case .columns: String(localized: "Columns")
        case .indexes: String(localized: "Indexes")
        case .foreignKeys: String(localized: "Foreign Keys")
        case .sqlPreview: String(localized: "SQL Preview")
        }
    }
}

struct CreateTableView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CreateTableView")

    let connection: DatabaseConnection
    var coordinator: MainContentCoordinator?
    let selectionState: GridSelectionState

    @Environment(\.appServices) private var services

    /// The definition in progress. Held outside this view because the view is destroyed the moment
    /// the tab is deselected, and nothing in a Create Table tab exists anywhere else yet.
    @Bindable var draft: CreateTableDraft

    @State private var wrappedChangeManager: AnyChangeManager

    private var structureChangeManager: StructureChangeManager { draft.changeManager }

    @State private var selectedTab: CreateTableTab = .columns
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var gridDelegate: CreateTableGridDelegate
    @State private var actionHandler = CreateTableActionHandler()

    // DataGridView state
    @State private var selectedRows: Set<Int> = []
    @State private var sortState = SortState()
    @State private var columnLayout = ColumnLayoutState()
    @State private var serverSupport = StructureServerSupport.unrestricted

    init(
        connection: DatabaseConnection,
        coordinator: MainContentCoordinator?,
        selectionState: GridSelectionState,
        draft: CreateTableDraft
    ) {
        self.connection = connection
        self.coordinator = coordinator
        self.selectionState = selectionState
        self.draft = draft

        let manager = draft.changeManager
        _wrappedChangeManager = State(wrappedValue: AnyChangeManager(manager))
        _gridDelegate = State(wrappedValue: CreateTableGridDelegate(
            structureChangeManager: manager,
            structureTab: .columns,
            connection: connection
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            configBar
            Divider()
            toolbar
            Divider()
            tabContent
        }
        .navigationTitle(String(localized: "Create Table"))
        .onAppear {
            selectionState.indices = []
            coordinator?.inspectorRowSource = gridDelegate
            gridDelegate.onSelectedRowsChanged = { self.selectedRows = $0 }
            gridDelegate.onReferenceListsChanged = { coordinator?.inspectorRowSourceRevision += 1 }
            serverSupport = StructureServerSupport.forConnection(connection.id)
            updateGridDelegate()
            if structureChangeManager.workingColumns.isEmpty {
                structureChangeManager.addNewColumn()
            }
            actionHandler.createTable = { createTable() }
            actionHandler.undo = { gridDelegate.dataGridUndo() }
            actionHandler.redo = { gridDelegate.dataGridRedo() }
            coordinator?.createTableActions = actionHandler
            coordinator?.toolbarState.hasCreateTablePending = isReadyToCreate
        }
        .onDisappear {
            /// Guarded by identity, like the `inspectorRowSource` clear below it. SwiftUI does not
            /// order the outgoing view's `onDisappear` before the incoming view's `onAppear`, so an
            /// unguarded clear that lands second nils the wiring the incoming Create Table tab has
            /// already installed, leaving its Create button and its close prompt dead.
            ///
            /// The shared selection channel gets a second guard, because a data grid mounting in
            /// this tab's place restores its own rows into it and this clear landing afterwards
            /// would wipe them.
            if coordinator?.createTableActions === actionHandler {
                if GridSelectionOwner.resolve(
                    tabType: coordinator?.tabManager.selectedTab?.tabType,
                    resultsViewMode: coordinator?.tabManager.selectedTab?.display.resultsViewMode
                ) != .dataGrid {
                    selectionState.indices = []
                }
                coordinator?.createTableActions = nil
                coordinator?.toolbarState.hasCreateTablePending = false
            }
            if coordinator?.inspectorRowSource === gridDelegate {
                coordinator?.inspectorRowSource = nil
            }
        }
        .onChange(of: selectedRows) { _, newRows in selectionState.indices = newRows }
        .onChange(of: selectedTab) { updateGridDelegate() }
        .onChange(of: isReadyToCreate) { updateCreateTablePendingState() }
        .alert(String(localized: "Create Table Failed"), isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(verbatim: RevealedText(errorMessage ?? "").plainText)
        }
    }

    // MARK: - Config Bar

    private var configBar: some View {
        HStack(spacing: 12) {
            Text("Table Name:")
                .font(.body.weight(.medium))

            TextField("Enter table name", text: $draft.tableName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled(true)
                .frame(maxWidth: 300)
                .accessibilityIdentifier("create-table-name")

            if showMySQLOptions {
                Divider()
                    .frame(height: 20)

                Picker("Engine:", selection: $draft.tableOptions.engine) {
                    ForEach(CreateTableOptions.engines, id: \.self) { engine in
                        Text(engine).tag(engine)
                    }
                }
                .fixedSize()

                Picker("Charset:", selection: $draft.tableOptions.charset) {
                    ForEach(CreateTableOptions.charsets, id: \.self) { cs in
                        Text(cs).tag(cs)
                    }
                }
                .fixedSize()

                Picker("Collation:", selection: $draft.tableOptions.collation) {
                    ForEach(CreateTableOptions.collations[draft.tableOptions.charset] ?? [], id: \.self) { col in
                        Text(col).tag(col)
                    }
                }
                .fixedSize()
            }

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: draft.tableOptions.charset) { _, newCharset in
            if let first = CreateTableOptions.collations[newCharset]?.first {
                draft.tableOptions.collation = first
            }
        }
    }

    private var showMySQLOptions: Bool {
        connection.type == .mysql || connection.type == .mariadb
    }

    // MARK: - Toolbar

    private var availableTabs: [CreateTableTab] {
        var tabs = CreateTableTab.allCases
        if !connection.type.supportsForeignKeys {
            tabs = tabs.filter { $0 != .foreignKeys }
        }
        return tabs
    }

    private var isGridTab: Bool {
        selectedTab != .sqlPreview
    }

    private var toolbar: some View {
        /// The composed issues, not the plan's. A driver that cannot spell one of the statements,
        /// as Snowflake and Trino cannot spell `CREATE INDEX`, reports it only here, and reading the
        /// plan alone left Create Table enabled over a preview the app would then refuse to run.
        let issues = currentStatements().issues

        return HStack(spacing: 8) {
            Button(action: { gridDelegate.dataGridAddRow() }) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .help(String(localized: "Add Row"))
            .disabled(!isGridTab)

            Button(action: { gridDelegate.dataGridDeleteRows(selectedRows) }) {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .help(String(localized: "Delete Selected"))
            .disabled(!isGridTab || selectedRows.isEmpty)

            issueMessage(issues)

            Spacer(minLength: 12)

            Picker("", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer(minLength: 12)

            Button(isCreating ? String(localized: "Creating…") : String(localized: "Create Table")) {
                createTable()
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(!issues.isEmpty || isCreating)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("create-table-commit")
        }
        .padding()
    }

    /// The reason Create Table is unavailable, beside the row it is about.
    ///
    /// A row the user began and did not finish used to be deleted from the generated statement with
    /// no message, which is how a filled-in foreign key came to vanish between the grid and the SQL
    /// Preview. Naming the segment matters as much as naming the problem, because the offending row
    /// is usually on a segment the user is not looking at.
    @ViewBuilder
    private func issueMessage(_ issues: [SchemaDraftIssue]) -> some View {
        if let first = issues.first {
            Label(messageText(first), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(issues.map(\.qualifiedMessage).joined(separator: "\n"))
                .accessibilityIdentifier("create-table-validation")
        }
    }

    private func messageText(_ issue: SchemaDraftIssue) -> String {
        issue.tab == structureTab ? issue.message : issue.qualifiedMessage
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .columns, .indexes, .foreignKeys:
            structureGrid
        case .sqlPreview:
            sqlPreviewView
        }
    }

    // MARK: - Structure Grid

    private var structureTab: StructureTab {
        switch selectedTab {
        case .columns: return .columns
        case .indexes: return .indexes
        case .foreignKeys: return .foreignKeys
        case .sqlPreview: return .columns
        }
    }

    private func updateGridDelegate() {
        let provider = StructureRowProvider(
            changeManager: structureChangeManager,
            tab: structureTab,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            serverSupport: serverSupport
        )
        gridDelegate.structureTab = structureTab
        gridDelegate.serverSupport = serverSupport
        gridDelegate.orderedFields = provider.orderedColumnFields
        gridDelegate.schemaName = coordinator?.toolbarState.currentSchema
        coordinator?.inspectorRowSourceRevision += 1
    }

    private var structureGrid: some View {
        let provider = StructureRowProvider(
            changeManager: structureChangeManager,
            tab: structureTab,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            serverSupport: serverSupport
        )

        // Rebuild the row snapshot fresh on every call so cell edits made
        // through the delegate are visible to the next reloadData. Capturing
        // a snapshot here would let the cell view re-render with the pre-edit
        // value. Same rationale as `TableStructureView.structureGrid`.
        let manager = structureChangeManager
        let tab = structureTab
        let dbType = connection.type
        let support = serverSupport
        return DataGridView(
            tableRowsProvider: {
                StructureRowProvider(
                    changeManager: manager,
                    tab: tab,
                    databaseType: dbType,
                    additionalFields: [.primaryKey],
                    serverSupport: support
                ).asTableRows()
            },
            changeManager: wrappedChangeManager,
            isEditable: true,
            configuration: DataGridConfiguration(
                dropdownColumns: provider.dropdownColumns,
                typePickerColumns: provider.typePickerColumns,
                customDropdownOptions: provider.customDropdownOptions,
                connectionId: connection.id,
                databaseType: connection.type,
                databaseName: DatabaseManager.shared.browseDatabaseName(for: connection),
                schemaName: coordinator?.toolbarState.currentSchema,
                tabType: .createTable
            ),
            delegate: gridDelegate,
            selectedRowIndices: $selectedRows,
            sortState: $sortState,
            columnLayout: $columnLayout
        )
    }

    // MARK: - SQL Preview

    /// Derived from the working rows rather than refreshed by an event.
    ///
    /// It used to be `@State` written by `onChange(of: reloadVersion)`, and `reloadVersion` is bumped
    /// only by a schema load and a discard, never by an edit. What kept the preview honest was the
    /// segment switch remounting this branch, so anything that changed the draft while the preview
    /// was already on screen, undo among them, left a statement on screen that would not be run.
    private var sqlPreviewView: some View {
        let composed = currentStatements()
        return Group {
            if composed.statements.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.plaintext")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(composed.issues.first?.qualifiedMessage
                        ?? String(localized: "Add columns to see the CREATE TABLE statement"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DDLTextView(ddl: composed.preview, fontSize: .constant(13))
            }
        }
    }

    // Cell editing, row operations, undo/redo handled by CreateTableGridDelegate

    // MARK: - SQL Generation

    /// Pure, so the toolbar can ask on every keystroke without touching the driver.
    private var currentPlan: CreateTablePlan {
        CreateTableDraftBuilder.plan(
            tableName: draft.tableName,
            options: draft.tableOptions,
            columns: structureChangeManager.workingColumns,
            indexes: structureChangeManager.workingIndexes,
            foreignKeys: structureChangeManager.workingForeignKeys,
            dialect: ForeignKeyDialect.forType(connection.type),
            includesEngineOptions: showMySQLOptions
        )
    }

    private func currentStatements() -> CreateTableStatements {
        let plan = currentPlan
        guard let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?
            .schemaPluginDriver else {
            return CreateTableStatements(statements: [], issues: plan.issues, tableName: nil)
        }
        return CreateTableStatementComposer.compose(plan: plan, driver: pluginDriver)
    }

    // MARK: - Create Table

    private var isReadyToCreate: Bool {
        let composed = currentStatements()
        return !isCreating && composed.issues.isEmpty && !composed.statements.isEmpty
    }

    private func updateCreateTablePendingState() {
        coordinator?.toolbarState.hasCreateTablePending = isReadyToCreate
    }

    /// Routed through `DatabaseManager.executeCreateTable`, which owns the authorization, the
    /// isolated connection, the transaction and the history records.
    ///
    /// The view used to do all four itself against `driver(for:)`, which is the session driver. A
    /// `BEGIN` there joins whatever transaction a query tab left open, and the `COMMIT` after the
    /// last `CREATE INDEX` takes that tab's uncommitted work with it. `schemaChangeRoute` exists to
    /// keep the app's own DDL off the user's connection.
    private func createTable() {
        guard !isCreating else { return }
        let composed = currentStatements()
        guard composed.issues.isEmpty, !composed.statements.isEmpty else {
            errorMessage = composed.issues.map(\.qualifiedMessage).joined(separator: "\n")
            showError = true
            return
        }
        guard let scope = DatabaseManager.shared.browseScope(for: connection.id) else {
            errorMessage = String(localized: "Not connected to database")
            showError = true
            return
        }

        isCreating = true
        errorMessage = nil
        updateCreateTablePendingState()

        let statements = composed.statements
        let createdName = composed.tableName ?? draft.tableName
        Task {
            defer { isCreating = false }
            do {
                try await DatabaseManager.shared.executeCreateTable(
                    statements: statements,
                    databaseType: connection.type,
                    scope: scope
                )
                coordinator?.openTableTab(createdName)
                AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: connection.id))
            } catch {
                Self.logger.error("Create table failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
