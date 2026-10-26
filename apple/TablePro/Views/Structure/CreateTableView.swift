//
//  CreateTableView.swift
//  TablePro
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

    let scope: DatabaseScope?
    var coordinator: MainContentCoordinator?

    @Environment(\.appServices) private var services

    @ObservedObject var draft: CreateTableDraft
    @ObservedObject private var gridModel: DataGridModel
    private let gridAdapter: CreateTableGridAdapter

    private var structureChangeManager: StructureChangeManager { draft.changeManager }

    @State private var selectedTab: CreateTableTab = .columns
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var actionHandler = CreateTableActionHandler()

    init(
        connection: DatabaseConnection,
        scope: DatabaseScope?,
        coordinator: MainContentCoordinator?,
        draft: CreateTableDraft
    ) {
        self.connection = connection
        self.scope = scope
        self.coordinator = coordinator
        self.draft = draft
        let adapter = draft.gridAdapter(for: connection)
        self.gridAdapter = adapter
        self.gridModel = adapter.model
    }

    var body: some View {
        VStack(spacing: 0) {
            configBar
            Divider()
            editorContent
        }
        .navigationTitle(String(localized: "Create Table"))
        .onAppear {
            draft.resolveForm(
                from: DatabaseManager.shared.driver(for: connection.id)?.createTableFormSpec(schema: scope?.schema)
            )
            actionHandler.createTable = { createTable() }
            coordinator?.createTableActions = actionHandler
            if draft.form == nil {
                attachStructureGrid()
            }
            coordinator?.toolbarState.hasCreateTablePending = isReadyToCreate
        }
        .onDisappear {
            // Guarded by identity: the outgoing view's onDisappear can land after the incoming one's onAppear.
            if coordinator?.createTableActions === actionHandler {
                coordinator?.createTableActions = nil
                coordinator?.toolbarState.hasCreateTablePending = false
            }
            if coordinator?.inspectorRowSource === gridAdapter {
                coordinator?.inspectorRowSource = nil
            }
        }
        .onChange(of: selectedTab) { _ in gridAdapter.select(structureTab) }
        .onChange(of: structureChangeManager.reloadVersion) { _ in gridAdapter.refresh() }
        .onChange(of: structureChangeManager.hasChanges) { _ in gridAdapter.refresh() }
        .onChange(of: isReadyToCreate) { _ in updateCreateTablePendingState() }
        .task(id: compositionKey) { await recomposeAfterPause() }
        .alert(String(localized: "Create Table Failed"), isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(verbatim: RevealedText(errorMessage ?? "").plainText)
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if draft.form != nil {
            CreateTableFormEditor(
                draft: draft,
                databaseType: connection.type,
                isCreating: isCreating,
                generateStatements: { request in try formStatements(for: request) },
                onCreate: { createTable() }
            )
        } else if draft.hasResolvedForm {
            tabBar
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            commitBar
        } else {
            Color.clear
        }
    }

    private func attachStructureGrid() {
        coordinator?.inspectorRowSource = gridAdapter
        gridAdapter.coordinator = coordinator
        gridAdapter.serverSupport = StructureServerSupport.forConnection(connection.id)
        gridAdapter.schemaName = coordinator?.toolbarState.currentSchema
        if structureChangeManager.workingColumns.isEmpty {
            structureChangeManager.addNewColumn()
        }
        gridAdapter.select(structureTab)
        gridAdapter.refresh()
        actionHandler.undo = { gridAdapter.undo() }
        actionHandler.redo = { gridAdapter.redo() }
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
                .accessibilityLabel(String(localized: "Table Name"))
                .accessibilityIdentifier("create-table-name")

            if offersTableComment {
                Text("Comment:")
                    .font(.body.weight(.medium))

                TextField("Optional", text: $draft.tableOptions.comment)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .accessibilityLabel(String(localized: "Comment"))
                    .accessibilityIdentifier("create-table-comment")
            }

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
        .paneBarBackground()
        .onChange(of: draft.tableOptions.charset) { newCharset in
            if let first = CreateTableOptions.collations[newCharset]?.first {
                draft.tableOptions.collation = first
            }
        }
    }

    private var showMySQLOptions: Bool {
        CreateTableDraft.offersEngineOptions(for: connection.type)
    }

    private var offersTableComment: Bool {
        guard draft.hasResolvedForm, draft.form == nil else { return false }
        let support = DatabaseObjectToolEligibility.Support.of(DatabaseManager.shared.driver(for: connection.id))
        return support.commentableTypes.contains(.table)
    }

    // MARK: - Tabs

    private var availableTabs: [CreateTableTab] {
        var tabs = CreateTableTab.allCases
        if !connection.type.supportsForeignKeys {
            tabs = tabs.filter { $0 != .foreignKeys }
        }
        return tabs
    }

    private var tabBar: some View {
        PaneTabBar(
            title: String(localized: "Structure"),
            selection: $selectedTab.committingEdit(of: gridModel),
            identifier: "create-table-tabs"
        ) {
            ForEach(availableTabs, id: \.self) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
    }

    // One grid serves the three grid tabs: the adapter repoints it as the selection moves.
    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .columns, .indexes, .foreignKeys:
            structureGridPane
        case .sqlPreview:
            sqlPreviewView
        }
    }

    // MARK: - Commit Bar

    private var commitBar: some View {
        let issues = draft.composed?.issues ?? draft.plan(for: connection.type).issues

        return HStack(spacing: 8) {
            issueMessage(issues)

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
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

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

    // MARK: - Structure Grid

    private var structureTab: StructureTab {
        switch selectedTab {
        case .columns: return .columns
        case .indexes: return .indexes
        case .foreignKeys: return .foreignKeys
        case .sqlPreview: return .columns
        }
    }

    private var structureGridPane: some View {
        VStack(spacing: 0) {
            DataGridView(model: gridModel)
            Divider()
            rowButtons(identifier: rowButtonsIdentifier)
        }
    }

    private var rowButtonsIdentifier: String {
        switch selectedTab {
        case .columns, .sqlPreview: return "create-table-columns"
        case .indexes: return "create-table-indexes"
        case .foreignKeys: return "create-table-foreign-keys"
        }
    }

    // Add and Delete act on the shown tab's rows, since the adapter follows the selected tab.
    private func rowButtons(identifier: String) -> some View {
        HStack(spacing: 8) {
            Button(action: { gridAdapter.addRow() }) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
            }
            .help(String(localized: "Add Row"))
            .accessibilityLabel(String(localized: "Add Row"))
            .accessibilityIdentifier("\(identifier)-add")

            Button(action: { gridAdapter.deleteRows(gridModel.selectedRowIDs) }) {
                Image(systemName: "minus")
                    .frame(width: 24, height: 24)
            }
            .help(String(localized: "Delete Selected"))
            .accessibilityLabel(String(localized: "Delete Selected"))
            .disabled(gridModel.selection.isEmpty)
            .accessibilityIdentifier("\(identifier)-remove")

            Spacer()
        }
        .padding(8)
    }

    // MARK: - SQL Preview

    @ViewBuilder
    private var sqlPreviewView: some View {
        if let composed = draft.composed {
            if composed.statements.isEmpty {
                CreateTableSQLPreviewStandIn(content: .message(composed.issues.first?.qualifiedMessage))
            } else {
                DDLTextView(ddl: composed.preview, fontSize: .constant(13), databaseType: connection.type)
            }
        } else if let failure = draft.compositionFailure {
            CreateTableSQLPreviewStandIn(content: .message(failure))
        } else {
            uncomposedPreview(plan: draft.plan(for: connection.type))
        }
    }

    private func uncomposedPreview(plan: CreateTablePlan) -> some View {
        CreateTableSQLPreviewStandIn(
            content: plan.definition == nil ? .message(plan.issues.first?.qualifiedMessage) : .composing
        )
    }

    // MARK: - SQL Generation

    private static let compositionPause: Duration = .milliseconds(150)

    private var compositionKey: CreateTableCompositionKey? {
        scope.map { draft.compositionKey(scope: $0) }
    }

    private func recomposeAfterPause() async {
        guard let scope else { return }
        try? await Task.sleep(for: Self.compositionPause)
        guard !Task.isCancelled else { return }
        await draft.recompose(databaseType: connection.type, scope: scope)
    }

    // MARK: - Create Table

    private var isReadyToCreate: Bool {
        guard !isCreating else { return false }
        if let form = draft.form {
            return form.issues(tableName: draft.tableName).isEmpty
        }
        guard let composed = draft.composed else { return false }
        return composed.issues.isEmpty && !composed.statements.isEmpty
    }

    private func formStatements(for request: PluginCreateTableRequest) throws -> [String] {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw PluginCreateTableFormError(message: String(localized: "Not connected to database"))
        }
        return try driver.createTableStatements(for: request, schema: scope?.schema)
    }

    private func updateCreateTablePendingState() {
        coordinator?.toolbarState.hasCreateTablePending = isReadyToCreate
    }

    private func createTable() {
        guard draft.form != nil else {
            createTableFromStructureGrid()
            return
        }
        createTableFromForm()
    }

    private func createTableFromStructureGrid() {
        guard !isCreating else { return }
        let plan = draft.plan(for: connection.type)
        guard plan.issues.isEmpty else {
            errorMessage = plan.issues.map(\.qualifiedMessage).joined(separator: "\n")
            showError = true
            return
        }
        guard let scope else {
            errorMessage = String(localized: "Not connected to database")
            showError = true
            return
        }

        isCreating = true
        errorMessage = nil
        updateCreateTablePendingState()

        Task {
            defer { isCreating = false }
            do {
                let composed = try await DatabaseManager.shared.createTableStatements(plan: plan, scope: scope)
                guard composed.issues.isEmpty, !composed.statements.isEmpty else {
                    errorMessage = composed.issues.map(\.qualifiedMessage).joined(separator: "\n")
                    showError = true
                    return
                }
                let createdName = composed.tableName ?? draft.tableName
                try await runCreateTable(statements: composed.statements, createdName: createdName, in: scope)
            } catch {
                Self.logger.error("Create table failed: \(error.publicLogShape, privacy: .public)")
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func createTableFromForm() {
        guard !isCreating, let form = draft.form else { return }
        let issues = form.issues(tableName: draft.tableName)
        guard issues.isEmpty else {
            errorMessage = issues.map(\.qualifiedMessage).joined(separator: "\n")
            showError = true
            return
        }
        guard let scope else {
            errorMessage = String(localized: "Not connected to database")
            showError = true
            return
        }

        let request = form.request(tableName: draft.tableName)
        let schema = scope.schema
        isCreating = true
        errorMessage = nil
        draft.form?.clearSubmissionError()
        updateCreateTablePendingState()

        Task {
            defer { isCreating = false }
            do {
                let statements = try await DatabaseManager.shared.withMetadataDriver(scope: scope) { driver in
                    try driver.createTableStatements(for: request, schema: schema)
                }
                guard !statements.isEmpty else {
                    draft.form?.recordSubmissionError(PluginCreateTableFormError(
                        message: String(localized: "The form produced no statements to run.")
                    ))
                    return
                }
                try await runCreateTable(statements: statements, createdName: request.tableName, in: scope)
            } catch let formError as PluginCreateTableFormError {
                draft.form?.recordSubmissionError(formError)
            } catch {
                Self.logger.error("Create table failed: \(error.publicLogShape, privacy: .public)")
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func runCreateTable(statements: [String], createdName: String, in scope: DatabaseScope) async throws {
        do {
            try await DatabaseManager.shared.executeCreateTable(
                statements: statements,
                databaseType: connection.type,
                scope: scope
            )
        } catch let incomplete as CreateTableIncompleteError {
            openCreatedTable(createdName, in: scope, showStructure: true)
            AlertHelper.showErrorSheet(
                title: String(localized: "Table Created with Errors"),
                message: incomplete.message,
                recoverySuggestion: String(
                    localized: "The table exists, but a statement after CREATE TABLE failed. Finish the change in its Structure tab."
                ),
                window: coordinator?.contentWindow
            )
            return
        }
        openCreatedTable(createdName, in: scope, showStructure: false)
    }

    private func openCreatedTable(_ name: String, in scope: DatabaseScope, showStructure: Bool) {
        let created = DatabaseObjectChange(connectionId: connection.id, scope: scope, name: name, kind: .rows)
        coordinator?.openTableTab(
            name,
            schema: scope.schema,
            database: scope.database.nilIfEmpty,
            showStructure: showStructure
        )
        AppCommands.shared.objectChanged.send(created)
    }
}

internal struct CreateTableSQLPreviewStandIn: View {
    internal enum Content: Equatable {
        case message(String?)
        case composing
    }

    internal let content: Content

    internal var body: some View {
        stateView
            .valueStandInBackground()
    }

    @ViewBuilder
    private var stateView: some View {
        switch content {
        case .message(let message):
            VStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(message ?? String(localized: "Add columns to see the CREATE TABLE statement"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .composing:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
