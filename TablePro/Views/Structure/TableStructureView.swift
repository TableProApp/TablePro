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

    /// Whether the clipboard holds structure rows this view can paste. Structure paste reads its
    /// own pasteboard type and nothing else, so the plain text a structure copy also writes is not
    /// enough. Menu validation and the grid delegate both ask here rather than each spelling out
    /// the same check.
    static var canPasteStructureRows: Bool {
        NSPasteboard.general.data(forType: structurePasteboardType) != nil
    }
    let tableName: String
    let connection: DatabaseConnection
    let databaseName: String
    let schemaName: String?

    /// Whether the Structure tab is open on a view rather than a table. Every reorder mechanism
    /// emits table DDL, so a view is withheld rather than allowed to fail at the statement.
    var isViewObject: Bool = false

    let toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator?
    let selectionState: GridSelectionState

    @Environment(\.appServices) var services

    /// Derived from the tab's own binding on every render so it can never go stale.
    var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: databaseName, schema: schemaName)
    }

    var structureLoader: TableStructureLoader {
        TableStructureLoader(scope: scope, tableName: tableName)
    }

    /// Everything the user has staged, plus the baseline it is staged against. Held outside this
    /// view because the view is destroyed whenever the tab is deselected or switched to Data.
    let session: StructureEditingSession

    /// Where the user was. Two tabs on one table are two editors, and a trip through the Data view
    /// must not lose the sub-tab, filter or sort either, so all of it lives on the session.
    var selectedTab: StructureTab {
        get { session.selectedTab }
        nonmutating set { session.selectedTab = newValue }
    }

    var searchText: String {
        get { session.searchText }
        nonmutating set { session.searchText = newValue }
    }

    var sortState: SortState {
        get { session.sortState }
        nonmutating set { session.sortState = newValue }
    }

    var structureSortDescriptor: StructureSortDescriptor? {
        get { session.sortDescriptor }
        nonmutating set { session.sortDescriptor = newValue }
    }

    var structureColumnLayouts: [StructureTab: ColumnLayoutState] {
        get { session.columnLayouts }
        nonmutating set { session.columnLayouts = newValue }
    }

    /// Raised across a write and across the reload that follows it, so the handlers watching
    /// `columns`, `indexes` and `foreignKeys` do not mistake either for the user editing.
    var isReloadingAfterSave: Bool {
        get { session.isApplying }
        nonmutating set { session.isApplying = newValue }
    }

    var lastSaveTime: Date? {
        get { session.lastAppliedAt }
        nonmutating set { session.lastAppliedAt = newValue }
    }

    var wrappedChangeManager: AnyChangeManager { session.wrappedChangeManager }

    var gridDelegate: StructureGridDelegate { session.gridDelegate }

    /// The loaded schema, forwarded to the session so a rebuild adopts it instead of refetching.
    /// Refetching would re-baseline `structureChangeManager` and clear the staged edits.
    var columns: [ColumnInfo] {
        get { session.columns }
        nonmutating set { session.columns = newValue }
    }

    var indexes: [IndexInfo] {
        get { session.indexes }
        nonmutating set { session.indexes = newValue }
    }

    var foreignKeys: [ForeignKeyInfo] {
        get { session.foreignKeys }
        nonmutating set { session.foreignKeys = newValue }
    }

    var checkConstraints: [CheckConstraintInfo] {
        get { session.checkConstraints }
        nonmutating set { session.checkConstraints = newValue }
    }

    var triggers: [TriggerInfo] {
        get { session.triggers }
        nonmutating set { session.triggers = newValue }
    }

    var ddlStatement: String {
        get { session.ddlStatement }
        nonmutating set { session.ddlStatement = newValue }
    }

    var tabData: StructureTabDataState {
        get { session.tabData }
        nonmutating set { session.tabData = newValue }
    }

    var structureChangeManager: StructureChangeManager { session.changeManager }

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) var ddlFontSize: Double = 13
    @State var showCopyConfirmation = false
    @State var copyResetTask: Task<Void, Never>?
    @State var isLoading = true
    @State var isInitialLoading = true
    @State var errorMessage: String?
    @State var partsReloadToken = 0
    @AppStorage("skipSchemaPreview", store: AppStorageEnvironment.shared.defaults) var skipSchemaPreview = false

    @State var displayVersion: Int = 0
    @State var selectedRows: Set<Int> = []
    @State var actionHandler = StructureViewActionHandler()

    init(
        tableName: String,
        connection: DatabaseConnection,
        databaseName: String,
        schemaName: String?,
        isViewObject: Bool = false,
        toolbarState: ConnectionToolbarState,
        coordinator: MainContentCoordinator?,
        selectionState: GridSelectionState,
        session: StructureEditingSession
    ) {
        self.tableName = tableName
        self.connection = connection
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.isViewObject = isViewObject
        self.toolbarState = toolbarState
        self.coordinator = coordinator
        self.selectionState = selectionState
        self.session = session
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(loadInitialData)
        .onChange(of: selectedRows) { _, newRows in
            selectionState.indices = newRows
            publishFooterCapability()
        }
        .onChange(of: selectedTab) { _, newValue in
            onSelectedTabChanged(newValue)
            publishFooterCapability()
        }
        .onChange(of: columns) { onColumnsChanged() }
        .onChange(of: indexes) { onIndexesChanged() }
        .onChange(of: foreignKeys) { onForeignKeysChanged() }
        .onChange(of: checkConstraints) { onCheckConstraintsChanged() }
        .onChange(of: searchText) { displayVersion += 1 }
        .onChange(of: displayVersion) { updateGridDelegate() }
        .onAppear {
            coordinator?.toolbarState.hasStructureChanges = structureChangeManager.hasChanges

            selectionState.indices = []
            coordinator?.inspectorRowSource = gridDelegate

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

            actionHandler.previewSQL = { self.generateStructurePreviewSQL() }
            actionHandler.copyRows = { self.gridDelegate.dataGridCopyRows(self.selectedRows) }
            actionHandler.pasteRows = { self.gridDelegate.dataGridPasteRows() }
            actionHandler.undo = { self.gridDelegate.dataGridUndo() }
            actionHandler.redo = { self.gridDelegate.dataGridRedo() }
            actionHandler.addRow = { self.gridDelegate.dataGridAddRow() }
            actionHandler.removeRow = { self.gridDelegate.dataGridDeleteRows(self.selectedRows) }
            actionHandler.refresh = { self.onRefreshData() }
            coordinator?.structureActions = actionHandler
            publishFooterCapability()
        }
        .onDisappear {
            /// Every clear is guarded by identity, because appearance is not lifetime: SwiftUI does
            /// not order `onDisappear` on the outgoing view before `onAppear` on the incoming one,
            /// and an unguarded clear that lands second nils the wiring the incoming structure tab
            /// has already installed. Its Save, Refresh, Preview SQL, undo and footer buttons then
            /// do nothing at all until something else re-runs `onAppear`.
            if coordinator?.structureActions === actionHandler {
                coordinator?.structureActions = nil
                coordinator?.toolbarState.hasStructureChanges = false
                selectionState.indices = []
            }
            if coordinator?.inspectorRowSource === gridDelegate {
                coordinator?.inspectorRowSource = nil
            }
        }
        .onChange(of: structureChangeManager.hasChanges) { _, newValue in
            coordinator?.toolbarState.hasStructureChanges = newValue
            updateGridDelegate()
        }
        .onChange(of: session.appliedVersion) { _, _ in
            Task { await refreshAfterApply() }
        }
        .onChange(of: structureChangeManager.reloadVersion) { _, _ in
            // Any mutation that does not toggle hasChanges (add row when changes
            // already exist, undo to a still-dirty state) only bumps reloadVersion.
            // Bump displayVersion so SwiftUI re-evaluates structureGrid with a fresh
            // tableRows snapshot, which lets DataGridView see the new row count and
            // call reloadData(). Without this, Cmd+Shift+N adds the row to the change
            // manager but the grid never displays it.
            displayVersion += 1
        }
        .onReceive(AppCommands.shared.refreshData) { request in
            guard request.connectionId == connection.id else { return }
            guard request.reaches(tabScope: scope) else { return }
            /// A close applying another tab's staged edits broadcasts a refresh for the same
            /// database. Answering it here would ask this tab whether to discard the edits the user
            /// has just asked to save, in a sheet queued behind the close.
            guard coordinator?.isApplyingStagedStructureEdits != true else { return }
            onRefreshData()
        }
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
        if !connection.type.supportsTriggers {
            tabs = tabs.filter { $0 != .triggers }
        }
        if !connection.type.supportsCheckConstraints {
            tabs = tabs.filter { $0 != .checkConstraints }
        }
        return tabs
    }

    private var toolbar: some View {
        @Bindable var session = session
        return HStack {
            Spacer()

            Picker("Structure", selection: $session.selectedTab) {
                ForEach(availableTabs, id: \.self) { tab in
                    Text(tabLabel(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .monospacedDigit()
            .accessibilityIdentifier("structure-tab-picker")

            Spacer()
        }
        .padding()
    }

    // MARK: - Footer capability

    /// Published to the tab's own session, which the bottom bar reads. Nothing is cleared on
    /// disappear: the session outlives the view by design, and the bar only reads this while the
    /// tab is showing its structure.
    private func publishFooterCapability() {
        guard connection.type.supportsSchemaEditing, let labels = footerLabels(for: selectedTab) else {
            session.footer = StructureFooterCapability()
            return
        }
        session.footer = StructureFooterCapability(
            canAdd: canAdd(for: selectedTab),
            canRemove: canRemove(for: selectedTab),
            addLabel: labels.add,
            removeLabel: labels.remove
        )
    }

    private func canAdd(for tab: StructureTab) -> Bool {
        switch tab {
        case .columns: return connection.type.supportsAddColumn
        case .indexes: return connection.type.supportsAddIndex
        case .foreignKeys: return connection.type.supportsForeignKeys
        case .checkConstraints: return connection.type.supportsCheckConstraintEditing
        case .ddl, .parts, .triggers: return false
        }
    }

    private func canRemove(for tab: StructureTab) -> Bool {
        guard !selectedRows.isEmpty else { return false }
        switch tab {
        case .columns: return connection.type.supportsDropColumn
        case .indexes: return connection.type.supportsDropIndex
        case .foreignKeys: return connection.type.supportsForeignKeys
        case .checkConstraints: return connection.type.supportsCheckConstraintEditing
        case .ddl, .parts, .triggers: return false
        }
    }

    private func footerLabels(for tab: StructureTab) -> (add: String, remove: String)? {
        switch tab {
        case .columns:
            return (String(localized: "Add Column"), String(localized: "Remove Column"))
        case .indexes:
            return (String(localized: "Add Index"), String(localized: "Remove Index"))
        case .foreignKeys:
            return (String(localized: "Add Foreign Key"), String(localized: "Remove Foreign Key"))
        case .checkConstraints:
            return (String(localized: "Add Check Constraint"), String(localized: "Remove Check Constraint"))
        case .ddl, .parts, .triggers:
            return nil
        }
    }

    // MARK: - Tab Label with Count Badge

    private func tabLabel(for tab: StructureTab) -> String {
        StructureTabDataState.label(for: tab, count: loadedCount(for: tab))
    }

    private func loadedCount(for tab: StructureTab) -> Int? {
        guard tabData.hasData(tab) else { return nil }
        switch tab {
        case .columns: return columns.count
        case .indexes: return indexes.count
        case .foreignKeys: return foreignKeys.count
        case .triggers: return triggers.count
        case .checkConstraints: return checkConstraints.count
        case .ddl, .parts: return nil
        }
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
        case .columns:
            structureGrid
        case .indexes:
            if shouldShowIndexesEmptyState {
                EmptyStateView.indexes { gridDelegate.dataGridAddRow() }
            } else {
                structureGrid
            }
        case .foreignKeys:
            if shouldShowForeignKeysEmptyState {
                EmptyStateView.foreignKeys { gridDelegate.dataGridAddRow() }
            } else {
                structureGrid
            }
        case .checkConstraints:
            if shouldShowCheckConstraintsEmptyState {
                EmptyStateView.checkConstraints { gridDelegate.dataGridAddRow() }
            } else {
                structureGrid
            }
        case .triggers:
            TriggerDetailView(
                triggers: triggers,
                scope: scope,
                connection: connection,
                tableName: tableName,
                isLoading: !tabData.hasData(.triggers),
                onOpenInEditor: openTriggerInEditor
            )
        case .ddl:
            ddlView
        case .parts:
            ClickHousePartsView(
                tableName: tableName,
                connectionId: connection.id,
                reloadToken: partsReloadToken
            )
        }
    }

    private var shouldShowIndexesEmptyState: Bool {
        tabData.hasData(.indexes)
            && structureChangeManager.workingIndexes.isEmpty
            && connection.type.supportsAddIndex
    }

    private var shouldShowForeignKeysEmptyState: Bool {
        tabData.hasData(.foreignKeys)
            && structureChangeManager.workingForeignKeys.isEmpty
            && connection.type.supportsForeignKeys
    }

    /// Only offered where the engine can actually add one. An engine that lists constraints but
    /// cannot edit them shows the grid, so a table's real constraints stay visible instead of being
    /// replaced by an empty state whose only affordance is disabled.
    private var shouldShowCheckConstraintsEmptyState: Bool {
        tabData.hasData(.checkConstraints)
            && structureChangeManager.workingCheckConstraints.isEmpty
            && connection.type.supportsCheckConstraintEditing
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

    private func columnLayoutBinding(for tab: StructureTab) -> Binding<ColumnLayoutState> {
        Binding(
            get: { session.columnLayouts[tab] ?? ColumnLayoutState() },
            set: { session.columnLayouts[tab] = $0 }
        )
    }

    func updateGridDelegate() {
        let provider = makeCurrentProvider()

        gridDelegate.selectedTab = selectedTab
        gridDelegate.currentProvider = provider
        gridDelegate.orderedFields = provider.orderedColumnFields
        coordinator?.inspectorRowSourceRevision += 1

        let availability = columnReorderAvailability
        gridDelegate.moveRowHandler = availability.isAvailable ? { [self] fromIndex, toIndex in
            beginColumnReorder(fromIndex: fromIndex, toIndex: toIndex)
        } : nil
        gridDelegate.columnReorder = DataGridRowReorder(
            isEnabled: availability.isAvailable,
            unavailableReason: availability.unavailableReason
        )
    }

    private var structureGrid: some View {
        @Bindable var session = session
        let provider = makeCurrentProvider()
        let canEdit = connection.type.supportsSchemaEditing
        let customOptions = provider.customDropdownOptions
        let allDropdownColumns = provider.dropdownColumns.union(Set(customOptions.keys))

        // Build the row snapshot fresh on every call rather than capturing it
        // once at body-evaluation time. After a cell edit / undo / redo the
        // change manager's working state is updated synchronously, but a
        // captured snapshot would still hold the pre-edit value, so the
        // `tableView.reloadData(forRowIndexes:)` issued by the delegate would
        // re-render the cell from a stale source. Mirror the data tab's pattern
        // (`MainEditorContentView` rebuilds via `coordinator.tabSessionRegistry`
        // on every call). `makeCurrentProvider` is cheap because the working
        // arrays are small (typically <100 entries).
        return DataGridView(
            tableRowsProvider: { makeCurrentProvider().asTableRows() },
            changeManager: wrappedChangeManager,
            isEditable: canEdit,
            configuration: DataGridConfiguration(
                dropdownColumns: allDropdownColumns,
                typePickerColumns: provider.typePickerColumns,
                customDropdownOptions: customOptions.isEmpty ? nil : customOptions,
                connectionId: connection.id,
                databaseType: connection.type,
                tableName: tableName,
                databaseName: databaseName,
                schemaName: schemaName,
                tabType: .table
            ),
            delegate: gridDelegate,
            rowReorder: DataGridRowReorder(
                isEnabled: columnReorderAvailability.isAvailable,
                unavailableReason: columnReorderAvailability.unavailableReason
            ),
            selectedRowIndices: $selectedRows,
            sortState: $session.sortState,
            columnLayout: columnLayoutBinding(for: selectedTab),
            contentRevision: displayVersion
        )
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                NativeSearchField(text: $session.searchText, placeholder: String(localized: "Filter"))
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
                .foregroundStyle(.orange)
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
    let connection = DatabaseConnection(
        name: "Test",
        host: "localhost",
        port: 3_306,
        database: "test",
        username: "root",
        type: .mysql
    )
    return TableStructureView(
        tableName: "users",
        connection: connection,
        databaseName: "test",
        schemaName: nil,
        toolbarState: ConnectionToolbarState(),
        coordinator: nil,
        selectionState: GridSelectionState(),
        session: StructureEditingSession(
            identity: "test.users",
            connection: connection,
            databaseName: "test",
            schemaName: nil,
            tableName: "users"
        )
    )
    .frame(width: 800, height: 600)
}
