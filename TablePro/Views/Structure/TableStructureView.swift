//
//  TableStructureView.swift
//  TablePro
//
//  View for displaying table structure using DataGridView
//  Complete refactor to match data grid UX
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

/// View displaying table structure with DataGridView
struct TableStructureView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TableStructureView")
    let tableName: String
    let connection: DatabaseConnection
    let toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator?

    @State private var selectedTab: StructureTab = .columns
    @State private var columns: [ColumnInfo] = []
    @State private var indexes: [IndexInfo] = []
    @State private var foreignKeys: [ForeignKeyInfo] = []
    @State private var ddlStatement: String = ""
    @State private var ddlFontSize: CGFloat = 13
    @State private var showCopyConfirmation = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var loadedTabs: Set<StructureTab> = []
    @State private var isReloadingAfterSave = false  // Prevent onChange loops during save reload
    @State private var lastSaveTime: Date?  // Track when we last saved
    @AppStorage("skipSchemaPreview") private var skipSchemaPreview = false

    // DataGridView state
    @State private var structureChangeManager = StructureChangeManager()
    @State private var wrappedChangeManager: AnyChangeManager
    @State private var selectedRows: Set<Int> = []
    @State private var sortState = SortState()
    @State private var editingCell: CellPosition?
    @State private var structureColumnLayout = ColumnLayoutState()
    @State private var actionHandler = StructureViewActionHandler()

    init(tableName: String, connection: DatabaseConnection, toolbarState: ConnectionToolbarState, coordinator: MainContentCoordinator?) {
        self.tableName = tableName
        self.connection = connection
        self.toolbarState = toolbarState
        self.coordinator = coordinator

        // Initialize wrappedChangeManager using the StateObject's wrappedValue
        let manager = StructureChangeManager()
        _structureChangeManager = State(wrappedValue: manager)
        _wrappedChangeManager = State(wrappedValue: AnyChangeManager(structureManager: manager))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contentArea
        }
        .task(loadInitialData)
        .onChange(of: selectedTab) { _, newValue in onSelectedTabChanged(newValue) }
        .onChange(of: columns) { onColumnsChanged() }
        .onChange(of: indexes) { onIndexesChanged() }
        .onChange(of: foreignKeys) { onForeignKeysChanged() }
        .onChange(of: selectedRows) { _, newSelection in
            AppState.shared.hasRowSelection = !newSelection.isEmpty
        }
        .onAppear {
            AppState.shared.isCurrentTabEditable = (selectedTab != .ddl)
            AppState.shared.hasRowSelection = !selectedRows.isEmpty
            AppState.shared.hasStructureChanges = structureChangeManager.hasChanges

            // Wire action handler for direct coordinator calls
            actionHandler.saveChanges = {
                if self.structureChangeManager.hasChanges && self.selectedTab != .ddl {
                    Task { await self.executeSchemaChanges() }
                }
            }
            actionHandler.previewSQL = { self.generateStructurePreviewSQL() }
            actionHandler.copyRows = { self.handleCopyRows(self.selectedRows) }
            actionHandler.pasteRows = { self.handlePaste() }
            actionHandler.undo = { self.handleUndo() }
            actionHandler.redo = { self.handleRedo() }
            coordinator?.structureActions = actionHandler
        }
        .onDisappear {
            AppState.shared.isCurrentTabEditable = false
            AppState.shared.hasRowSelection = false
            AppState.shared.hasStructureChanges = false
            coordinator?.structureActions = nil
        }
        .onChange(of: structureChangeManager.hasChanges) { _, newValue in
            AppState.shared.hasStructureChanges = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshData), perform: onRefreshData)
    }

    // MARK: - Toolbar

    private var availableTabs: [StructureTab] {
        var tabs = StructureTab.allCases
        if !connection.type.supportsForeignKeys {
            tabs = tabs.filter { $0 != .foreignKeys }
        }
        if connection.type != .clickhouse {
            tabs = tabs.filter { $0 != .parts }
        }
        return tabs
    }

    private var toolbar: some View {
        HStack {
            Spacer()

            // Tab picker
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

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if let error = errorMessage {
            errorView(error)
        } else {
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .columns, .indexes, .foreignKeys:
            structureGrid
        case .ddl:
            ddlView
        case .parts:
            ClickHousePartsView(tableName: tableName, connectionId: connection.id)
        }
    }

    // MARK: - Structure Grid (DataGridView)

    private var structureGrid: some View {
        let provider = StructureRowProvider(changeManager: structureChangeManager, tab: selectedTab, databaseType: connection.type)
        let canEdit = connection.type.supportsSchemaEditing

        let moveRowHandler: ((Int, Int) -> Void)? = {
            guard selectedTab == .columns,
                  canEdit,
                  !structureChangeManager.hasChanges,
                  PluginManager.shared.supportsColumnReorder(for: connection.type) else {
                return nil
            }
            return { fromIndex, toIndex in
                let columnsSnapshot = structureChangeManager.workingColumns
                Task { @MainActor in
                    do {
                        let executedSQL = try await StructureColumnReorderHandler.moveColumn(
                            fromIndex: fromIndex,
                            toIndex: toIndex,
                            workingColumns: columnsSnapshot,
                            tableName: tableName,
                            connectionId: connection.id
                        )
                        QueryHistoryManager.shared.recordQuery(
                            query: executedSQL.hasSuffix(";") ? executedSQL : executedSQL + ";",
                            connectionId: connection.id,
                            databaseName: connection.database,
                            executionTime: 0,
                            rowCount: 0,
                            wasSuccessful: true
                        )
                        isReloadingAfterSave = true
                        await loadColumns()
                        loadSchemaForEditing()
                        isReloadingAfterSave = false
                        ColumnLayoutStorage.shared.clear(for: tableName, connectionId: connection.id)
                        NotificationCenter.default.post(name: .refreshData, object: nil)
                    } catch {
                        AlertHelper.showErrorSheet(
                            title: String(localized: "Column Reorder Failed"),
                            message: error.localizedDescription,
                            window: NSApp.keyWindow
                        )
                    }
                }
            }
        }()

        return DataGridView(
            rowProvider: provider.asInMemoryProvider(),
            changeManager: wrappedChangeManager,
            isEditable: canEdit,
            onRefresh: nil,
            onCellEdit: handleCellEdit,
            onDeleteRows: handleDeleteRows,
            onCopyRows: handleCopyRows,
            onPasteRows: handlePaste,
            onUndo: handleUndo,
            onRedo: handleRedo,
            onSort: nil,
            onAddRow: canEdit ? { addNewRow() } : nil,
            onUndoInsert: nil,
            onFilterColumn: nil,
            getVisualState: { row in
                structureChangeManager.getVisualState(for: row, tab: selectedTab)
            },
            dropdownColumns: provider.dropdownColumns,
            typePickerColumns: provider.typePickerColumns,
            connectionId: connection.id,
            databaseType: getDatabaseType(),
            onMoveRow: moveRowHandler,
            selectedRowIndices: $selectedRows,
            sortState: $sortState,
            editingCell: $editingCell,
            columnLayout: $structureColumnLayout
        )
    }

    // MARK: - Event Handlers

    private func handleCellEdit(_ row: Int, _ column: Int, _ value: String?) {
        // column parameter is already adjusted for row number column by DataGridView
        guard column >= 0 else { return }

        switch selectedTab {
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

        case .ddl:
            break
        case .parts:
            break
        }
    }

    private func updateColumn(_ column: inout EditableColumnDefinition, at index: Int, with value: String) {
        if connection.type == .clickhouse {
            // ClickHouse: Name(0), Type(1), Nullable(2), Default(3), Comment(4) — no Auto Inc
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.comment = value.isEmpty ? nil : value
            default: break
            }
        } else {
            switch index {
            case 0: column.name = value
            case 1: column.dataType = value
            case 2: column.isNullable = value.uppercased() == "YES" || value == "1"
            case 3: column.defaultValue = value.isEmpty ? nil : value
            case 4: column.autoIncrement = value.uppercased() == "YES" || value == "1"
            case 5: column.comment = value.isEmpty ? nil : value
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

    private func handleDeleteRows(_ rows: Set<Int>) {
        // Find min/max for smart selection after delete
        let minRow = rows.min() ?? 0
        let maxRow = rows.max() ?? 0

        switch selectedTab {
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
        case .parts:
            selectedRows.removeAll()
            return
        case .ddl:
            selectedRows.removeAll()
            return
        }

        // Smart selection after delete (same as data grid behavior)
        let newCount: Int
        switch selectedTab {
        case .columns:
            newCount = structureChangeManager.workingColumns.count
        case .indexes:
            newCount = structureChangeManager.workingIndexes.count
        case .foreignKeys:
            newCount = structureChangeManager.workingForeignKeys.count
        case .ddl:
            newCount = 0
        case .parts:
            newCount = 0
        }

        // Calculate next row to select
        if newCount > 0 {
            if maxRow < newCount {
                // Select row after the deleted range
                selectedRows = [maxRow]
            } else if minRow > 0 {
                // Deleted at end, select previous row
                selectedRows = [minRow - 1]
            } else {
                // Deleted first row(s), select row 0 if exists
                selectedRows = [0]
            }
        } else {
            // No rows left
            selectedRows.removeAll()
        }
    }

    private func addNewRow() {
        switch selectedTab {
        case .columns:
            structureChangeManager.addNewColumn()
        case .indexes:
            structureChangeManager.addNewIndex()
        case .foreignKeys:
            structureChangeManager.addNewForeignKey()
        case .ddl:
            break
        case .parts:
            break
        }
    }

    // MARK: - Undo/Redo

    private func handleUndo() {
        guard selectedTab != .ddl else { return }
        structureChangeManager.undo()
    }

    private func handleRedo() {
        guard selectedTab != .ddl else { return }
        structureChangeManager.redo()
    }

    // MARK: - Copy/Paste

    // Custom pasteboard type for structure data (to avoid conflicts with data grid)
    private static let structurePasteboardType = NSPasteboard.PasteboardType("com.TablePro.structure")

    private func handleCopyRows(_ rowIndices: Set<Int>) {
        guard selectedTab != .ddl, selectedTab != .parts, !rowIndices.isEmpty else { return }

        var copiedItems: [Any] = []

        switch selectedTab {
        case .columns:
            for row in rowIndices.sorted() {
                guard row < structureChangeManager.workingColumns.count else { continue }
                let column = structureChangeManager.workingColumns[row]
                copiedItems.append(column)
            }
        case .indexes:
            for row in rowIndices.sorted() {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let index = structureChangeManager.workingIndexes[row]
                copiedItems.append(index)
            }
        case .foreignKeys:
            for row in rowIndices.sorted() {
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let fk = structureChangeManager.workingForeignKeys[row]
                copiedItems.append(fk)
            }
        case .ddl, .parts:
            break
        }

        // Store in pasteboard with both custom JSON type (internal paste) and TSV (external paste)
        guard !copiedItems.isEmpty else { return }

        // Build JSON string for custom pasteboard type
        var jsonString: String?
        if let columns = copiedItems as? [EditableColumnDefinition],
           let encoded = try? JSONEncoder().encode(columns) {
            jsonString = String(data: encoded, encoding: .utf8)
        } else if let indexes = copiedItems as? [EditableIndexDefinition],
                  let encoded = try? JSONEncoder().encode(indexes) {
            jsonString = String(data: encoded, encoding: .utf8)
        } else if let fks = copiedItems as? [EditableForeignKeyDefinition],
                  let encoded = try? JSONEncoder().encode(fks) {
            jsonString = String(data: encoded, encoding: .utf8)
        }

        // Build TSV string for external paste
        let provider = StructureRowProvider(changeManager: structureChangeManager, tab: selectedTab, databaseType: connection.type)
        var lines: [String] = []
        for row in rowIndices.sorted() {
            guard let rowData = provider.row(at: row) else { continue }
            let line = rowData.map { $0 ?? "NULL" }.joined(separator: "\t")
            lines.append(line)
        }
        let tsvString = lines.joined(separator: "\n")

        // Write both types on a single pasteboard item
        let item = NSPasteboardItem()
        if let json = jsonString {
            item.setString(json, forType: Self.structurePasteboardType)
        }
        if !tsvString.isEmpty {
            item.setString(tsvString, forType: .string)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func handlePaste() {
        guard let data = NSPasteboard.general.data(forType: Self.structurePasteboardType),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        // Try to parse as copied structure items
        let decoder = JSONDecoder()

        switch selectedTab {
        case .columns:
            guard let columns = try? decoder.decode([EditableColumnDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            // Create copies with new IDs
            for item in columns {
                let newColumn = EditableColumnDefinition(
                    id: UUID(),
                    name: item.name,
                    dataType: item.dataType,
                    isNullable: item.isNullable,
                    defaultValue: item.defaultValue,
                    autoIncrement: item.autoIncrement,
                    unsigned: item.unsigned,
                    comment: item.comment,
                    collation: item.collation,
                    onUpdate: item.onUpdate,
                    charset: item.charset,
                    extra: item.extra,
                    isPrimaryKey: item.isPrimaryKey
                )
                structureChangeManager.addColumn(newColumn)
            }

        case .indexes:
            guard let indexes = try? decoder.decode([EditableIndexDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in indexes {
                let newIndex = EditableIndexDefinition(
                    id: UUID(),
                    name: item.name,
                    columns: item.columns,
                    type: item.type,
                    isUnique: item.isUnique,
                    isPrimary: item.isPrimary,
                    comment: item.comment
                )
                structureChangeManager.addIndex(newIndex)
            }

        case .foreignKeys:
            guard let fks = try? decoder.decode([EditableForeignKeyDefinition].self, from: Data(jsonString.utf8)) else {
                return
            }
            for item in fks {
                let newFK = EditableForeignKeyDefinition(
                    id: UUID(),
                    name: item.name,
                    columns: item.columns,
                    referencedTable: item.referencedTable,
                    referencedColumns: item.referencedColumns,
                    onDelete: item.onDelete,
                    onUpdate: item.onUpdate
                )
                structureChangeManager.addForeignKey(newFK)
            }

        case .ddl:
            break
        case .parts:
            break
        }
    }

    // MARK: - Schema Operations

    private func generateStructurePreviewSQL() {
        let changes = structureChangeManager.getChangesArray()
        guard !changes.isEmpty else {
            return
        }

        // If user chose to skip preview, apply changes directly
        if skipSchemaPreview {
            Task {
                await executeSchemaChanges()
            }
            return
        }

        guard let pluginDriver = (DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter)?.schemaPluginDriver else {
            toolbarState.previewStatements = ["-- Error: no plugin driver available for DDL generation"]
            toolbarState.showSQLReviewPopover = true
            return
        }

        let generator = SchemaStatementGenerator(
            tableName: tableName,
            pluginDriver: pluginDriver
        )

        do {
            let schemaStatements = try generator.generate(changes: changes)
            toolbarState.previewStatements = schemaStatements.map(\.sql)
        } catch {
            toolbarState.previewStatements = ["-- Error generating SQL: \(error.localizedDescription)"]
        }
        toolbarState.showSQLReviewPopover = true
    }

    private func executeSchemaChanges() async {
        let changes = structureChangeManager.getChangesArray()
        guard !changes.isEmpty else { return }

        // Set flag BEFORE calling DatabaseManager (so we ignore its refresh notification)
        isReloadingAfterSave = true

        do {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: tableName,
                changes: changes,
                databaseType: getDatabaseType()
            )

            // Success - reload schema
            loadedTabs.removeAll()

            // Reload all structure data before calling loadSchemaForEditing
            await loadColumns()

            // Load indexes and foreign keys (needed for complete schema state)
            guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
                isReloadingAfterSave = false
                return
            }
            do {
                indexes = try await driver.fetchIndexes(table: tableName)
                foreignKeys = try await driver.fetchForeignKeys(table: tableName)
            } catch {
                Self.logger.error("Failed to reload indexes/FKs: \(error.localizedDescription, privacy: .public)")
            }

            // Now load the complete schema into the change manager
            loadSchemaForEditing()

            // Load current tab data for display
            await loadTabDataIfNeeded(selectedTab)

            // Force clear state after reload (in case it got set during the async process)
            structureChangeManager.discardChanges()

            lastSaveTime = Date()  // ✅ Record save time
            isReloadingAfterSave = false
        } catch {
            isReloadingAfterSave = false  // Clear flag on error
            AlertHelper.showErrorSheet(
                title: String(localized: "Error Applying Changes"),
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }

    private func discardChanges() {
        structureChangeManager.discardChanges()
    }

    private func getDatabaseType() -> DatabaseType {
        connection.type
    }

    // MARK: - DDL View

    private var ddlView: some View {
        VStack(spacing: 0) {
            // DDL toolbar
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Button(action: { ddlFontSize = max(10, ddlFontSize - 1) }) {
                        Image(systemName: "textformat.size.smaller")
                    }
                    Text("\(Int(ddlFontSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Button(action: { ddlFontSize = min(24, ddlFontSize + 1) }) {
                        Image(systemName: "textformat.size.larger")
                    }
                }
                .buttonStyle(.borderless)

                Spacer()

                if showCopyConfirmation {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Copied!")
                    }
                    .transition(.opacity)
                }

                Button(action: copyDDL) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(action: exportDDL) {
                    Label("Export", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if ddlStatement.isEmpty {
                emptyState(String(localized: "No DDL available"))
            } else {
                DDLTextView(ddl: ddlStatement, fontSize: $ddlFontSize)
            }
        }
    }

    // MARK: - Helper Views

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    @Sendable
    private func loadInitialData() async {
        await loadColumns()
    }

    private func loadColumns() async {
        isLoading = true
        errorMessage = nil

        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            errorMessage = String(localized: "Not connected")
            isLoading = false
            return
        }

        do {
            columns = try await driver.fetchColumns(table: tableName)
            loadedTabs.insert(.columns)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func loadTabDataIfNeeded(_ tab: StructureTab) async {
        guard !loadedTabs.contains(tab) else { return }
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }

        do {
            switch tab {
            case .columns:
                if columns.isEmpty {
                    columns = try await driver.fetchColumns(table: tableName)
                }
            case .indexes:
                indexes = try await driver.fetchIndexes(table: tableName)
            case .foreignKeys:
                foreignKeys = try await driver.fetchForeignKeys(table: tableName)
            case .ddl:
                let sequences = try await driver.fetchDependentSequences(forTable: tableName)
                let enumTypes = try await driver.fetchDependentTypes(forTable: tableName)
                let baseDDL = try await driver.fetchTableDDL(table: tableName)
                if sequences.isEmpty && enumTypes.isEmpty {
                    ddlStatement = baseDDL
                } else {
                    var preamble = ""
                    for seq in sequences {
                        preamble += seq.ddl + "\n\n"
                    }
                    for enumType in enumTypes {
                        let quotedName = "\"\(enumType.name.replacingOccurrences(of: "\"", with: "\"\""))\""
                        let quotedLabels = enumType.labels.map { "'\(SQLEscaping.escapeStringLiteral($0))'" }
                        preamble += "CREATE TYPE \(quotedName) AS ENUM (\(quotedLabels.joined(separator: ", ")));\n"
                    }
                    ddlStatement = preamble + "\n" + baseDDL
                }
            case .parts:
                break
            }
            loadedTabs.insert(tab)
        } catch {
            Self.logger.error("Failed to load \(tab.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSchemaForEditing() {
        structureChangeManager.loadSchema(
            tableName: tableName,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys,
            primaryKey: columns.filter { $0.isPrimaryKey }.map { $0.name },
            databaseType: getDatabaseType()
        )
    }

    // MARK: - DDL Actions

    private func copyDDL() {
        ClipboardService.shared.writeText(ddlStatement)

        withAnimation {
            showCopyConfirmation = true
        }

        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
            withAnimation {
                showCopyConfirmation = false
            }
        }
    }

    private func exportDDL() {
        let savePanel = NSSavePanel()
        if let sqlType = UTType(filenameExtension: "sql") {
            savePanel.allowedContentTypes = [sqlType]
        }
        savePanel.nameFieldStringValue = "\(tableName).sql"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try ddlStatement.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Self.logger.error("Failed to export: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Lifecycle Callbacks

    private func onSelectedTabChanged(_ new: StructureTab) {
        AppState.shared.isCurrentTabEditable = (new != .ddl && new != .parts)

        Task {
            await loadTabDataIfNeeded(new)
        }
    }

    private func onColumnsChanged() {
        guard !isReloadingAfterSave else { return }
        loadSchemaForEditing()
    }

    private func onIndexesChanged() {
        guard !isReloadingAfterSave else { return }
        loadSchemaForEditing()
    }

    private func onForeignKeysChanged() {
        guard !isReloadingAfterSave else { return }
        loadSchemaForEditing()
    }

    private func onRefreshData(_ notification: Notification) {
        // Ignore refresh notifications while we're in the middle of our own save/reload
        guard !isReloadingAfterSave else {
            Self.logger.debug("Ignoring refresh notification - currently reloading after save")
            return
        }

        // Skip warning if we just saved (within 2 seconds)
        let justSaved = lastSaveTime.map { Date().timeIntervalSince($0) < 2.0 } ?? false

        // Check for unsaved changes before refreshing
        if structureChangeManager.hasChanges && !justSaved {
            // Show confirmation dialog
            Task { @MainActor in
                let window = NSApp.keyWindow
                let confirmed = await AlertHelper.confirmDestructive(
                    title: String(localized: "Discard Changes?"),
                    message: String(localized: "You have unsaved changes to the table structure. Refreshing will discard these changes."),
                    confirmButton: String(localized: "Discard"),
                    cancelButton: String(localized: "Cancel"),
                    window: window
                )

                if confirmed {
                    // User chose to discard
                    discardChanges()
                    await loadColumns()
                    await loadTabDataIfNeeded(selectedTab)
                }
            }
            // If cancelled, do nothing
        } else {
            // No changes (or just saved), safe to refresh
            Task {
                await loadColumns()
                await loadTabDataIfNeeded(selectedTab)
            }
        }
    }
}

#Preview {
    TableStructureView(
        tableName: "users",
        connection: DatabaseConnection(
            name: "Test",
            host: "localhost",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql
        ),
        toolbarState: ConnectionToolbarState(),
        coordinator: nil
    )
    .frame(width: 800, height: 600)
}
