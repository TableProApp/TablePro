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

    @State private var structureChangeManager = StructureChangeManager()
    @State private var wrappedChangeManager: AnyChangeManager
    @State private var tableName = ""
    @State private var tableOptions = CreateTableOptions()
    @State private var selectedTab: CreateTableTab = .columns
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var previewSQL = ""

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
            if structureChangeManager.workingColumns.isEmpty {
                structureChangeManager.addNewColumn()
            }
        }
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
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))

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
            Button(action: addNewRow) {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .help(String(localized: "Add Row"))
            .disabled(!isGridTab)

            Button(action: { handleDeleteRows(selectedRows) }) {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
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
            onRefresh: nil,
            onCellEdit: handleCellEdit,
            onDeleteRows: handleDeleteRows,
            onCopyRows: nil,
            onPasteRows: nil,
            onUndo: handleUndo,
            onRedo: handleRedo,
            onSort: nil,
            onAddRow: { addNewRow() },
            onUndoInsert: nil,
            onFilterColumn: nil,
            getVisualState: nil,
            dropdownColumns: provider.dropdownColumns,
            typePickerColumns: provider.typePickerColumns,
            connectionId: connection.id,
            databaseType: connection.type,
            onMoveRow: nil,
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

    // MARK: - Cell Editing

    private func handleCellEdit(_ row: Int, _ column: Int, _ value: String?) {
        guard column >= 0 else { return }

        switch structureTab {
        case .columns:
            guard row < structureChangeManager.workingColumns.count else { return }
            var col = structureChangeManager.workingColumns[row]
            updateColumn(&col, at: column, with: value ?? "")
            structureChangeManager.updateColumn(id: col.id, with: col)

        case .indexes:
            guard row < structureChangeManager.workingIndexes.count else { return }
            var idx = structureChangeManager.workingIndexes[row]
            updateIndex(&idx, at: column, with: value ?? "")
            structureChangeManager.updateIndex(id: idx.id, with: idx)

        case .foreignKeys:
            guard row < structureChangeManager.workingForeignKeys.count else { return }
            var fk = structureChangeManager.workingForeignKeys[row]
            updateForeignKey(&fk, at: column, with: value ?? "")
            structureChangeManager.updateForeignKey(id: fk.id, with: fk)

        default:
            break
        }
    }

    private func updateColumn(_ column: inout EditableColumnDefinition, at index: Int, with value: String) {
        if connection.type == .clickhouse {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.isPrimaryKey = value.uppercased() == "YES" || value == "1"
            case 5: column.comment = value.isEmpty ? nil : value
            default: break
            }
        } else {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.isPrimaryKey = value.uppercased() == "YES" || value == "1"
            case 5: column.autoIncrement = value.uppercased() == "YES" || value == "1"
            case 6: column.comment = value.isEmpty ? nil : value
            default: break
            }
        }
    }

    private func updateIndex(_ index: inout EditableIndexDefinition, at colIndex: Int, with value: String) {
        switch colIndex {
        case 0: index.name = value
        case 1: index.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2:
            if let indexType = EditableIndexDefinition.IndexType(rawValue: value.uppercased()) {
                index.type = indexType
            }
        case 3: index.isUnique = value.uppercased() == "YES" || value == "1"
        default: break
        }
    }

    private func updateForeignKey(_ fk: inout EditableForeignKeyDefinition, at index: Int, with value: String) {
        switch index {
        case 0: fk.name = value
        case 1: fk.columns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 2: fk.referencedTable = value
        case 3: fk.referencedColumns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case 4:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onDelete = action
            }
        case 5:
            if let action = EditableForeignKeyDefinition.ReferentialAction(rawValue: value.uppercased()) {
                fk.onUpdate = action
            }
        default: break
        }
    }

    // MARK: - Row Operations

    private func handleDeleteRows(_ rows: Set<Int>) {
        switch structureTab {
        case .columns:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingColumns.count else { continue }
                let column = structureChangeManager.workingColumns[row]
                structureChangeManager.deleteColumn(id: column.id)
            }
        case .indexes:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let index = structureChangeManager.workingIndexes[row]
                structureChangeManager.deleteIndex(id: index.id)
            }
        case .foreignKeys:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let fk = structureChangeManager.workingForeignKeys[row]
                structureChangeManager.deleteForeignKey(id: fk.id)
            }
        default:
            break
        }

        let newCount: Int
        switch structureTab {
        case .columns: newCount = structureChangeManager.workingColumns.count
        case .indexes: newCount = structureChangeManager.workingIndexes.count
        case .foreignKeys: newCount = structureChangeManager.workingForeignKeys.count
        default: newCount = 0
        }

        if newCount > 0 {
            let maxRow = rows.max() ?? 0
            let minRow = rows.min() ?? 0
            if maxRow < newCount {
                selectedRows = [maxRow]
            } else if minRow > 0 {
                selectedRows = [minRow - 1]
            } else {
                selectedRows = [0]
            }
        } else {
            selectedRows.removeAll()
        }
    }

    private func addNewRow() {
        switch structureTab {
        case .columns:
            structureChangeManager.addNewColumn()
        case .indexes:
            structureChangeManager.addNewIndex()
        case .foreignKeys:
            structureChangeManager.addNewForeignKey()
        default:
            break
        }
    }

    private func handleUndo() {
        structureChangeManager.undo()
    }

    private func handleRedo() {
        structureChangeManager.redo()
    }

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
            columns: columns.map { toPluginColumnDefinition($0) },
            indexes: structureChangeManager.workingIndexes
                .filter { !$0.name.isEmpty && !$0.columns.isEmpty }
                .map { toPluginIndexDefinition($0) },
            foreignKeys: structureChangeManager.workingForeignKeys
                .filter { !$0.name.isEmpty && !$0.columns.isEmpty && !$0.referencedTable.isEmpty }
                .map { toPluginForeignKeyDefinition($0) },
            primaryKeyColumns: pkColumns,
            engine: showMySQLOptions ? tableOptions.engine : nil,
            charset: showMySQLOptions ? tableOptions.charset : nil,
            collation: showMySQLOptions ? tableOptions.collation : nil,
            ifNotExists: tableOptions.ifNotExists
        )

        let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver
        return pluginDriver?.generateCreateTableSQL(definition: definition)
    }

    private func toPluginColumnDefinition(_ col: EditableColumnDefinition) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: col.name,
            dataType: col.dataType,
            isNullable: col.isNullable,
            defaultValue: col.defaultValue,
            isPrimaryKey: col.isPrimaryKey,
            autoIncrement: col.autoIncrement,
            comment: col.comment,
            unsigned: col.unsigned,
            onUpdate: col.onUpdate
        )
    }

    private func toPluginIndexDefinition(_ index: EditableIndexDefinition) -> PluginIndexDefinition {
        PluginIndexDefinition(
            name: index.name,
            columns: index.columns,
            isUnique: index.isUnique,
            indexType: index.type.rawValue
        )
    }

    private func toPluginForeignKeyDefinition(_ fk: EditableForeignKeyDefinition) -> PluginForeignKeyDefinition {
        PluginForeignKeyDefinition(
            name: fk.name,
            columns: fk.columns,
            referencedTable: fk.referencedTable,
            referencedColumns: fk.referencedColumns,
            onDelete: fk.onDelete.rawValue,
            onUpdate: fk.onUpdate.rawValue
        )
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
