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
    static let logger = Logger(subsystem: "com.TablePro", category: "TableStructureView")
    static let structurePasteboardType = NSPasteboard.PasteboardType("com.TablePro.structure")
    let tableName: String
    let connection: DatabaseConnection
    let toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator?

    @State var selectedTab: StructureTab = .columns
    @State var columns: [ColumnInfo] = []
    @State var indexes: [IndexInfo] = []
    @State var foreignKeys: [ForeignKeyInfo] = []
    @State var ddlStatement: String = ""
    @State var ddlFontSize: CGFloat = 13
    @State var showCopyConfirmation = false
    @State var copyResetTask: Task<Void, Never>?
    @State var isLoading = true
    @State var isInitialLoading = true
    @State var errorMessage: String?
    @State var loadedTabs: Set<StructureTab> = []
    @State var isReloadingAfterSave = false  // Prevent onChange loops during save reload
    @State var lastSaveTime: Date?  // Track when we last saved
    @AppStorage("skipSchemaPreview") var skipSchemaPreview = false

    // Search and sort state
    @State var searchText = ""
    @State var structureSortDescriptor: StructureSortDescriptor?
    @State var displayVersion: Int = 0

    // DataGridView state
    @State var structureChangeManager: StructureChangeManager
    @State var wrappedChangeManager: AnyChangeManager
    @State var selectedRows: Set<Int> = []
    @State var sortState = SortState()
    @State var editingCell: CellPosition?
    @State var structureColumnLayout = ColumnLayoutState()
    @State var actionHandler = StructureViewActionHandler()
    @State var gridDelegate: StructureGridDelegate

    init(tableName: String, connection: DatabaseConnection, toolbarState: ConnectionToolbarState, coordinator: MainContentCoordinator?) {
        self.tableName = tableName
        self.connection = connection
        self.toolbarState = toolbarState
        self.coordinator = coordinator

        let manager = StructureChangeManager()
        _structureChangeManager = State(wrappedValue: manager)
        _wrappedChangeManager = State(wrappedValue: AnyChangeManager(structureManager: manager))
        _gridDelegate = State(wrappedValue: StructureGridDelegate(
            structureChangeManager: manager,
            selectedTab: .columns,
            connection: connection,
            tableName: tableName,
            coordinator: coordinator
        ))
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
        .onChange(of: searchText) { displayVersion += 1 }
        .onChange(of: displayVersion) { updateGridDelegate() }
        .onAppear {
            coordinator?.toolbarState.hasStructureChanges = structureChangeManager.hasChanges

            gridDelegate.onSelectedRowsChanged = { self.selectedRows = $0 }
            gridDelegate.coordinator = coordinator
            gridDelegate.sortHandler = { [self] column, ascending in
                structureSortDescriptor = StructureSortDescriptor(column: column, ascending: ascending)
                var newSortState = SortState()
                newSortState.columns = [SortColumn(columnIndex: column, direction: ascending ? .ascending : .descending)]
                sortState = newSortState
                displayVersion += 1
            }
            updateGridDelegate()

            actionHandler.saveChanges = {
                if self.structureChangeManager.hasChanges && self.selectedTab != .ddl {
                    Task { await self.executeSchemaChanges() }
                }
            }
            actionHandler.previewSQL = { self.generateStructurePreviewSQL() }
            actionHandler.copyRows = { self.gridDelegate.dataGridCopyRows(self.selectedRows) }
            actionHandler.pasteRows = { self.gridDelegate.dataGridPasteRows() }
            actionHandler.undo = { self.gridDelegate.dataGridUndo() }
            actionHandler.redo = { self.gridDelegate.dataGridRedo() }
            coordinator?.structureActions = actionHandler
        }
        .onDisappear {
            coordinator?.toolbarState.hasStructureChanges = false
            coordinator?.structureActions = nil
        }
        .onChange(of: structureChangeManager.hasChanges) { _, newValue in
            coordinator?.toolbarState.hasStructureChanges = newValue
            updateGridDelegate()
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

            Picker("", selection: $selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tabLabel(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()
        }
        .padding()
    }

    // MARK: - Tab Label with Count Badge

    private func tabLabel(for tab: StructureTab) -> String {
        let count: Int?
        switch tab {
        case .columns:
            count = loadedTabs.contains(.columns) ? columns.count : nil
        case .indexes:
            count = loadedTabs.contains(.indexes) ? indexes.count : nil
        case .foreignKeys:
            count = loadedTabs.contains(.foreignKeys) ? foreignKeys.count : nil
        case .ddl, .parts:
            count = nil
        }

        if let count {
            return "\(tab.displayName) (\(count))"
        }
        return tab.displayName
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

    private func makeCurrentProvider() -> StructureRowProvider {
        StructureRowProvider(
            changeManager: structureChangeManager,
            tab: selectedTab,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            filterText: searchText.isEmpty ? nil : searchText,
            sortDescriptor: structureSortDescriptor
        )
    }

    func updateGridDelegate() {
        let provider = makeCurrentProvider()
        let canEdit = connection.type.supportsSchemaEditing

        gridDelegate.selectedTab = selectedTab
        gridDelegate.currentProvider = provider
        gridDelegate.orderedFields = provider.orderedColumnFields

        let moveRowHandler: ((Int, Int) -> Void)? = {
            guard selectedTab == .columns,
                  canEdit,
                  !structureChangeManager.hasChanges,
                  PluginManager.shared.supportsColumnReorder(for: connection.type) else {
                return nil
            }
            return { [self] fromIndex, toIndex in
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
                            window: coordinator?.contentWindow
                        )
                    }
                }
            }
        }()

        gridDelegate.moveRowHandler = moveRowHandler
    }

    private var structureGrid: some View {
        let provider = makeCurrentProvider()
        let canEdit = connection.type.supportsSchemaEditing
        let customOptions = provider.customDropdownOptions
        let allDropdownColumns = provider.dropdownColumns.union(Set(customOptions.keys))

        return DataGridView(
            rowProvider: provider.asInMemoryProvider(),
            changeManager: wrappedChangeManager,
            resultVersion: displayVersion,
            isEditable: canEdit,
            configuration: DataGridConfiguration(
                dropdownColumns: allDropdownColumns,
                typePickerColumns: provider.typePickerColumns,
                customDropdownOptions: customOptions.isEmpty ? nil : customOptions,
                connectionId: connection.id,
                databaseType: connection.type
            ),
            delegate: gridDelegate,
            selectedRowIndices: $selectedRows,
            sortState: $sortState,
            editingCell: $editingCell,
            columnLayout: $structureColumnLayout
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                NativeSearchField(text: $searchText, placeholder: String(localized: "Filter"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                Divider()
            }
        }
    }

    // MARK: - Helper Views

    func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(Color(nsColor: .systemOrange))
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func emptyState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
