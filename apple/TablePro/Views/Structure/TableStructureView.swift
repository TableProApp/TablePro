//
//  TableStructureView.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

struct TableStructureView: View {
    static let logger = Logger(subsystem: "com.TablePro", category: "TableStructureView")
    static let structurePasteboardType = NSPasteboard.PasteboardType("com.TablePro.structure")
    static let structureSourceTypePasteboardType = NSPasteboard.PasteboardType("com.TablePro.structure.database-type")

    static var canPasteStructureRows: Bool {
        NSPasteboard.general.data(forType: structurePasteboardType) != nil
    }
    let tableName: String
    let connection: DatabaseConnection
    let databaseName: String
    let schemaName: String?

    @ObservedObject var toolbarState: ConnectionToolbarState
    let coordinator: MainContentCoordinator?

    @Environment(\.appServices) var services

    var scope: DatabaseScope {
        DatabaseScope(
            connectionId: connection.id, database: databaseName, schema: schemaName, isSessionBound: isSessionBound
        )
    }

    var isSessionBound: Bool { session.isSessionBound }

    var structureLoader: TableStructureLoader {
        TableStructureLoader(scope: scope, tableName: tableName)
    }

    @ObservedObject var session: StructureEditingSession

    var objectKind: TableInfo.TableType { session.objectKind }

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

    var isReloadingAfterSave: Bool {
        get { session.isApplying }
        nonmutating set { session.isApplying = newValue }
    }

    var lastSaveTime: Date? {
        get { session.lastAppliedAt }
        nonmutating set { session.lastAppliedAt = newValue }
    }

    var gridAdapter: StructureGridAdapter { session.gridAdapter }

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

    // Observed on its own: a change inside it fires its publisher, never the session's.
    @ObservedObject var structureChangeManager: StructureChangeManager

    @AppStorage("structureCodeFontSize", store: AppStorageEnvironment.shared.defaults) var ddlFontSize: Double = 13
    @State var showCopyConfirmation = false
    @State var copyResetTask: Task<Void, Never>?
    @State var isLoading = true
    @State var isInitialLoading = true
    @State var errorMessage: String?
    @State var partsReloadToken = 0
    @AppStorage("skipSchemaPreview", store: AppStorageEnvironment.shared.defaults) var skipSchemaPreview = false

    @State var actionHandler = StructureViewActionHandler()
    @FocusState var isTableCommentFocused: Bool

    init(
        tableName: String,
        connection: DatabaseConnection,
        databaseName: String,
        schemaName: String?,
        toolbarState: ConnectionToolbarState,
        coordinator: MainContentCoordinator?,
        session: StructureEditingSession
    ) {
        self.tableName = tableName
        self.connection = connection
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.toolbarState = toolbarState
        self.coordinator = coordinator
        self.session = session
        self.structureChangeManager = session.changeManager
    }

