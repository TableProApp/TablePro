//
//  MainContentCommandActions.swift
//  TablePro
//
//  Provides command actions for MainContentView, accessible via @FocusedValue.
//  Menu commands and toolbar buttons call methods directly instead of posting notifications.
//  Retains NotificationCenter subscribers only for legitimate multi-listener broadcasts.
//

import AppKit
import Foundation
import Observation
import os
import SwiftUI
import TableProPluginKit

/// Provides command actions for MainContentView, accessible via @FocusedValue
@MainActor
@Observable
final class MainContentCommandActions {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCommandActions")

    // MARK: - Dependencies

    @ObservationIgnored private weak var coordinator: MainContentCoordinator?
    @ObservationIgnored private let filterStateManager: FilterStateManager
    @ObservationIgnored private let connection: DatabaseConnection

    // MARK: - Bindings

    @ObservationIgnored private let selectionState: GridSelectionState
    @ObservationIgnored private let selectedTables: Binding<Set<TableInfo>>
    @ObservationIgnored private let pendingTruncates: Binding<Set<String>>
    @ObservationIgnored private let pendingDeletes: Binding<Set<String>>
    @ObservationIgnored private let tableOperationOptions: Binding<[String: TableOperationOptions]>
    @ObservationIgnored private let rightPanelState: RightPanelState

    /// The window this instance belongs to — used for key-window guards.
    @ObservationIgnored weak var window: NSWindow?

    // MARK: - State

    /// Task handles for async notification observers; cancelled on deinit.
    @ObservationIgnored private var notificationTasks: [Task<Void, Never>] = []

    // MARK: - Initialization

    init(
        coordinator: MainContentCoordinator,
        filterStateManager: FilterStateManager,
        connection: DatabaseConnection,
        selectionState: GridSelectionState,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        rightPanelState: RightPanelState
    ) {
        self.coordinator = coordinator
        self.filterStateManager = filterStateManager
        self.connection = connection
        self.selectionState = selectionState
        self.selectedTables = selectedTables
        self.pendingTruncates = pendingTruncates
        self.pendingDeletes = pendingDeletes
        self.tableOperationOptions = tableOperationOptions
        self.rightPanelState = rightPanelState

        setupSaveAction()
        setupObservers()
    }

    deinit {
        for task in notificationTasks {
            task.cancel()
        }
    }

    // MARK: - Async Notification Helper

