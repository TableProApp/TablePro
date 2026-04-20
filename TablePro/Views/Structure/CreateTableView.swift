//
//  CreateTableView.swift
//  TablePro
//
//  Self-contained view for creating a new database table.
//  Uses StructureChangeManager and DataGridView for column/index/FK editing.
//

import AppKit
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

    @State private var structureChangeManager: StructureChangeManager
    @State private var wrappedChangeManager: AnyChangeManager
    @State private var tableName = ""
    @State private var tableOptions = CreateTableOptions()
    @State private var selectedTab: CreateTableTab = .columns
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var previewSQL = ""
    @State private var gridDelegate: CreateTableGridDelegate

    // DataGridView state
    @State private var selectedRows: Set<Int> = []
    @State private var sortState = SortState()
    @State private var editingCell: CellPosition?
    @State private var columnLayout = ColumnLayoutState()

    init(connection: DatabaseConnection, coordinator: MainContentCoordinator?) {
        self.connection = connection
        self.coordinator = coordinator

        let manager = StructureChangeManager()
        _structureChangeManager = State(wrappedValue: manager)
        _wrappedChangeManager = State(wrappedValue: AnyChangeManager(structureManager: manager))
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
            gridDelegate.onSelectedRowsChanged = { self.selectedRows = $0 }
            updateGridDelegate()
            if structureChangeManager.workingColumns.isEmpty {
                structureChangeManager.addNewColumn()
            }
        }
        .onChange(of: selectedTab) { updateGridDelegate() }
        .alert(String(localized: "Create Table Failed"), isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Config Bar

    private var configBar: some View {
        HStack(spacing: 12) {
            Text("Table Name:")
                .font(.body.weight(.medium))

            TextField("Enter table name", text: $tableName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            if showMySQLOptions {
                Divider()
                    .frame(height: 20)

                Picker("Engine:", selection: $tableOptions.engine) {
                    ForEach(CreateTableOptions.engines, id: \.self) { engine in
                        Text(engine).tag(engine)
                    }
                }
                .fixedSize()

                Picker("Charset:", selection: $tableOptions.charset) {
                    ForEach(CreateTableOptions.charsets, id: \.self) { cs in
                        Text(cs).tag(cs)
                    }
                }
                .fixedSize()

                Picker("Collation:", selection: $tableOptions.collation) {
                    ForEach(CreateTableOptions.collations[tableOptions.charset] ?? [], id: \.self) { col in
                        Text(col).tag(col)
                    }
                }
                .fixedSize()
            }

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: tableOptions.charset) { _, newCharset in
            if let first = CreateTableOptions.collations[newCharset]?.first {
                tableOptions.collation = first
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
        HStack(spacing: 8) {
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

            Spacer()

            Picker("", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            Button(isCreating ? String(localized: "Creating...") : String(localized: "Create Table")) {
                createTable()
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .disabled(tableName.isEmpty || structureChangeManager.workingColumns.isEmpty || isCreating)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
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
            additionalFields: [.primaryKey]
        )
        gridDelegate.structureTab = structureTab
        gridDelegate.orderedFields = provider.orderedColumnFields
    }

    private var structureGrid: some View {
        let provider = StructureRowProvider(
            changeManager: structureChangeManager,
            tab: structureTab,
            databaseType: connection.type,
            additionalFields: [.primaryKey]
        )

        return DataGridView(
            rowProvider: provider.asInMemoryProvider(),
            changeManager: wrappedChangeManager,
            isEditable: true,
            configuration: DataGridConfiguration(
                dropdownColumns: provider.dropdownColumns,
                typePickerColumns: provider.typePickerColumns,
                connectionId: connection.id,
                databaseType: connection.type
            ),
            delegate: gridDelegate,
            selectedRowIndices: $selectedRows,
            sortState: $sortState,
            editingCell: $editingCell,
            columnLayout: $columnLayout
        )
    }

    // MARK: - SQL Preview

    private var sqlPreviewView: some View {
        Group {
            if previewSQL.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.plaintext")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Add columns to see the CREATE TABLE statement")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DDLTextView(ddl: previewSQL, fontSize: .constant(13))
            }
        }
        .onAppear { generatePreviewSQL() }
        .onChange(of: structureChangeManager.reloadVersion) { generatePreviewSQL() }
        .onChange(of: tableName) { generatePreviewSQL() }
        .onChange(of: tableOptions) { generatePreviewSQL() }
    }

    // Cell editing, row operations, undo/redo handled by CreateTableGridDelegate

    // MARK: - SQL Generation

    private func generatePreviewSQL() {
        let sql = buildCreateTableSQL()
        previewSQL = sql ?? ""
    }

    private func buildCreateTableSQL() -> String? {
        let columns = structureChangeManager.workingColumns.filter { !$0.name.isEmpty && !$0.dataType.isEmpty }
        guard !columns.isEmpty else { return nil }

        var pkColumns = columns.filter { $0.isPrimaryKey }.map(\.name)
        if pkColumns.isEmpty {
            pkColumns = columns.filter { $0.autoIncrement }.map(\.name)
        }

        let definition = PluginCreateTableDefinition(
            tableName: tableName.isEmpty ? "untitled" : tableName,
            columns: columns.map { $0.toPlugin() },
            indexes: structureChangeManager.workingIndexes
                .filter { !$0.name.isEmpty && !$0.columns.isEmpty }
                .map { $0.toPlugin() },
            foreignKeys: structureChangeManager.workingForeignKeys
                .filter { !$0.name.isEmpty && !$0.columns.isEmpty && !$0.referencedTable.isEmpty }
                .map { $0.toPlugin() },
            primaryKeyColumns: pkColumns,
            engine: showMySQLOptions ? tableOptions.engine : nil,
            charset: showMySQLOptions ? tableOptions.charset : nil,
            collation: showMySQLOptions ? tableOptions.collation : nil,
            ifNotExists: tableOptions.ifNotExists
        )

        let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver
        return pluginDriver?.generateCreateTableSQL(definition: definition)
    }

    // MARK: - Create Table

    private func createTable() {
        guard !tableName.isEmpty else { return }
        guard let sql = buildCreateTableSQL() else {
            errorMessage = String(localized: "Add at least one column with a name and type")
            showError = true
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
            defer { isCreating = false }
            do {
                guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
                    throw NSError(
                        domain: "CreateTableView", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "Not connected to database")]
                    )
                }

                _ = try await driver.execute(query: sql)

                QueryHistoryManager.shared.recordQuery(
                    query: sql,
                    connectionId: connection.id,
                    databaseName: connection.database,
                    executionTime: 0,
                    rowCount: 0,
                    wasSuccessful: true
                )

                NotificationCenter.default.post(name: .refreshData, object: nil)

                if let coordinator {
                    coordinator.openTableTab(tableName)
                }
            } catch {
                Self.logger.error("Create table failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}