    var body: some View {
        VStack(spacing: 0) {
            tableCommentBar
            tabBar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(loadInitialData)
        .onReceive(session.gridModel.$selectionRevision) { _ in
            publishFooterCapability()
        }
        .onChange(of: selectedTab) { newValue in
            onSelectedTabChanged(newValue)
            publishFooterCapability()
        }
        .onChange(of: columns) { _ in onColumnsChanged() }
        .onChange(of: indexes) { _ in onIndexesChanged() }
        .onChange(of: foreignKeys) { _ in onForeignKeysChanged() }
        .onChange(of: checkConstraints) { _ in onCheckConstraintsChanged() }
        .onChange(of: session.tableComment) { _ in onTableCommentChanged() }
        .onChange(of: session.tableOptions) { _ in onTableOptionsChanged() }
        .onChange(of: session.autoIncrementRead) { read in onAutoIncrementReadChanged(read) }
        .onChange(of: session.tableOptionsCatalog) { _ in gridAdapter.characterSetCatalogDidChange() }
        .onChange(of: isTableCommentFocused) { isFocused in
            if !isFocused { structureChangeManager.endTableCommentRun() }
        }
        .onChange(of: searchText) { _ in gridAdapter.refresh() }
        .onChange(of: session.serverSupport) { _ in gridAdapter.refresh() }
        .onAppear {
            coordinator?.toolbarState.hasStructureChanges = structureChangeManager.hasChanges
            coordinator?.inspectorRowSource = gridAdapter

            gridAdapter.coordinator = coordinator
            gridAdapter.moveRowHandler = { [self] fromIndex, toIndex in
                beginColumnReorder(fromIndex: fromIndex, toIndex: toIndex)
            }
            gridAdapter.refresh()

            actionHandler.previewSQL = { self.generateStructurePreviewSQL() }
            actionHandler.copyRows = { self.gridAdapter.copyRows(self.session.gridModel.selectedRowIDs) }
            actionHandler.pasteRows = { self.gridAdapter.pasteRows() }
            actionHandler.undo = { self.gridAdapter.undo() }
            actionHandler.redo = { self.gridAdapter.redo() }
            actionHandler.addRow = { self.gridAdapter.addRow() }
            actionHandler.removeRow = { self.gridAdapter.deleteRows(self.session.gridModel.selectedRowIDs) }
            actionHandler.refresh = { self.onRefreshData() }
            coordinator?.structureActions = actionHandler
            publishFooterCapability()
        }
        .onDisappear {
            structureChangeManager.endTableCommentRun()
            // Guarded by identity: SwiftUI does not order the outgoing view's onDisappear before the
            // incoming one's onAppear, so an unguarded clear can nil the wiring another tab installed.
            if coordinator?.structureActions === actionHandler {
                coordinator?.structureActions = nil
                coordinator?.toolbarState.hasStructureChanges = false
            }
            if coordinator?.inspectorRowSource === gridAdapter {
                coordinator?.inspectorRowSource = nil
            }
        }
        .onChange(of: structureChangeManager.hasChanges) { newValue in
            coordinator?.toolbarState.hasStructureChanges = newValue
            gridAdapter.refresh()
            if !newValue, session.settleOwedRefetch() {
                Task { await loadInitialData() }
            }
        }
        .onChange(of: structureChangeManager.isHeldForSave) { _ in
            publishFooterCapability()
            gridAdapter.refresh()
        }
        .onChange(of: session.appliedVersion) { _ in
            Task { await refreshAfterApply() }
        }
        // A mutation that leaves hasChanges as it was, such as a second added row, moves only this.
        .onChange(of: structureChangeManager.reloadVersion) { _ in
            gridAdapter.refresh()
        }
    }

    // MARK: - Tabs

    private var availableTabs: [StructureTab] {
        session.availableTabs
    }

    private var tabBar: some View {
        PaneTabBar(
            title: String(localized: "Structure"),
            selection: $session.selectedTab.committingEdit(of: session.gridModel),
            identifier: "structure-tab-picker"
        ) {
            ForEach(availableTabs, id: \.self) { tab in
                Text(tabLabel(for: tab)).tag(tab)
            }
        }
        .monospacedDigit()
        .overlay(alignment: .trailing) {
            if structureChangeManager.isHeldForSave {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving Changes…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.trailing)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("structure-save-progress")
            }
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
        case .options, .ddl, .parts: return nil
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        if let error = errorMessage {
            errorView(error)
                .gridStandInBackground()
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
            Group {
                if shouldShowIndexesEmptyState {
                    EmptyStateView.indexes { gridAdapter.addRow() }
                        .gridStandInBackground()
                } else {
                    structureGrid
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                indexesTabNotes
            }
        case .foreignKeys:
            if shouldShowForeignKeysEmptyState {
                EmptyStateView.foreignKeys { gridAdapter.addRow() }
                    .gridStandInBackground()
            } else {
                structureGrid
            }
        case .checkConstraints:
            if shouldShowCheckConstraintsEmptyState {
                EmptyStateView.checkConstraints { gridAdapter.addRow() }
                    .gridStandInBackground()
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
                canEdit: editGate.allowsTriggerEditing,
                onOpenInEditor: openTriggerInEditor
            )
        case .options:
            tableOptionsView
        case .ddl:
            ddlView
        case .parts:
            ClickHousePartsView(
                tableName: tableName,
                scope: scope,
                connection: connection,
                reloadToken: partsReloadToken
            )
        }
    }

    private var indexesTabNotes: some View {
        VStack(spacing: 0) {
            if let note = InvalidIndexNote(indexes: indexes) {
                StructureTabNoteView(
                    systemImage: note.systemImage,
                    text: note.text,
                    identifier: "structure-invalid-index-note"
                )
            }
            if objectKind == .materializedView,
               let note = MaterializedViewConcurrentRefreshNote(state: session.concurrentRefresh) {
                StructureTabNoteView(
                    systemImage: note.systemImage,
                    text: note.text,
                    identifier: "structure-concurrent-refresh-note"
                )
            }
        }
    }

    private var shouldShowIndexesEmptyState: Bool {
        tabData.hasData(.indexes)
            && structureChangeManager.workingIndexes.isEmpty
            && editGate.allows(.addIndex)
    }

    private var shouldShowForeignKeysEmptyState: Bool {
        tabData.hasData(.foreignKeys)
            && structureChangeManager.workingForeignKeys.isEmpty
            && connection.type.supportsForeignKeys
            && editGate.allows(.addForeignKey)
    }

    private var shouldShowCheckConstraintsEmptyState: Bool {
        tabData.hasData(.checkConstraints)
            && structureChangeManager.workingCheckConstraints.isEmpty
            && editGate.allows(.addCheckConstraint)
    }

    // MARK: - Structure Grid

    private var structureGrid: some View {
        DataGridView(model: session.gridModel)
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
            RevealedTextView(message)
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