    /// Creates a Task that iterates an async notification sequence and calls the handler.
    /// The task is stored for cancellation on deinit.
    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        let task = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(named: name) {
                guard self != nil else { break }
                handler(notification)
            }
        }
        notificationTasks.append(task)
    }

    /// Returns true if this instance's window is the current key window.
    private func isKeyWindow() -> Bool {
        guard let window = self.window else { return false }
        return window.isKeyWindow
    }

    /// Like `observe(_:handler:)` but only runs the handler when this instance's window is key.
    private func observeKeyWindowOnly(
        _ name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        observe(name) { [weak self] notification in
            guard self?.isKeyWindow() == true else { return }
            handler(notification)
        }
    }

    // MARK: - Save Action

    private func setupSaveAction() {
        rightPanelState.onSave = { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.coordinator?.saveSidebarEdits(
                        editState: self.rightPanelState.editState
                    )
                } catch {
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Failed to Save Changes"),
                        message: error.localizedDescription,
                        window: self.window
                    )
                }
            }
        }
    }

    // MARK: - Observer Setup

    private func setupObservers() {
        setupNonMenuNotificationObservers()
        setupDataBroadcastObservers()
        setupTabBroadcastObservers()
        setupDatabaseBroadcastObservers()
        setupWindowObservers()
        setupFileOpenObservers()
    }

    /// Observers for notifications still posted by non-menu views (DataGrid, SidebarView,
    /// context menus, QueryEditorView, ConnectionStatusView). These bridge AppKit/non-menu
    /// notification posts to the same command action methods used by @FocusedValue callers.
    private func setupNonMenuNotificationObservers() {
        observeKeyWindowOnly(.addNewRow) { [weak self] _ in self?.addNewRow() }

        observeKeyWindowOnly(.deleteSelectedRows) { [weak self] notification in
            let directIndices = notification.userInfo?["rowIndices"] as? Set<Int>
            self?.deleteSelectedRows(rowIndices: directIndices)
        }

        observeKeyWindowOnly(.duplicateRow) { [weak self] _ in self?.duplicateRow() }

        observeKeyWindowOnly(.exportQueryResults) { [weak self] _ in self?.exportQueryResults() }

        // Note: .copySelectedRows and .pasteRows observers call the data-grid
        // path directly (not the public methods) to avoid an infinite loop —
        // the public methods re-post these notifications for structure view.
        observeKeyWindowOnly(.copySelectedRows) { [weak self] _ in
            guard let self else { return }
            let indices = self.selectionState.indices
            self.coordinator?.copySelectedRowsToClipboard(indices: indices)
        }

        observeKeyWindowOnly(.pasteRows) { [weak self] _ in
            self?.coordinator?.pasteRows()
        }
    }

    // MARK: - Row Operations (Group A — Called Directly)

    func addNewRow() {
        coordinator?.addNewRow()
    }

    func deleteSelectedRows(rowIndices: Set<Int>? = nil) {
        let fromDataGrid = rowIndices != nil

        let indices = rowIndices ?? selectionState.indices
        if !indices.isEmpty {
            coordinator?.deleteSelectedRows(indices: indices)
        } else if !fromDataGrid, !selectedTables.wrappedValue.isEmpty {
            // Only toggle table deletion when the call did NOT originate from
            // the data grid (e.g., from the app menu Cmd+Delete with no rows selected)
            var updatedDeletes = pendingDeletes.wrappedValue
            var updatedTruncates = pendingTruncates.wrappedValue

            for table in selectedTables.wrappedValue {
                updatedTruncates.remove(table.name)
                if updatedDeletes.contains(table.name) {
                    updatedDeletes.remove(table.name)
                } else {
                    updatedDeletes.insert(table.name)
                }
            }

            pendingTruncates.wrappedValue = updatedTruncates
            pendingDeletes.wrappedValue = updatedDeletes
        }
    }

    func duplicateRow() {
        let indices = selectionState.indices
        guard let selectedIndex = indices.first, indices.count == 1 else { return }
        coordinator?.duplicateSelectedRow(index: selectedIndex)
    }

    func copySelectedRows() {
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.copyRows?()
        } else {
            let indices = selectionState.indices
            coordinator?.copySelectedRowsToClipboard(indices: indices)
        }
    }

    func copySelectedRowsWithHeaders() {
        let indices = selectionState.indices
        coordinator?.copySelectedRowsWithHeaders(indices: indices)
    }

    func copySelectedRowsAsJson() {
        let indices = selectionState.indices
        coordinator?.copySelectedRowsAsJson(indices: indices)
    }

    func pasteRows() {
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.pasteRows?()
        } else {
            coordinator?.pasteRows()
        }
    }

    // MARK: - Per-Window State (replaces AppState.shared for menu enablement)

    var isConnected: Bool { coordinator != nil }
    var isQueryExecuting: Bool { coordinator?.toolbarState.isExecuting ?? false }

    var safeModeLevel: SafeModeLevel { connection.safeModeLevel }

    var isReadOnly: Bool { safeModeLevel.blocksAllWrites }

    var editorLanguage: EditorLanguage {
        PluginManager.shared.editorLanguage(for: connection.type)
    }

    var currentDatabaseType: DatabaseType { connection.type }

    var supportsDatabaseSwitching: Bool {
        PluginManager.shared.supportsDatabaseSwitching(for: connection.type)
    }

    var isCurrentTabEditable: Bool {
        coordinator?.tabManager.selectedTab?.tableContext.isEditable == true
    }

    var isTableTab: Bool {
        coordinator?.toolbarState.isTableTab ?? false
    }

    var hasRowSelection: Bool {
        !selectionState.indices.isEmpty
    }

    var hasTableSelection: Bool {
        !selectedTables.wrappedValue.isEmpty
    }

    var hasQueryText: Bool {
        !(coordinator?.tabManager.selectedTab?.content.query.isEmpty ?? true)
    }

    /// Whether there are pending data changes that the SQL preview can show.
    /// Mirrors the toolbar Preview SQL button's enabled condition so the
    /// menu shortcut (Cmd+Shift+P) doesn't open an empty preview popover.
    var hasDataPendingChanges: Bool {
        coordinator?.toolbarState.hasDataPendingChanges ?? false
    }

    /// Any pending changes (data edits OR file edits). Mirrors the toolbar
    /// Save Changes button's enabled condition.
    var hasPendingChanges: Bool {
        coordinator?.toolbarState.hasPendingChanges ?? false
    }

    var hasStructureChanges: Bool {
        coordinator?.toolbarState.hasStructureChanges ?? false
    }

    // MARK: - Unsaved Changes Check

    private var hasUnsavedChanges: Bool {
        let hasEditedCells = coordinator?.changeManager.hasChanges ?? false
        let hasPendingTableOps = !pendingTruncates.wrappedValue.isEmpty
            || !pendingDeletes.wrappedValue.isEmpty
        let hasSidebarEdits = rightPanelState.editState.hasEdits
        let hasFileDirty = coordinator?.tabManager.selectedTab?.content.isFileDirty ?? false
        return hasEditedCells || hasPendingTableOps || hasSidebarEdits || hasFileDirty
    }

    // MARK: - Editor Query Loading (Group A — Called Directly)

    func loadQueryIntoEditor(_ query: String) {
        coordinator?.loadQueryIntoEditor(query)
    }

    func insertQueryFromAI(_ query: String) {
        coordinator?.insertQueryFromAI(query)
    }

    // MARK: - Tab Operations (Group A — Called Directly)

    func newTab(initialQuery: String? = nil) {
        if let coordinator, coordinator.tabManager.tabs.isEmpty {
            coordinator.tabManager.addTab(
                initialQuery: initialQuery,
                databaseName: connection.database
            )
            return
        }
        let payload = EditorTabPayload(
            connectionId: connection.id,
            initialQuery: initialQuery,
            intent: .newEmptyTab
        )
        WindowManager.shared.openTab(payload: payload)
    }

    func closeTab() {
        let seq = MainContentCoordinator.nextSwitchSeq()
        Self.logger.info("[close] closeTab seq=\(seq) hasUnsavedChanges=\(self.hasUnsavedChanges)")
        if hasUnsavedChanges {
            Task {
                let keyWindow = NSApp.keyWindow
                let result = await AlertHelper.confirmSaveChanges(
                    message: String(localized: "Your changes will be lost if you don't save them."),
                    window: keyWindow
                )

                switch result {
                case .save:
                    await saveAndClose()
                case .dontSave:
                    discardAndClose()
                case .cancel:
                    break
                }
            }
        } else {
            performClose()
        }
    }

    private func performClose() {
        let t0 = Date()
        guard let window = coordinator?.contentWindow ?? NSApp.keyWindow else { return }
        let visibleTabbedWindows = (window.tabbedWindows ?? [window]).filter(\.isVisible)
        Self.logger.info("[close] performClose visibleTabs=\(visibleTabbedWindows.count) tabManagerTabs=\(self.coordinator?.tabManager.tabs.count ?? 0)")

        if visibleTabbedWindows.count > 1 {
            window.close()
        } else if coordinator?.tabManager.tabs.isEmpty == true {
            window.close()
        } else {
            if let coordinator {
                for tab in coordinator.tabManager.tabs {
                    coordinator.tableRowsStore.removeTableRows(for: tab.id)
                }
                coordinator.tabManager.tabs.removeAll()
                coordinator.tabManager.selectedTabId = nil
                coordinator.toolbarState.isTableTab = false
            }
        }
        Self.logger.info("[close] performClose done ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    private func saveAndClose() async {
        guard let coordinator = coordinator else {
            performClose()
            return
        }

        // Structure view saves via direct coordinator call
        if coordinator.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator.structureActions?.saveChanges?()
            performClose()
            return
        }

        // Data grid changes or pending table operations take priority
        let hasDataChanges = coordinator.changeManager.hasChanges
            || !pendingTruncates.wrappedValue.isEmpty
            || !pendingDeletes.wrappedValue.isEmpty
        if hasDataChanges {
            let saved = await withCheckedContinuation { continuation in
                coordinator.saveCompletionContinuation = continuation
                saveChanges()
            }
            if saved {
                performClose()
            }
            return
        }

        // Sidebar-only edits (made directly in the inspector panel)
        if rightPanelState.editState.hasEdits {
            rightPanelState.onSave?()
            performClose()
            return
        }

        // File save (query editor with source file)
        if coordinator.tabManager.selectedTab?.content.isFileDirty == true {
            saveFileToSourceURL()
            performClose()
            return
        }

        performClose()
    }

    private func saveFileToSourceURL() {
        guard let tab = coordinator?.tabManager.selectedTab,
              let url = tab.content.sourceFileURL else { return }
        let content = tab.content.query
        Task {
            do {
                try await SQLFileService.writeFile(content: content, to: url)
                if let index = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tab.id }) {
                    coordinator?.tabManager.tabs[index].content.savedFileContent = content
                }
            } catch {
                // File may have been deleted or become inaccessible
                Self.logger.error("Failed to save file: \(error.localizedDescription)")
                saveFileAs()
            }
        }
    }

    private func discardAndClose() {
        coordinator?.changeManager.clearChangesAndUndoHistory()
        pendingTruncates.wrappedValue.removeAll()
        pendingDeletes.wrappedValue.removeAll()
        rightPanelState.editState.clearEdits()
        performClose()
    }

    func copyTableNames() {
        coordinator?.sidebarViewModel?.copySelectedTableNames()
    }

    func truncateTables() {
        guard !(selectedTables.wrappedValue.isEmpty) else { return }
        coordinator?.sidebarViewModel?.batchToggleTruncate()
    }

    func createView() {
        coordinator?.createView()
    }

    func createNewTable() {
        coordinator?.createNewTable()
    }

    func showERDiagram() {
        coordinator?.showERDiagram()
    }

    func showServerDashboard() {
        coordinator?.showServerDashboard()
    }

    func openTerminal() {
        coordinator?.openTerminal()
    }

    var supportsServerDashboard: Bool {
        guard let type = coordinator?.connection.type else { return false }
        return ServerDashboardQueryProviderFactory.provider(for: type) != nil
    }

    // MARK: - Tab Navigation (Group A — Called Directly)

    func selectTab(number: Int) {
        guard let keyWindow = NSApp.keyWindow,
              let tabbedWindows = keyWindow.tabbedWindows,
              tabbedWindows.indices.contains(number - 1) else { return }
        let target = tabbedWindows[number - 1]
        target.makeKeyAndOrderFront(nil)
    }

    // MARK: - Filter Operations (Group A — Called Directly)

    func toggleFilterPanel() {
        guard let coordinator = coordinator,
              coordinator.tabManager.selectedTab?.tabType == .table else { return }
        filterStateManager.toggle()
    }

    // MARK: - Data Operations (Group A — Called Directly)

    func saveChanges() {
        // Check if we're in structure view mode
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.saveChanges?()
        } else if coordinator?.changeManager.hasChanges == true
            || !pendingTruncates.wrappedValue.isEmpty
            || !pendingDeletes.wrappedValue.isEmpty {
            // Handle data grid changes (prioritize over sidebar edits since
            // data grid edits are synced to sidebar editState, and the data grid
            // path uses the correct plugin driver for statement generation)
            var truncates = pendingTruncates.wrappedValue
            var deletes = pendingDeletes.wrappedValue
            var options = tableOperationOptions.wrappedValue
            coordinator?.saveChanges(
                pendingTruncates: &truncates,
                pendingDeletes: &deletes,
                tableOperationOptions: &options
            )
            pendingTruncates.wrappedValue = truncates
            pendingDeletes.wrappedValue = deletes
            tableOperationOptions.wrappedValue = options
        } else if rightPanelState.editState.hasEdits {
            // Save sidebar-only edits (edits made directly in the right panel)
            rightPanelState.onSave?()
        }
        // File save: write query back to source file
        else if let tab = coordinator?.tabManager.selectedTab,
                tab.content.sourceFileURL != nil, tab.content.isFileDirty {
            saveFileToSourceURL()
        }
        // Save As: untitled query tab with content
        else if let tab = coordinator?.tabManager.selectedTab,
                tab.tabType == .query, tab.content.sourceFileURL == nil,
                !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            saveFileAs()
        }
    }

    func saveFileAs() {
        guard let tab = coordinator?.tabManager.selectedTab,
              tab.tabType == .query else { return }
        let content = tab.content.query
        let suggestedName = tab.content.sourceFileURL?.lastPathComponent ?? "\(tab.title).sql"
        Task {
            guard let url = await SQLFileService.showSavePanel(suggestedName: suggestedName) else { return }
            do {
                try await SQLFileService.writeFile(content: content, to: url)
                if let index = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tab.id }) {
                    coordinator?.tabManager.tabs[index].content.sourceFileURL = url
                    coordinator?.tabManager.tabs[index].content.savedFileContent = content
                    coordinator?.tabManager.tabs[index].title = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                Self.logger.error("Failed to save file: \(error.localizedDescription)")
            }
        }
    }

    func openSQLFile() {
        Task {
            guard let urls = await SQLFileService.showOpenPanel() else { return }
            NotificationCenter.default.post(name: .openSQLFiles, object: urls)
        }
    }

    func explainQuery() {
        coordinator?.runExplainQuery()
    }

    func aiExplainQuery() {
        guard let query = coordinator?.tabManager.selectedTab?.content.query, !query.isEmpty else { return }
        coordinator?.showAIChatPanel()
        coordinator?.aiViewModel?.handleExplainSelection(query)
    }

    func aiOptimizeQuery() {
        guard let query = coordinator?.tabManager.selectedTab?.content.query, !query.isEmpty else { return }
        coordinator?.showAIChatPanel()
        coordinator?.aiViewModel?.handleOptimizeSelection(query)
    }

    func previewFKReference() {
        coordinator?.toggleFKPreviewForFocusedCell()
    }

    func exportTables() {
        coordinator?.openExportDialog()
    }

    func exportQueryResults() {
        coordinator?.openExportQueryResultsDialog()
    }

    func importTables() {
        coordinator?.openImportDialog()
    }

    func saveAsFavorite() {
        coordinator?.saveCurrentQueryAsFavorite()
    }

    var canSaveAsFavorite: Bool {
        guard let tab = coordinator?.tabManager.selectedTab else { return false }
        return tab.tabType == .query && !tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func previewSQL() {
        coordinator?.handlePreviewSQL(
            pendingTruncates: pendingTruncates.wrappedValue,
            pendingDeletes: pendingDeletes.wrappedValue,
            tableOperationOptions: tableOperationOptions.wrappedValue
        )
    }

    func runQuery() {
        coordinator?.runQuery()
    }

    func runAllStatements() {
        coordinator?.runAllStatements()
    }

    func cancelCurrentQuery() {
        coordinator?.cancelCurrentQuery()
    }

    func formatQuery() {
        guard let coordinator,
              let (tab, tabIndex) = coordinator.tabManager.selectedTabAndIndex else { return }
        let dbType = connection.type
        let formatter = SQLFormatterService()
        let options = SQLFormatterOptions.default

        do {
            let result = try formatter.format(
                tab.content.query,
                dialect: dbType,
                cursorOffset: 0,
                options: options
            )
            coordinator.tabManager.tabs[tabIndex].content.query = result.formattedSQL
        } catch {
            Self.logger.error("SQL Formatting error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UI Operations (Group A — Called Directly)

    func toggleHistoryPanel() {
        coordinator?.toolbarState.isHistoryPanelVisible.toggle()
    }

    func toggleRightSidebar() {
        coordinator?.inspectorProxy?.toggleInspector()
    }

    func toggleResults() {
        guard let coordinator,
              let (_, tabIndex) = coordinator.tabManager.selectedTabAndIndex else { return }
        coordinator.tabManager.tabs[tabIndex].display.isResultsCollapsed.toggle()
        coordinator.toolbarState.isResultsCollapsed = coordinator.tabManager.tabs[tabIndex].display.isResultsCollapsed
    }

    func previousResultTab() {
        guard let coordinator,
              let (tab, _) = coordinator.tabManager.selectedTabAndIndex else { return }
        guard tab.display.resultSets.count > 1,
              let currentId = tab.display.activeResultSetId ?? tab.display.resultSets.last?.id,
              let currentIndex = tab.display.resultSets.firstIndex(where: { $0.id == currentId }),
              currentIndex > 0 else { return }
        coordinator.switchActiveResultSet(to: tab.display.resultSets[currentIndex - 1].id, in: tab.id)
    }

    func nextResultTab() {
        guard let coordinator,
              let (tab, _) = coordinator.tabManager.selectedTabAndIndex else { return }
        guard tab.display.resultSets.count > 1,
              let currentId = tab.display.activeResultSetId ?? tab.display.resultSets.last?.id,
              let currentIndex = tab.display.resultSets.firstIndex(where: { $0.id == currentId }),
              currentIndex < tab.display.resultSets.count - 1 else { return }
        coordinator.switchActiveResultSet(to: tab.display.resultSets[currentIndex + 1].id, in: tab.id)
    }

    func closeResultTab() {
        guard let coordinator else { return }
        let tab = coordinator.tabManager.selectedTab
        guard let activeId = tab?.display.activeResultSetId ?? tab?.display.resultSets.last?.id else { return }
        coordinator.closeResultSet(id: activeId)
    }

    // MARK: - Database Operations (Group A — Called Directly)

    func openDatabaseSwitcher() {
        coordinator?.activeSheet = .databaseSwitcher
    }

    func openQuickSwitcher() {
        coordinator?.activeSheet = .quickSwitcher
    }

    func openConnectionSwitcher() {
        coordinator?.toolbarState.showConnectionSwitcher = true
    }

    // MARK: - Undo/Redo (Group A — Called Directly)

    func undoChange() {
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.undo?()
        } else {
            coordinator?.contentWindow?.undoManager?.undo()
        }
    }

    func redoChange() {
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.redo?()
        } else {
            coordinator?.contentWindow?.undoManager?.redo()
        }
    }

    // MARK: - Group B Broadcast Subscribers

    // MARK: Data Broadcasts

    private func setupDataBroadcastObservers() {
        observeKeyWindowOnly(.refreshData) { [weak self] _ in self?.handleRefreshData() }
    }

    private func handleRefreshData() {
        let hasPendingTableOps = !pendingTruncates.wrappedValue.isEmpty || !pendingDeletes.wrappedValue.isEmpty
        coordinator?.handleRefresh(
            hasPendingTableOps: hasPendingTableOps,
            onDiscard: { [weak self] in
                self?.pendingTruncates.wrappedValue.removeAll()
                self?.pendingDeletes.wrappedValue.removeAll()
            }
        )
        if let coordinator {
            Task { await coordinator.refreshTables() }
        }
    }

    // MARK: Tab Broadcasts

    private func setupTabBroadcastObservers() {
        // All tab notifications (newQueryTab, loadQueryIntoEditor, insertQueryFromAI)
        // have been replaced with direct method calls via @FocusedValue.
    }

    // MARK: Database Broadcasts

    private func setupDatabaseBroadcastObservers() {
        observe(.databaseDidConnect) { [weak self] _ in self?.handleDatabaseDidConnect() }
    }

    private func handleDatabaseDidConnect() {
        Task {
            if let driver = DatabaseManager.shared.driver(for: self.connection.id) {
                coordinator?.toolbarState.databaseVersion = driver.serverVersion
            }
            if case .loading = SchemaService.shared.state(for: self.connection.id) {
                coordinator?.initRedisKeyTreeIfNeeded()
                return
            }
            await coordinator?.refreshTables()
            coordinator?.initRedisKeyTreeIfNeeded()
        }
    }

    // MARK: Window Broadcasts

    private func setupWindowObservers() {
        observe(.mainWindowWillClose) { [weak self] _ in
            guard let coordinator = self?.coordinator else { return }
            coordinator.persistence.saveNow(
                tabs: coordinator.tabManager.tabs,
                selectedTabId: coordinator.tabManager.selectedTabId
            )
        }
    }

    // MARK: File Open Broadcasts

    private func setupFileOpenObservers() {
        observeKeyWindowOnly(.openSQLFiles) { [weak self] notification in
            self?.handleOpenSQLFiles(notification)
        }
    }

    private func handleOpenSQLFiles(_ notification: Notification) {
        guard let urls = notification.object as? [URL] else { return }
        Task {
            for url in urls {
                try? await TabRouter.shared.route(.openSQLFile(url))
            }
        }
    }
}

// MARK: - Focused Value Key

private struct CommandActionsKey: FocusedValueKey {
    typealias Value = MainContentCommandActions
}

extension FocusedValues {
    var commandActions: MainContentCommandActions? {
        get { self[CommandActionsKey.self] }
        set { self[CommandActionsKey.self] = newValue }
    }
}
