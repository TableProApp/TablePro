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

private enum CreateTableTab: String, CaseIterable {
    case columns = "Columns"
    case indexes = "Indexes"
    case foreignKeys = "Foreign Keys"
    case sqlPreview = "SQL Preview"
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
            tableNameBar
            Divider()
            tabPicker
            Divider()
            tabContent
            Divider()
            actionBar
        }
        .onAppear {
            if structureChangeManager.workingColumns.isEmpty {
                structureChangeManager.addNewColumn()
            }
        }
    }

    // MARK: - Table Name Bar

    private var tableNameBar: some View {
        HStack(spacing: 12) {
            Text("Table Name:")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))

            TextField("Enter table name", text: $tableName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            if showMySQLOptions {
                Divider()
                    .frame(height: 20)

                Text("Engine:")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
                Picker("", selection: $tableOptions.engine) {
                    ForEach(CreateTableOptions.engines, id: \.self) { engine in
                        Text(engine).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 100)

                Text("Charset:")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
                Picker("", selection: $tableOptions.charset) {
                    ForEach(CreateTableOptions.charsets, id: \.self) { cs in
                        Text(cs).tag(cs)
                    }
                }
                .labelsHidden()
                .frame(width: 100)

                Text("Collation:")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
                Picker("", selection: $tableOptions.collation) {
                    ForEach(CreateTableOptions.collations[tableOptions.charset] ?? [], id: \.self) { col in
                        Text(col).tag(col)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    // MARK: - Tab Picker

    private var availableTabs: [CreateTableTab] {
        var tabs = CreateTableTab.allCases
        if !connection.type.supportsForeignKeys {
            tabs = tabs.filter { $0 != .foreignKeys }
        }
        return tabs
    }

    private var tabPicker: some View {
        HStack {
            Spacer()
            Picker("", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
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
            getVisualState: { row in
                structureChangeManager.getVisualState(for: row, tab: structureTab)
            },
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
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: copyPreviewSQL) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(previewSQL.isEmpty)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

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
                ScrollView {
                    Text(previewSQL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear { generatePreviewSQL() }
        .onChange(of: structureChangeManager.reloadVersion) { generatePreviewSQL() }
    }

    private func copyPreviewSQL() {
        guard !previewSQL.isEmpty else { return }
        ClipboardService.shared.writeText(previewSQL)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            if let error = errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel") {
                NSApp.keyWindow?.close()
            }

            Button(isCreating ? String(localized: "Creating...") : String(localized: "Create Table")) {
                createTable()
            }
            .buttonStyle(.borderedProminent)
            .disabled(tableName.isEmpty || structureChangeManager.workingColumns.isEmpty || isCreating)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
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

        let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver
        let quote: (String) -> String = pluginDriver?.quoteIdentifier ?? { name in
            let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        let escape: (String) -> String = pluginDriver?.escapeStringLiteral ?? { value in
            value.replacingOccurrences(of: "'", with: "''")
        }

        var parts: [String] = []

        // Column definitions
        for col in columns {
            var def = "    \(quote(col.name)) \(col.dataType)"
            if col.unsigned { def += " UNSIGNED" }
            if !col.isNullable { def += " NOT NULL" }
            if col.autoIncrement { def += " AUTO_INCREMENT" }
            if let defaultVal = col.defaultValue, !defaultVal.isEmpty {
                if isDefaultExpression(defaultVal) {
                    def += " DEFAULT \(defaultVal)"
                } else {
                    def += " DEFAULT '\(escape(defaultVal))'"
                }
            }
            if let onUpdate = col.onUpdate, !onUpdate.isEmpty {
                def += " ON UPDATE \(onUpdate)"
            }
            if let comment = col.comment, !comment.isEmpty {
                def += " COMMENT '\(escape(comment))'"
            }
            parts.append(def)
        }

        // Primary key: columns marked as PK, or AUTO_INCREMENT columns (MySQL requires a key)
        var pkColumns = columns.filter { $0.isPrimaryKey }
        if pkColumns.isEmpty {
            pkColumns = columns.filter { $0.autoIncrement }
        }
        if !pkColumns.isEmpty {
            let pkNames = pkColumns.map { quote($0.name) }.joined(separator: ", ")
            parts.append("    PRIMARY KEY (\(pkNames))")
        }

        // Indexes
        let indexes = structureChangeManager.workingIndexes.filter { !$0.name.isEmpty && !$0.columns.isEmpty }
        for idx in indexes {
            let idxCols = idx.columns.map { quote($0) }.joined(separator: ", ")
            let unique = idx.isUnique ? "UNIQUE " : ""
            parts.append("    \(unique)INDEX \(quote(idx.name)) (\(idxCols))")
        }

        // Foreign keys
        let foreignKeys = structureChangeManager.workingForeignKeys.filter {
            !$0.name.isEmpty && !$0.columns.isEmpty && !$0.referencedTable.isEmpty && !$0.referencedColumns.isEmpty
        }
        for fk in foreignKeys {
            let fkCols = fk.columns.map { quote($0) }.joined(separator: ", ")
            let refCols = fk.referencedColumns.map { quote($0) }.joined(separator: ", ")
            var constraint = "    CONSTRAINT \(quote(fk.name)) FOREIGN KEY (\(fkCols))"
            constraint += " REFERENCES \(quote(fk.referencedTable)) (\(refCols))"
            if fk.onDelete != .noAction {
                constraint += " ON DELETE \(fk.onDelete.rawValue)"
            }
            if fk.onUpdate != .noAction {
                constraint += " ON UPDATE \(fk.onUpdate.rawValue)"
            }
            parts.append(constraint)
        }

        var sql = "CREATE TABLE \(quote(tableName.isEmpty ? "untitled" : tableName)) (\n"
        sql += parts.joined(separator: ",\n")
        sql += "\n)"

        // MySQL/MariaDB table options
        if showMySQLOptions {
            if let engine = tableOptions.engine { sql += " ENGINE=\(engine)" }
            if let charset = tableOptions.charset { sql += " DEFAULT CHARSET=\(charset)" }
            if let collation = tableOptions.collation { sql += " COLLATE=\(collation)" }
        }

        sql += ";"
        return sql
    }

    private func isDefaultExpression(_ value: String) -> Bool {
        let upper = value.uppercased()
        return upper == "NULL"
            || upper == "CURRENT_TIMESTAMP"
            || upper == "NOW()"
            || upper == "TRUE"
            || upper == "FALSE"
            || upper.hasPrefix("CURRENT_")
            || Int64(value) != nil
            || Double(value) != nil
    }

    // MARK: - Create Table

    private func createTable() {
        guard !tableName.isEmpty else { return }
        guard let sql = buildCreateTableSQL() else {
            errorMessage = String(localized: "Add at least one column with a name and type")
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
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

                // Close this window and open the new table
                if let coordinator {
                    coordinator.openTableTab(tableName)
                }
                NSApp.keyWindow?.close()
            } catch {
                Self.logger.error("Create table failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
