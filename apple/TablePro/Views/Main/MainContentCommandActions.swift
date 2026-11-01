//
//  MainContentCommandActions.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import SwiftUI
import TableProPluginKit
import TableProSQLGrammar
import TableProUtilities
import UniformTypeIdentifiers

// Menu and toolbar commands call methods directly; NotificationCenter stays only for multi-listener broadcasts.
@MainActor
final class MainContentCommandActions: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCommandActions")

    enum WindowCloseOutcome {
        case closed
        case cancelled
    }

    // MARK: - Dependencies

    internal weak var coordinator: MainContentCoordinator?
    private let connection: DatabaseConnection
    internal var chooseSaveURL: @MainActor (String) async -> URL? = { suggestedName in
        await SQLFileService.showSavePanel(suggestedName: suggestedName)
    }

    // MARK: - Bindings

    private let selectedTables: Binding<Set<DatabaseTreeTableRef>>
    private let pendingTruncates: Binding<Set<DatabaseTreeTableRef>>
    private let pendingDeletes: Binding<Set<DatabaseTreeTableRef>>
    private let tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>
    private let trailingPaneState: TrailingPaneState

    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            updateTextInputFocusTracking()
        }
    }

    // MARK: - State

    // Stored, not computed: NSWindow.firstResponder publishes no change, so Observation could not wake the menu.
    @Published var focusOwnsTextInput = false

    let textInputFocusObserver = OSAllocatedUnfairLock<(any NSObjectProtocol)?>(uncheckedState: nil)

    var isTextInputFocusCheckScheduled = false

    // A var so a test can script the answer instead of showing the alert.
    var confirmSaveChanges: (String, NSWindow?) async -> AlertHelper.SaveConfirmationResult = { message, window in
        await AlertHelper.confirmSaveChanges(message: message, window: window)
    }

    private var notificationTasks: [Task<Void, Never>] = []

    private var eventCancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    init(
        coordinator: MainContentCoordinator,
        connection: DatabaseConnection,
        selectedTables: Binding<Set<DatabaseTreeTableRef>>,
        pendingTruncates: Binding<Set<DatabaseTreeTableRef>>,
        pendingDeletes: Binding<Set<DatabaseTreeTableRef>>,
        tableOperationOptions: Binding<[DatabaseTreeTableRef: TableOperationOptions]>,
        trailingPaneState: TrailingPaneState
    ) {
        self.coordinator = coordinator
        self.connection = connection
        self.selectedTables = selectedTables
        self.pendingTruncates = pendingTruncates
        self.pendingDeletes = pendingDeletes
        self.tableOperationOptions = tableOperationOptions
        self.trailingPaneState = trailingPaneState

        setupObservers()
    }

    deinit {
        for task in notificationTasks {
            task.cancel()
        }
        if let observer = textInputFocusObserver.withLockUnchecked({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Async Notification Helper

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

    // Key window alone is not enough: every connection shares it, so a broadcast opened a file in all of them.
    private func isVisibleInKeyWindow() -> Bool {
        guard let window = self.window, window.isKeyWindow else { return false }
        guard let host = window.contentViewController as? MainSplitViewController else { return true }
        return host.workspaces.selected?.sessionState?.coordinator === coordinator
    }

    private func observeKeyWindowOnly(
        _ name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        observe(name) { [weak self] notification in
            guard self?.isVisibleInKeyWindow() == true else { return }
            handler(notification)
        }
    }

    private func observeKeyWindowOnly<Payload>(
        _ publisher: PassthroughSubject<Payload, Never>,
        handler: @escaping @MainActor (Payload) -> Void
    ) {
        KeyWindowCommandSubscription
            .sink(publisher, when: { [weak self] in self?.isVisibleInKeyWindow() == true }, perform: handler)
            .store(in: &eventCancellables)
    }

    // MARK: - Save Action

    private func saveInspectorEdits() {
        Task { [weak self] in
            await self?.saveInspectorEditsAwaiting()
        }
    }

    // A close waits on this: started and left, the write could land after the window it reports to closed.
    @discardableResult
    private func saveInspectorEditsAwaiting() async -> Bool {
        let editState = trailingPaneState.inspector.editState
        do {
            try await coordinator?.saveSidebarEdits(editState: editState)
            return true
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Failed to Save Changes"),
                message: error.localizedDescription,
                window: window
            )
            return false
        }
    }

    // MARK: - Observer Setup

    private func setupObservers() {
        setupNonMenuNotificationObservers()
        setupDataBroadcastObservers()
        setupDatabaseBroadcastObservers()
        setupWindowObservers()
        setupFileOpenObservers()
    }

    private func setupNonMenuNotificationObservers() {
        observeKeyWindowOnly(AppCommands.shared.exportQueryResults) { [weak self] _ in self?.exportQueryResults() }
    }

    // MARK: - Row Operations (Group A: Called Directly)

    func addNewRow() {
        switch selectionOwner {
        case .schemaGrid: addSchemaRow()
        case .dataGrid: coordinator?.addNewRow()
        case .none: break
        }
    }

    // The rows the data grid's model has selected, in display order; empty when another grid owns the selection.
    private var selectedDataRowIDs: [RowID] {
        guard dataGridOwnsSelection else { return [] }
        return coordinator?.activeGridModel?.selectedRowIDs ?? []
    }

    // A structure grid with no session or draft behind it takes no commands; claiming it would shadow sidebar delete.
    var selectionOwner: GridSelectionOwner {
        let owner = GridSelectionOwner.resolve(
            tabType: coordinator?.tabManager.selectedTab?.tabType,
            resultsViewMode: coordinator?.tabManager.selectedTab?.display.resultsViewMode
        )
        guard owner == .schemaGrid, coordinator?.activeStructureEditor == nil else { return owner }
        return .none
    }

    private var dataGridOwnsSelection: Bool { selectionOwner == .dataGrid }

    // The one data-grid row a single-row command acts on, or nil when the selection holds other than one row.
    var singleSelectedDataGridRowID: RowID? {
        let rowIDs = selectedDataRowIDs
        guard rowIDs.count == 1 else { return nil }
        return rowIDs.first
    }

    func deleteSelectedRows() {
        // A selected definition that cannot be removed refuses here; Delete never reaches the sidebar's tables.
        if selectsSchemaDefinition {
            removeSchemaRows()
            return
        }

        let rowIDs = selectedDataRowIDs
        if !rowIDs.isEmpty {
            coordinator?.deleteRows(rowIDs)
        } else if !selectedTables.wrappedValue.isEmpty {
            // Through the sidebar's own path, which asks before it queues a drop.
            coordinator?.sidebarViewModel?.batchToggleDelete(refs: Array(selectedTables.wrappedValue))
        }
    }

    func duplicateRow() {
        if selectionOwner == .schemaGrid {
            duplicateSchemaRows()
            return
        }
        guard let rowID = singleSelectedDataGridRowID else { return }
        coordinator?.duplicateRow(rowID)
    }

    func copySelectedRows() {
        switch selectionOwner {
        case .schemaGrid: copySchemaRows()
        case .dataGrid: coordinator?.copyRowsToClipboard(selectedDataRowIDs)
        case .none: break
        }
    }

    func copySelectedRowsWithHeaders() {
        guard dataGridOwnsSelection else { return }
        coordinator?.copyRowsToClipboard(selectedDataRowIDs, includeHeaders: true)
    }

    func copySelectedRowsAsJson() {
        guard dataGridOwnsSelection else { return }
        coordinator?.copyRowsAsJson(selectedDataRowIDs)
    }

    func pasteRows() {
        switch selectionOwner {
        case .schemaGrid: pasteSchemaRows()
        case .dataGrid: coordinator?.pasteRows()
        case .none: break
        }
    }

    // MARK: - Per-Window State (replaces AppState.shared for menu enablement)

    // Only the window's ConnectionWindowPhase knows; this object outlives a lost session so a reconnect can restore tabs.
    var isConnected: Bool { coordinator?.splitViewController?.isConnected ?? false }
    var isQueryExecuting: Bool { coordinator?.isSelectedTabBusy ?? false }
    // Not isQueryExecuting: Cmd+. has to dim while a batch commits, which nothing can interrupt.
    var isQueryStoppable: Bool { coordinator?.isSelectedTabStoppable ?? false }

    var safeModeLevel: SafeModeLevel { coordinator?.toolbarState.safeModeLevel ?? connection.safeModeLevel }

    var isReadOnly: Bool { safeModeLevel.blocksAllWrites }

    var canNavigatePages: Bool {
        PluginManager.shared.paginationCapability(for: connection.type).allowsSeeking
    }

    var editorLanguage: EditorLanguage {
        PluginManager.shared.editorLanguage(for: connection.type)
    }

    var currentDatabaseType: DatabaseType { connection.type }

    var connectionId: UUID { connection.id }

    // With no tab, Close ends the connection, and the menu has to say so.
    var hasOpenTab: Bool { coordinator?.tabManager.selectedTab != nil }

    var browseDatabaseName: String { coordinator?.browseDatabaseName ?? "" }

    var openTabCount: Int { coordinator?.tabManager.visibleTabs.count ?? 0 }

    var supportsContainerSwitching: Bool {
        PluginManager.shared.supportsContainerSwitching(for: connection.type)
    }

    var canFavoriteActiveDatabase: Bool {
        PluginManager.shared.containerSwitchTarget(for: connection.type) == .database
            && !browseDatabaseName.isEmpty
    }

    var activeDatabaseFavoriteEnvironment: FavoriteDatabaseEnvironment? {
        guard canFavoriteActiveDatabase else { return nil }
        return FavoriteDatabasesStorage.shared
            .favorites(for: connection.id)
            .first { $0.database == browseDatabaseName }?
            .environment
    }

    func setActiveDatabaseFavorite(environment: FavoriteDatabaseEnvironment) {
        guard canFavoriteActiveDatabase else { return }
        FavoriteDatabasesStorage.shared.setFavorite(
            database: browseDatabaseName,
            environment: environment,
            connectionId: connection.id
        )
    }

    func removeActiveDatabaseFavorite() {
        guard canFavoriteActiveDatabase else { return }
        FavoriteDatabasesStorage.shared.removeFavorite(
            database: browseDatabaseName,
            connectionId: connection.id
        )
    }

    // Whole localized titles, not a format: System Settings binds an App Shortcut to a menu item's exact title.
    func containerSwitchTitle(schema: String, database: String) -> String {
        switch PluginManager.shared.containerSwitchTarget(for: currentDatabaseType) {
        case .schema: return schema
        case .database, .none: return database
        }
    }

    var openContainerSwitcherTitle: String {
        containerSwitchTitle(
            schema: String(localized: "Open Schema…"),
            database: String(localized: "Open Database…")
        )
    }

    var canSwitchSidebarLayout: Bool {
        PluginManager.shared.supportsDatabaseTree(for: connection.type)
    }

    // Reads what loadSessionContexts fetched: Snowflake (the only one today) pays two round trips for the list.
    var hasSessionContexts: Bool {
        !(coordinator?.sessionContexts.isEmpty ?? true)
    }

    var supportsSchemaSwitching: Bool {
        PluginManager.shared.supportsSchemaSwitching(for: connection.type)
    }

    // Same rule the tree layout is gated on.
    var canFilterDatabases: Bool {
        PluginManager.shared.supportsDatabaseTree(for: connection.type)
            && sidebarLayout == .tree
    }

    // Same check as the sidebar banner: no Show All Databases for a filter naming only hidden system databases.
    var hasDatabaseFilter: Bool {
        DatabaseTreeVisibility.isFiltering(
            selected: SharedSidebarState.forConnection(connection.id).databaseFilterSelected,
            databases: DatabaseTreeMetadataService.shared.databases(for: connection.id),
            showsSystem: AppSettingsManager.shared.general.showSystemContainers
        )
    }

    // Not gated on layout: search, Open Quickly and the pickers follow the filter even where the sidebar shows one schema.
    var canFilterSchemas: Bool {
        DatabaseTreeMetadataService.listsTablesPerSchema(PluginManager.shared.databaseGroupingStrategy(for: connection.type))
    }

    var hasSchemaFilter: Bool {
        SidebarSchemaFilter().keptSchemas(connectionId: connection.id, database: browseDatabaseName) != nil
    }

    var sidebarLayout: SidebarLayout {
        SharedSidebarState.forConnection(connection.id).sidebarLayout
    }

    func setSidebarLayout(_ layout: SidebarLayout) {
        SharedSidebarState.forConnection(connection.id).sidebarLayout = layout
    }

    // Not the data tab's state in Structure: Add Row there used to light from the rows' editability.
    var isCurrentTabEditable: Bool {
        guard let coordinator, coordinator.tabManager.selectedTab != nil else { return false }
        switch selectionOwner {
        case .schemaGrid: return canAddSchemaRow || canRemoveSchemaRows
        case .dataGrid: return coordinator.canEditActiveResult
        case .none: return false
        }
    }

    // Add and Duplicate Row gate on this; a structure grid adds only where its section allows it.
    var isCurrentTabSchemaResolved: Bool {
        guard let coordinator, let tabId = coordinator.tabManager.selectedTabId else { return false }
        if selectionOwner == .schemaGrid { return canAddSchemaRow }
        return coordinator.tabSessionRegistry.tableRows(for: tabId).hasAuthoritativeSchema
    }

    var canRestorePreviousValues: Bool {
        coordinator?.canRewindSelectedTab ?? false
    }


    // Chart mode has no result grid, and Structure's grid has its own commands.
    var canUseTableResultCommands: Bool {
        guard coordinator?.toolbarState.isTableTab == true,
              let viewMode = coordinator?.tabManager.selectedTab?.display.resultsViewMode
        else {
            return false
        }
        return viewMode.showsRowFilters
    }

    // A query result's grid finds as a table's does; only a mounted grid has a bar to show.
    var canUseGridFindCommands: Bool {
        guard let coordinator, let tab = coordinator.tabManager.selectedTab,
              tab.tabType == .table || tab.tabType == .query,
              tab.display.resultsViewMode.showsFindBar else { return false }
        return coordinator.hasMountedDataGrid
    }

    var hasActiveGridFind: Bool {
        canUseGridFindCommands && coordinator?.findCoordinator.hasActiveFind == true
    }

    var canJumpToColumn: Bool {
        guard dataGridOwnsSelection,
              let coordinator,
              coordinator.hasMountedDataGrid,
              let tab = coordinator.tabManager.selectedTab,
              tab.display.resultsViewMode == .data else { return false }
        let resultColumns = coordinator.tabSessionRegistry.existingTableRows(for: tab.id)?.columns ?? []
        return !coordinator.columnsForVisibilityPicker(for: tab, resultColumns: resultColumns).isEmpty
    }

    // Mirrors pasteRows(): an item enabled over a handler that bails at its first guard swallows Command+V silently.
    var canPasteRows: Bool {
        guard !safeModeLevel.blocksAllWrites, let tab = coordinator?.tabManager.selectedTab else {
            return false
        }
        switch selectionOwner {
        case .schemaGrid:
            return canPasteSchemaRows
        case .dataGrid:
            return tab.tabType == .table && isCurrentTabEditable && isCurrentTabSchemaResolved
                && ClipboardService.shared.hasText
        case .none:
            return false
        }
    }

    // Save As and Export Results gate on this, not isConnected, which left them lit over a handler that did nothing.
    var isQueryTab: Bool {
        coordinator?.tabManager.selectedTab?.tabType == .query
    }

    var hasResultRows: Bool {
        guard let coordinator, let tab = coordinator.tabManager.selectedTab else { return false }
        return !coordinator.tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty
    }

    var hasRowSelection: Bool {
        selectionOwner != .none && coordinator?.activeGridModel?.selection.isEmpty == false
    }

    // Structure grid indices are not result rows; copy with headers or as JSON would read the wrong rows.
    var hasDataGridRowSelection: Bool {
        !selectedDataRowIDs.isEmpty
    }

    var hasTableSelection: Bool {
        !selectedTables.wrappedValue.isEmpty
    }

    var canBuildJoinQuery: Bool {
        isConnected && coordinator?.canBuildJoinQuery == true
    }

    func buildJoinQuery() {
        coordinator?.openJoinBuilder(seededWith: selectedTables.wrappedValue)
    }

    // Not hasTableSelection, which let the menu bar stage a TRUNCATE on a view.
    var canTruncateSelectedTables: Bool {
        TableOperationEligibility.canTruncate(
            selectedTables.wrappedValue, context: tableOperationEligibility
        )
    }

    // Same check as the sidebar's Delete item, which the menu bar used to skip on engines with no statement for it.
    var canDropSelectedTables: Bool {
        guard !selectsSchemaDefinition else { return false }
        return TableOperationEligibility.canDrop(selectedTables.wrappedValue, context: tableOperationEligibility)
    }

    private var selectsSchemaDefinition: Bool {
        selectionOwner == .schemaGrid && coordinator?.activeStructureEditor?.focusedSection != nil
    }

    private var tableOperationEligibility: TableOperationEligibility.Context {
        guard let coordinator,
              let adapter = DatabaseManager.shared.driver(for: coordinator.connectionId) as? PluginDriverAdapter
        else { return .unavailable }
        return adapter.tableOperationEligibility(
            for: selectedTables.wrappedValue,
            isReadOnly: coordinator.safeModeLevel.blocksAllWrites
        )
    }

    // Use over TableInfo, which names no database, so commands reach the selection while the browser points elsewhere.
    var selectedObjectRef: DatabaseTreeTableRef? {
        let selection = selectedTables.wrappedValue
        guard selection.count == 1 else { return nil }
        return selection.first
    }

    var selectedObject: TableInfo? {
        selectedObjectRef?.table
    }

    var hasQueryText: Bool {
        coordinator?.tabManager.selectedTab?.hasQueryText ?? false
    }

    // Mirrors the toolbar Preview SQL button so Cmd+Shift+P never opens an empty preview popover.
    var hasDataPendingChanges: Bool {
        coordinator?.toolbarState.hasDataPendingChanges ?? false
    }

    // Mirrors the toolbar Save Changes button's enabled condition.
    var hasPendingChanges: Bool {
        coordinator?.toolbarState.hasPendingChanges ?? false
    }

    var hasOpenGridEdit: Bool {
        coordinator?.isEditingActiveGrid == true
    }

    // MARK: - Unsaved Changes Check

    // Every connection in the window: closing it closes them all, and skipping a background one is silent data loss.
    internal var hasUnsavedWorkInWindow: Bool {
        guard let host = window?.contentViewController as? MainSplitViewController else {
            return coordinator?.hasAnyUnsavedWork() ?? false
        }
        return host.workspaces.workspaces.contains { workspace in
            workspace.sessionState?.coordinator.hasAnyUnsavedWork() == true
        }
    }

    // This connection only: closing its tabs leaves another connection's pending work alone.
    internal var hasUnsavedWorkInConnection: Bool {
        coordinator?.hasAnyUnsavedWork() ?? false
    }

    internal var isUsersRolesTab: Bool {
        coordinator?.tabManager.selectedTab?.tabType == .usersRoles
    }

    var undoMenuTitle: String {
        guard isUsersRolesTab, let actions = coordinator?.usersRolesActions, actions.canUndo() else {
            return String(localized: "Undo")
        }
        return actions.undoMenuTitle()
    }

    var redoMenuTitle: String {
        guard isUsersRolesTab, let actions = coordinator?.usersRolesActions, actions.canRedo() else {
            return String(localized: "Redo")
        }
        return actions.redoMenuTitle()
    }

    // MARK: - Editor Query Loading (Group A: Called Directly)

    func loadQueryIntoEditor(_ query: String) {
        coordinator?.loadQueryIntoEditor(query)
    }

    func insertQueryFromAI(_ query: String) {
        coordinator?.insertQueryFromAI(query)
    }

    func applyAISuggestion(_ afterSQL: String, replacing beforeSQL: String, source: QueryEditorAnchor?) {
        coordinator?.applyAISuggestion(afterSQL, replacing: beforeSQL, source: source)
    }

    // MARK: - Tab Operations (Group A: Called Directly)

    func newTab(initialQuery: String? = nil) {
        guard let coordinator else { return }
        coordinator.tabManager.addTab(
            initialQuery: initialQuery,
            databaseName: coordinator.newTabDatabaseName,
            claimFocus: true
        )
    }

    // The last tab leaves the connection on its empty state; closing the window would take other connections' tabs too.
    func closeTab(id: UUID) {
        Task { await closeTabAwaiting(id: id) }
    }

    // Asks before closing unsaved work (HIG); like NSDocument, the tab stays open when the save leaves work unsaved.
    func closeTabAwaiting(id: UUID) async {
        guard let coordinator,
              let tab = coordinator.tabManager.tabs.first(where: { $0.id == id }) else { return }
        // An open cell editor is unsaved work too, so it lands before the question is asked.
        if coordinator.tabManager.selectedTabId == id {
            coordinator.commitActiveGridEdit()
        }
        guard coordinator.hasUnsavedWork(in: tab) else {
            coordinator.closeTabsByUser(ids: [id])
            return
        }
        guard coordinator.tabClosesInFlight.insert(id).inserted else { return }
        defer { coordinator.tabClosesInFlight.remove(id) }

        let previousSelection = coordinator.tabManager.selectedTabId
        revealTab(id)

        switch await confirmSaveChanges(
            String(localized: "Your changes will be lost if you don't save them."),
            closeAnchorWindow
        ) {
        case .save:
            guard await saveSelectedTabWork() else { return }
            closeRevealedTab(id, returningTo: previousSelection)
        case .dontSave:
            closeRevealedTab(id, returningTo: previousSelection)
        case .cancel:
            guard coordinator.tabManager.selectedTabId == id else { return }
            restoreSelection(previousSelection)
        }
    }

    // A save can wait on the server; a tab the user picked meanwhile is a newer choice than the one this close set aside.
    private func closeRevealedTab(_ id: UUID, returningTo previousSelection: UUID?) {
        guard let coordinator else { return }
        let stillShowsClosingTab = coordinator.tabManager.selectedTabId == id
        coordinator.closeTabsByUser(ids: [id])
        guard stillShowsClosingTab else { return }
        restoreSelection(previousSelection)
    }

    // Save and discard read the selected tab, and the user should see the work the alert asks about.
    private func revealTab(_ id: UUID) {
        guard let coordinator, coordinator.tabManager.selectedTabId != id else { return }
        coordinator.tabManager.selectedTabId = id
    }

    // The selection moved only for the alert; a closed front tab lands on its neighbour since the tab to restore is gone.
    private func restoreSelection(_ id: UUID?) {
        guard let coordinator,
              let id,
              coordinator.tabManager.selectedTabId != id,
              coordinator.tabManager.tabs.contains(where: { $0.id == id }) else { return }
        coordinator.tabManager.selectedTabId = id
    }

    func closeTab() {
        guard let coordinator else {
            Task { await closeWindowAwaiting() }
            return
        }
        if let selected = coordinator.tabManager.selectedTab {
            closeTab(id: selected.id)
            return
        }
        closeWorkspace()
    }

    // asBatchSurvivor: nil for a lone close (the window decides), true for the window a batch keeps blank, false otherwise.
    @discardableResult
    func closeWindowAwaiting(asBatchSurvivor: Bool? = nil) async -> WindowCloseOutcome {
        let seq = MainContentCoordinator.nextSwitchSeq()
        coordinator?.commitActiveGridEdit()
        Self.logger.info("[close] closeWindowAwaiting seq=\(seq) hasUnsavedWork=\(self.hasUnsavedWorkInWindow)")

        guard hasUnsavedWorkInWindow else {
            finish(asBatchSurvivor: asBatchSurvivor)
            return .closed
        }

        selectInTabGroup()
        let result = await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: closeAnchorWindow
        )

        switch result {
        case .save:
            return await saveAndClose(asBatchSurvivor: asBatchSurvivor) ? .closed : .cancelled
        case .dontSave:
            discardAndClose(asBatchSurvivor: asBatchSurvivor)
            return .closed
        case .cancel:
            return .cancelled
        }
    }

    var closeAnchorWindow: NSWindow? {
        coordinator?.contentWindow ?? window ?? NSApp.keyWindow
    }

    // A background tabbed window is occluded, so its confirmation sheet would animate where the user cannot see it.
    private func selectInTabGroup() {
        guard let target = coordinator?.contentWindow ?? window,
              let tabGroup = target.tabGroup,
              tabGroup.selectedWindow !== target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tabGroup.selectedWindow = target
        }
    }

    // Called before the close dispatch: two of its three branches tear the window down with no later chance to capture.
    private func captureClosingTabsForRecovery() {
        guard let coordinator else { return }
        for tab in coordinator.tabsForRecoveryCapture() {
            RecentlyClosedTabStore.shared.push(tab: tab, connection: connection)
        }
    }

    private func finish(asBatchSurvivor: Bool?) {
        let t0 = Date()
        guard let window = coordinator?.contentWindow ?? NSApp.keyWindow else { return }
        captureClosingTabsForRecovery()

        if let asBatchSurvivor {
            Self.logger.info("[close] finish batch survivor=\(asBatchSurvivor)")
            if asBatchSurvivor {
                clearTabsInPlace()
            } else {
                window.close()
            }
            return
        }

        let visibleTabbedWindows = (window.tabbedWindows ?? [window]).filter(\.isVisible)
        Self.logger.info("[close] finish visibleTabs=\(visibleTabbedWindows.count) tabManagerTabs=\(self.coordinator?.tabManager.tabs.count ?? 0)")

        if visibleTabbedWindows.count > 1 || coordinator?.tabManager.tabs.isEmpty == true {
            window.close()
        } else {
            clearTabsInPlace()
        }
        Self.logger.info("[close] finish done ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    // Empties instead of closing, so the last tab lands on the no-tabs state with its connection still live.
    private func clearTabsInPlace() {
        guard let coordinator else { return }
        for tab in coordinator.tabManager.tabs {
            coordinator.tabSessionRegistry.removeTableRows(for: tab.id)
        }
        coordinator.tabManager.tabs.removeAll()
        coordinator.tabManager.selectedTabId = nil
        coordinator.toolbarState.isTableTab = false
    }

    // False while work is still staged after the attempt (review sheet, refused or cancelled DDL, file conflict, Save As cancel).
    func saveSelectedTabWork() async -> Bool {
        guard let coordinator = coordinator else { return true }

        if isUsersRolesTab, coordinator.usersRolesActions?.hasChanges() == true {
            coordinator.usersRolesActions?.reviewAndApply()
            return false
        }

        // Keyed on the session, not resultsViewMode, which let a Data-view or background tab close over its staged ALTERs.
        if let tabId = coordinator.tabManager.selectedTabId,
           let session = coordinator.structureSessions[tabId],
           session.changeManager.hasChanges {
            guard await session.applyStagedChanges(coordinator: coordinator).allowsClose else {
                return false
            }
        }
        guard await applySelectedDiagramEdits(in: coordinator) else { return false }
        guard await applySelectedTypeChanges() else { return false }

        // Data grid changes or pending table operations take priority
        if hasDataWork {
            return await withCheckedContinuation { continuation in
                coordinator.saveCompletionContinuation = continuation
                saveChanges()
            }
        }

        if trailingPaneState.inspector.editState.hasEdits {
            return await saveInspectorEditsAwaiting()
        }

        // File save (query editor with source file)
        if coordinator.tabManager.selectedTab?.content.isFileDirty == true {
            return await saveSelectedFileAwaiting()
        }

        return true
    }

    private func saveAndClose(asBatchSurvivor: Bool?) async -> Bool {
        guard let coordinator else {
            finish(asBatchSurvivor: asBatchSurvivor)
            return true
        }
        guard await applyStagedStructureEdits(in: coordinator.tabManager.tabs) else { return false }
        guard await saveSelectedTabWork() else { return false }
        finish(asBatchSurvivor: asBatchSurvivor)
        return true
    }

    // Reaches every tab the window or batch prompt asked about; the selected tab is left to saveSelectedTabWork.
    func applyStagedStructureEdits(in tabs: [QueryTab]) async -> Bool {
        guard let coordinator else { return true }
        let selectedId = coordinator.tabManager.selectedTabId
        let victims = tabs.filter { tab in
            tab.id != selectedId && coordinator.hasStagedStructureEdits(in: tab)
        }
        for tab in victims {
            guard await applyStagedSchemaWork(of: tab, in: coordinator) else { return false }
        }
        return await applyBackgroundTypeChanges(in: tabs)
    }


    private func discardAndClose(asBatchSurvivor: Bool?) {
        coordinator?.changeManager.clearChangesAndUndoHistory()
        pendingTruncates.wrappedValue.removeAll()
        pendingDeletes.wrappedValue.removeAll()
        trailingPaneState.inspector.editState.clearEdits()
        finish(asBatchSurvivor: asBatchSurvivor)
    }

    func copyTableNames() {
        coordinator?.sidebarViewModel?.copySelectedTableNames()
    }

    func truncateTables() {
        guard canTruncateSelectedTables else { return }
        coordinator?.sidebarViewModel?.batchToggleTruncate()
    }

    // MARK: - Filter Operations (Group A: Called Directly)

    func toggleFilterPanel() {
        guard canUseTableResultCommands, let coordinator else { return }
        coordinator.toggleFilterPanel()
    }

    var canPresentHighlightRules: Bool {
        coordinator?.canPresentHighlightRules ?? false
    }

    func showHighlightRules() {
        guard canPresentHighlightRules, let coordinator else { return }
        coordinator.presentHighlightRules()
    }

    func showFindBar(replace: Bool = false) {
        guard canUseGridFindCommands else { return }
        coordinator?.findCoordinator.showFind(replace: replace)
    }

    func useGridSelectionForFind() {
        guard canUseGridFindCommands else { return }
        coordinator?.findCoordinator.useSelectionForFind()
    }

    func stepFindForward() {
        coordinator?.findCoordinator.findNext()
    }

    func stepFindBackward() {
        coordinator?.findCoordinator.findPrevious()
    }

    // MARK: - Data Operations (Group A: Called Directly)

    var hasDataWork: Bool {
        coordinator?.changeManager.hasChanges == true
            || !pendingTruncates.wrappedValue.isEmpty
            || !pendingDeletes.wrappedValue.isEmpty
    }

    // What Save would write for the grid: cell edits and the staged TRUNCATE and DROP.
    func discardDataWork() {
        var truncates = pendingTruncates.wrappedValue
        var deletes = pendingDeletes.wrappedValue
        coordinator?.handleDiscard(pendingTruncates: &truncates, pendingDeletes: &deletes)
        pendingTruncates.wrappedValue = truncates
        pendingDeletes.wrappedValue = deletes
    }

    func restorePreviousValues() {
        coordinator?.rewindLastSave()
    }

    func saveChanges() {
        coordinator?.commitActiveGridEdit()
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.reviewAndApply()
            return
        }
        if coordinator?.tabManager.selectedTab?.tabType == .createTable {
            guard let coordinator, let draft = coordinator.activeCreateTableDraft else { return }
            draft.create(coordinator: coordinator)
            return
        }
        if saveSelectedDiagram() {
            return
        }
        if saveSelectedTypeChanges() { return }
        if let session = stagedStructureSession, let coordinator {
            Task { _ = await session.applyStagedChanges(coordinator: coordinator) }
        } else if hasDataWork {
            // Data grid first: its edits sync to the sidebar editState, and its path uses the plugin driver for statements.
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
        } else if trailingPaneState.inspector.editState.hasEdits {
            // Save sidebar-only edits (edits made directly in the right panel)
            saveInspectorEdits()
        }
        // File save: write query back to source file
        else if let tab = coordinator?.tabManager.selectedTab,
                tab.content.sourceFileURL != nil, tab.content.isFileDirty {
            saveFileToSourceURL()
        }
        // Save As: untitled query tab with content
        else if let tab = coordinator?.tabManager.selectedTab,
                tab.tabType == .query, tab.content.sourceFileURL == nil, tab.hasQueryText {
            saveFileAs()
        }
    }

    func saveFileAs() {
        Task { await saveFileAsAwaiting() }
    }

    @discardableResult
    func saveFileAsAwaiting() async -> Bool {
        guard let tab = coordinator?.tabManager.selectedTab,
              tab.tabType == .query else { return false }
        let content = tab.content.query
        let suggestedName = tab.content.sourceFileURL?.lastPathComponent ?? "\(tab.title).sql"
        let tabId = tab.id
        guard let url = await chooseSaveURL(suggestedName) else { return false }
        do {
            try await SQLFileService.writeFile(content: content, to: url, encoding: .utf8)
        } catch {
            Self.logger.error("Failed to save file: \(error.publicLogShape, privacy: .public)")
            reportFileSaveFailures([Self.saveFailureMessage(for: error, fileName: url.lastPathComponent)])
            return false
        }
        coordinator?.tabManager.mutate(tabId: tabId) { mutTab in
            mutTab.content.sourceFileURL = url
            FileTabBaseline.recordWrite(of: content, to: url, as: .utf8, in: &mutTab.content)
            mutTab.title = url.deletingPathExtension().lastPathComponent
        }
        coordinator?.tabManager.markTabRenamed(tabId)
        return true
    }

    var supportsExplain: Bool {
        !connection.type.explainVariants.isEmpty
    }

    var supportsFormatting: Bool {
        QueryFormatterFactory.supportsFormatting(connection.type)
    }

    func explainQuery() {
        coordinator?.runExplain()
    }

    var aiQueryActionAvailability: AIQueryActionAvailability {
        coordinator?.aiQueryActionAvailability ?? .hidden
    }

    func runAIQueryAction(_ action: AIQueryAction) {
        coordinator?.runAIQueryAction(action, target: .selectionOrStatementAtCursor)
    }

    func showRowAsJSON() {
        coordinator?.showRowAsJSON()
    }

    func openForeignKeyTable(reference: JSONForeignKeyRef, value: String) {
        coordinator?.navigateToFKReference(reference: reference, value: value)
    }

    func exportTables() {
        coordinator?.openExportDialog()
    }

    func exportQueryResults() {
        coordinator?.openExportQueryResultsDialog()
    }

    func importData() {
        coordinator?.openImportPanel()
    }

    func importTables(formatId: String) {
        coordinator?.openImportDialog(formatId: formatId)
    }

    var availableImportFormats: [ImportFormatOption] {
        PluginManager.shared.importFormatOptions(for: currentDatabaseType)
    }

    func backupDatabase() {
        coordinator?.activeSheet = .backupDatabase(databases: [])
    }

    // Per connection: a remote libSQL (Turso) URL cannot go to sqlite3, and its Backup Dump wrote a 52-byte file.
    var supportsBackup: Bool {
        NativeDumpRegistry.supports(
            connection,
            localFilePath: NativeDumpService.localFilePath(for: connection)
        )
    }

    var supportsRestore: Bool { supportsBackup }

    func restoreDatabase() {
        Task { @MainActor [weak self] in
            await self?.presentRestoreSourcePicker()
        }
    }

    private func presentRestoreSourcePicker() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = restoreSourceContentTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = restoreAcceptsDirectory
        panel.title = String(localized: "Choose Dump File")
        panel.prompt = String(localized: "Choose")
        panel.message = restoreSourceMessage

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        coordinator?.activeSheet = .restoreDatabase(fileURL: url)
    }

    private var restoreSourceContentTypes: [UTType] {
        let extensions = NativeDumpRegistry.formats(for: connection.type)
            .map(\.fileExtension)
            .filter { !$0.isEmpty }
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        guard restoreAcceptsDirectory else { return types + [.data] }
        return types + [.folder, .data]
    }

    // DuckDB restores a .duckdb file or a folder of Parquet.
    private var restoreAcceptsDirectory: Bool {
        NativeDumpRegistry.formats(for: connection.type).contains { $0.producesDirectory }
    }

    private var restoreSourceMessage: String {
        let descriptions = NativeDumpRegistry.formats(for: connection.type)
            .map(\.contentDescription)
            .filter { !$0.isEmpty }
        guard let joined = descriptions.formatted(.list(type: .or)).nilIfEmpty else {
            return String(localized: "Select a dump file this engine's own tool wrote.")
        }
        return String(format: String(localized: "Select a dump this connection's engine wrote: %@."), joined)
    }

    func saveAsFavorite() {
        coordinator?.saveCurrentQueryAsFavorite()
    }

    var canSaveAsFavorite: Bool {
        guard let tab = coordinator?.tabManager.selectedTab else { return false }
        return tab.tabType == .query && tab.hasQueryText
    }

    func previewSQL() {
        coordinator?.handlePreviewSQL(
            pendingTruncates: pendingTruncates.wrappedValue,
            pendingDeletes: pendingDeletes.wrappedValue,
            tableOperationOptions: tableOperationOptions.wrappedValue
        )
    }

    func runQuery() {
        if let coordinator, let draft = coordinator.activeCreateTableDraft {
            draft.create(coordinator: coordinator)
            return
        }
        coordinator?.runQuery(viewport: .keepPlace)
    }

    var canCreateDraftTable: Bool {
        coordinator?.activeCreateTableDraft?.isReadyToCreate ?? false
    }

    func runQueryWithoutLimit() {
        coordinator?.runQuery(viewport: .keepPlace, bypassRowLimit: true)
    }

    func runAllStatements() {
        coordinator?.runAllStatements()
    }

    func cancelCurrentQuery() {
        coordinator?.cancelCurrentQuery()
    }

    func formatQuery() {
        EditorEventRouter.shared.performFormatSQLForKeyWindow()
    }

    func clearQuery() {
        guard let coordinator,
              let (tab, tabIndex) = coordinator.tabManager.selectedTabAndIndex,
              tab.tabType == .query else { return }
        coordinator.tabManager.mutate(at: tabIndex) { $0.content.query = "" }
        coordinator.toolbarState.hasQueryText = false
        coordinator.scheduleDraftSave()
        // Emptying from a command bypasses the editor binding that recomputes the dirty indicator on each keystroke.
        coordinator.refreshUnsavedIndicator()
    }

    var canClearQuery: Bool {
        guard let tab = coordinator?.tabManager.selectedTab, tab.tabType == .query else { return false }
        return !tab.content.query.isEmpty
    }

    func clearResults() {
        coordinator?.clearActiveQueryResults()
    }

    var canClearResults: Bool {
        coordinator?.canClearActiveQueryResults ?? false
    }

    func removeInvisibleCharacters() {
        EditorEventRouter.shared.performRemoveInvisibleCharactersForKeyWindow()
    }

    func toggleFold() {
        EditorEventRouter.shared.performToggleFoldForKeyWindow()
    }

    func foldAll() {
        EditorEventRouter.shared.performFoldAllForKeyWindow()
    }

    func unfoldAll() {
        EditorEventRouter.shared.performUnfoldAllForKeyWindow()
    }

    func goToPreviousStatement() {
        EditorEventRouter.shared.moveCursorToStatementForKeyWindow(.previous)
    }

    func goToNextStatement() {
        EditorEventRouter.shared.moveCursorToStatementForKeyWindow(.next)
    }

    // Through the gutter's callback, so it only reaches its own connection; the caret moves first so a held key steps through.
    func runStatementAndAdvance() {
        EditorEventRouter.shared.runStatementAtCursorAndAdvanceForKeyWindow()
    }

    // MARK: - UI Operations (Group A: Called Directly)

    func toggleHistoryPanel() {
        guard let connectionId = coordinator?.connectionId else { return }
        let state = HistoryPanelState.forConnection(connectionId)
        state.isVisible.toggle()
    }

    func goToPreviousPage() {
        coordinator?.goToPreviousPage()
    }

    func goToNextPage() {
        coordinator?.goToNextPage()
    }

    func goToFirstPage() {
        coordinator?.goToFirstPage()
    }

    func goToLastPage() {
        coordinator?.goToLastPage()
    }

    func focusSidebarSearch() {
        coordinator?.splitViewController?.focusSidebarSearch()
    }

    func showSidebarTab(_ tab: SidebarTab) {
        coordinator?.splitViewController?.setSidebarTab(tab)
    }

    func toggleResults() {
        guard let coordinator,
              let (_, tabIndex) = coordinator.tabManager.selectedTabAndIndex else { return }
        coordinator.tabManager.mutate(at: tabIndex) { $0.display.isResultsCollapsed.toggle() }
        coordinator.toolbarState.isResultsCollapsed = coordinator.tabManager.tabs[tabIndex].display.isResultsCollapsed
    }

    func previousResultTab() {
        stepResultTab(by: -1)
    }

    func nextResultTab() {
        stepResultTab(by: 1)
    }

    var canShowPreviousResult: Bool {
        coordinator?.canStepActiveResultSet(by: -1) ?? false
    }

    var canShowNextResult: Bool {
        coordinator?.canStepActiveResultSet(by: 1) ?? false
    }

    private func stepResultTab(by offset: Int) {
        guard let coordinator, coordinator.canStepActiveResultSet(by: offset),
              let (tab, _) = coordinator.tabManager.selectedTabAndIndex,
              let activeId = tab.display.activeResultSet?.id,
              let index = tab.display.resultSets.firstIndex(where: { $0.id == activeId }) else { return }
        coordinator.switchActiveResultSet(to: tab.display.resultSets[index + offset].id, in: tab.id)
    }

    var canPinResultTab: Bool {
        coordinator?.canPinActiveResultSet ?? false
    }

    var isResultTabPinned: Bool {
        coordinator?.isActiveResultSetPinned ?? false
    }

    func pinResultTab() {
        guard let coordinator,
              let activeId = coordinator.tabManager.selectedTab?.display.activeResultSet?.id else { return }
        coordinator.togglePinResultSet(id: activeId)
    }

    var canCompareResult: Bool {
        coordinator?.canCompareActiveResult ?? false
    }

    func compareResult() {
        coordinator?.compareActiveResult()
    }

    var canCloseResultTab: Bool {
        coordinator?.canCloseActiveResultSet ?? false
    }

    func closeResultTab() {
        guard let coordinator, let activeId = coordinator.tabManager.selectedTab?.display.activeResultSet?.id else { return }
        coordinator.closeResultSet(id: activeId)
    }

    // MARK: - Group B Broadcast Subscribers

    // MARK: Data Broadcasts

    func refresh() {
        guard let coordinator else { return }
        coordinator.requestRefresh(
            hasPendingTableOps: hasPendingTableOps,
            onDiscard: { [weak self] in self?.clearPendingTableOps() }
        )
    }

    private var hasPendingTableOps: Bool {
        !pendingTruncates.wrappedValue.isEmpty || !pendingDeletes.wrappedValue.isEmpty
    }

    private func clearPendingTableOps() {
        pendingTruncates.wrappedValue.removeAll()
        pendingDeletes.wrappedValue.removeAll()
    }

    private func setupDataBroadcastObservers() {
        AppCommands.shared.refreshData
            .receive(on: RunLoop.main)
            .sink { [weak self] request in
                guard let self, request.connectionId == self.connection.id else { return }
                self.coordinator?.applyDataRefresh(request)
            }
            .store(in: &eventCancellables)

        AppCommands.shared.objectChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, change.connectionId == self.connection.id else { return }
                self.coordinator?.applyObjectChange(change)
            }
            .store(in: &eventCancellables)

        AppCommands.shared.containerChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, change.connectionId == self.connection.id else { return }
                self.coordinator?.applyContainerChange(change)
            }
            .store(in: &eventCancellables)

        AppCommands.shared.catalogChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, change.connectionId == self.connection.id else { return }
                self.coordinator?.applyCatalogChange(change)
            }
            .store(in: &eventCancellables)
    }

    // MARK: Database Broadcasts

    private func setupDatabaseBroadcastObservers() {
        AppEvents.shared.databaseDidConnect
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard let self, payload.connectionId == self.connection.id else { return }
                self.handleDatabaseDidConnect()
            }
            .store(in: &eventCancellables)
    }

    private func handleDatabaseDidConnect() {
        Task { [weak coordinator] in
            guard let coordinator, !coordinator.isTearingDown else { return }
            // A reconnect brings a new driver; the query builder would otherwise keep the disconnected one.
            coordinator.setupPluginDriver()
            // The first connect lands here during the initial load; refreshing on top sent every catalog query twice.
            if let inFlight = coordinator.schemaLoadTask,
               SchemaLoadPolicy.inFlightLoadCoversConnect(
                   loadDriver: coordinator.schemaLoadDriver,
                   connectedDriver: DatabaseManager.shared.driver(for: coordinator.connection.id)
               ) {
                await inFlight.value
                guard !coordinator.isTearingDown else { return }
                if case .loaded = SchemaService.shared.state(for: coordinator.connection.id) {
                    coordinator.initRedisKeyTreeIfNeeded()
                    return
                }
            }
            if case .loading = SchemaService.shared.state(for: coordinator.connection.id) {
                coordinator.initRedisKeyTreeIfNeeded()
                return
            }
            await coordinator.refreshTables()
            // Re-check after await: the user may have disconnected mid-fetch.
            guard !coordinator.isTearingDown else { return }
            coordinator.initRedisKeyTreeIfNeeded()
        }
    }

    // MARK: Window Broadcasts

    private func setupWindowObservers() {
        AppEvents.shared.mainWindowWillClose
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let coordinator = self?.coordinator else { return }
                guard !MainContentCoordinator.isAppTerminating else { return }
                coordinator.persistence.saveAggregated()
            }
            .store(in: &eventCancellables)
    }

    // MARK: File Open Broadcasts

    private func setupFileOpenObservers() {
        observeKeyWindowOnly(AppCommands.shared.openSQLFiles) { [weak self] urls in
            self?.handleOpenSQLFiles(urls)
        }
    }

    private func handleOpenSQLFiles(_ urls: [URL]) {
        Task {
            for url in urls {
                do {
                    try await TabRouter.shared.route(.openSQLFile(url))
                } catch {
                    coordinator?.presentError(
                        String(localized: "Could Not Open File"),
                        error.localizedDescription,
                        closeAnchorWindow
                    )
                }
            }
        }
    }
}

extension MainContentCommandActions {
    // Copy with the grid not focused takes the selected rows in the row copy format; a focused grid answers `copy:` itself.
    func copySelectedRowsInCopyFormat() {
        guard dataGridOwnsSelection, let model = coordinator?.activeGridModel else {
            copySelectedRows()
            return
        }
        let commands = DataGridCommands(model: model)
        commands.copyRows(
            DataGridCommandScope(selection: model.selection, focus: nil, isRowHeader: true),
            as: commands.rowCopyFormat
        )
    }
}
