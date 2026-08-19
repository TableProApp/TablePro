//
//  MainContentCommandActions.swift
//  TablePro
//
//  Provides command actions for MainContentView, reached through MainContentCoordinator.
//  Menu commands and toolbar buttons call methods directly instead of posting notifications.
//  Retains NotificationCenter subscribers only for legitimate multi-listener broadcasts.
//

import AppKit
import Combine
import Foundation
import Observation
import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

/// Provides command actions for MainContentView, reached through `MainContentCoordinator.commandActions`.
@MainActor
@Observable
final class MainContentCommandActions {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MainContentCommandActions")

    enum WindowCloseOutcome {
        case closed
        case cancelled
    }

    // MARK: - Dependencies

    @ObservationIgnored internal weak var coordinator: MainContentCoordinator?
    @ObservationIgnored private let connection: DatabaseConnection

    // MARK: - Bindings

    @ObservationIgnored private let selectionState: GridSelectionState
    @ObservationIgnored private let selectedTables: Binding<Set<TableInfo>>
    @ObservationIgnored private let pendingTruncates: Binding<Set<String>>
    @ObservationIgnored private let pendingDeletes: Binding<Set<String>>
    @ObservationIgnored private let tableOperationOptions: Binding<[String: TableOperationOptions]>
    @ObservationIgnored private let rightPanelState: RightPanelState

    /// The window this instance belongs to — used for key-window guards.
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            updateTextInputFocusTracking()
        }
    }

    // MARK: - State

    /// Whether a text input holds first responder in this instance's window.
    /// Stored rather than computed so Observation wakes the menu when focus
    /// crosses that boundary; `NSWindow.firstResponder` publishes no change.
    var focusOwnsTextInput = false

    @ObservationIgnored var textInputFocusObserver: NSObjectProtocol?

    @ObservationIgnored var isTextInputFocusCheckScheduled = false

    /// Task handles for async notification observers; cancelled on deinit.
    @ObservationIgnored private var notificationTasks: [Task<Void, Never>] = []

    /// Combine subscriptions for typed AppEvents publishers.
    @ObservationIgnored private var eventCancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    init(
        coordinator: MainContentCoordinator,
        connection: DatabaseConnection,
        selectionState: GridSelectionState,
        selectedTables: Binding<Set<TableInfo>>,
        pendingTruncates: Binding<Set<String>>,
        pendingDeletes: Binding<Set<String>>,
        tableOperationOptions: Binding<[String: TableOperationOptions]>,
        rightPanelState: RightPanelState
    ) {
        self.coordinator = coordinator
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
        if let textInputFocusObserver {
            NotificationCenter.default.removeObserver(textInputFocusObserver)
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

    /// The window being key is no longer enough: every connection it hosts shares that window, so
    /// a broadcast gated on it alone ran once per connection and opened a file in all of them.
    /// Only the connection on screen answers.
    private func isVisibleInKeyWindow() -> Bool {
        guard let window = self.window, window.isKeyWindow else { return false }
        guard let host = window.contentViewController as? MainSplitViewController else { return true }
        return host.workspaces.selected?.sessionState?.coordinator === coordinator
    }

    /// Like `observe(_:handler:)` but only runs the handler when this instance's window is key.
    private func observeKeyWindowOnly(
        _ name: Notification.Name,
        handler: @escaping @MainActor (Notification) -> Void
    ) {
        observe(name) { [weak self] notification in
            guard self?.isVisibleInKeyWindow() == true else { return }
            handler(notification)
        }
    }

    /// Subscribes to an `AppCommands` publisher and only runs the handler when this instance's window is key.
    private func observeKeyWindowOnly<Payload>(
        _ publisher: PassthroughSubject<Payload, Never>,
        handler: @escaping @MainActor (Payload) -> Void
    ) {
        publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] payload in
                guard self?.isVisibleInKeyWindow() == true else { return }
                handler(payload)
            }
            .store(in: &eventCancellables)
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
        setupDatabaseBroadcastObservers()
        setupWindowObservers()
        setupFileOpenObservers()
    }

    private func setupNonMenuNotificationObservers() {
        observeKeyWindowOnly(AppCommands.shared.exportQueryResults) { [weak self] _ in self?.exportQueryResults() }
    }

    // MARK: - Row Operations (Group A — Called Directly)

    func addNewRow() {
        // The structure tab routes through StructureGridDelegate, which inserts
        // a column / index / FK row depending on the active Structure sub-tab.
        // The data tab routes through MainContentCoordinator.addNewRow which
        // calls RowEditingCoordinator.addNewRow (data-only).
        switch selectionOwner {
        case .schemaGrid: coordinator?.structureActions?.addRow?()
        case .dataGrid: coordinator?.addNewRow()
        case .none: break
        }
    }

    private func resolvedRowSelection() -> Set<Int> {
        coordinator?.dataTabDelegate?.tableViewCoordinator?.currentRowSelection() ?? selectionState.indices
    }

    /// `selectionState` is shared with the structure and new-table grids, and nothing clears it when
    /// the result mode changes, so its indices only mean something once this says whose grid they
    /// came from. Every row command routes through it rather than re-deriving the answer.
    ///
    /// A Create Table tab publishes into the same channel but has no structure handler behind it,
    /// so claiming ownership there would make its commands silently inert and would shadow the
    /// table-deletion fallback the sidebar still needs. Ownership counts only where someone can act.
    private var selectionOwner: GridSelectionOwner {
        let owner = GridSelectionOwner.resolve(
            tabType: coordinator?.tabManager.selectedTab?.tabType,
            resultsViewMode: coordinator?.tabManager.selectedTab?.display.resultsViewMode
        )
        guard owner == .schemaGrid, coordinator?.structureActions == nil else { return owner }
        return .none
    }

    private var dataGridOwnsSelection: Bool { selectionOwner == .dataGrid }

    func deleteSelectedRows(rowIndices: Set<Int>? = nil) {
        let fromDataGrid = rowIndices != nil

        if selectionOwner == .schemaGrid {
            coordinator?.structureActions?.removeRow?()
            return
        }

        let indices = dataGridOwnsSelection ? (rowIndices ?? resolvedRowSelection()) : []
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
        guard dataGridOwnsSelection else { return }
        let indices = selectionState.indices
        guard let selectedIndex = indices.first, indices.count == 1 else { return }
        coordinator?.duplicateSelectedRow(index: selectedIndex)
    }

    func copySelectedRows() {
        switch selectionOwner {
        case .schemaGrid: coordinator?.structureActions?.copyRows?()
        case .dataGrid: coordinator?.copySelectedRowsToClipboard(indices: resolvedRowSelection())
        case .none: break
        }
    }

    func copySelectedRowsWithHeaders() {
        guard dataGridOwnsSelection else { return }
        coordinator?.copySelectedRowsWithHeaders(indices: resolvedRowSelection())
    }

    func copySelectedRowsAsJson() {
        guard dataGridOwnsSelection else { return }
        coordinator?.copySelectedRowsAsJson(indices: resolvedRowSelection())
    }

    func pasteRows() {
        switch selectionOwner {
        case .schemaGrid: coordinator?.structureActions?.pasteRows?()
        case .dataGrid: coordinator?.pasteRows()
        case .none: break
        }
    }

    // MARK: - Per-Window State (replaces AppState.shared for menu enablement)

    /// Answered by the window that owns this instance, because only its `ConnectionWindowPhase`
    /// can tell a window that is dialing or has failed from one that is connected. This object
    /// existing proves nothing: it is kept alive across a lost session so a reconnect can restore
    /// the user's tabs.
    var isConnected: Bool { coordinator?.splitViewController?.isConnected ?? false }
    var isQueryExecuting: Bool { coordinator?.toolbarState.isExecuting ?? false }

    var safeModeLevel: SafeModeLevel { coordinator?.toolbarState.safeModeLevel ?? connection.safeModeLevel }

    var isReadOnly: Bool { safeModeLevel.blocksAllWrites }

    var editorLanguage: EditorLanguage {
        PluginManager.shared.editorLanguage(for: connection.type)
    }

    var currentDatabaseType: DatabaseType { connection.type }

    var connectionId: UUID { connection.id }

    /// Whether Close has a tab to act on. With none, it ends the connection instead, and the menu
    /// has to say so rather than offering to close a tab that is not there.
    var hasOpenTab: Bool { coordinator?.tabManager.selectedTab != nil }

    var browseDatabaseName: String { coordinator?.browseDatabaseName ?? "" }

    var openTabCount: Int { coordinator?.tabManager.tabs.count ?? 0 }

    var supportsContainerSwitching: Bool {
        PluginManager.shared.supportsContainerSwitching(for: connection.type)
    }

    /// Picks between the two spellings a container command has. Each one is a whole localized
    /// string rather than a noun dropped into a format, because System Settings binds an App
    /// Shortcut to a menu item's exact literal title, and because the driver's own entity name
    /// would make the set open-ended. Both callers live in other files, so this is not private.
    func containerSwitchTitle(schema: String, database: String) -> String {
        switch PluginManager.shared.containerSwitchTarget(for: currentDatabaseType) {
        case .schema: return schema
        case .database, .none: return database
        }
    }

    var openContainerSwitcherTitle: String {
        containerSwitchTitle(
            schema: String(localized: "Open Schema..."),
            database: String(localized: "Open Database...")
        )
    }

    var canSwitchSidebarLayout: Bool {
        PluginManager.shared.supportsDatabaseTree(for: connection.type)
    }

    var supportsSchemaSwitching: Bool {
        PluginManager.shared.supportsSchemaSwitching(for: connection.type)
    }

    /// Filtering the database list only means anything on a connection whose sidebar can show one,
    /// which is the same rule the tree layout itself is gated on.
    var canFilterDatabases: Bool {
        PluginManager.shared.supportsDatabaseTree(for: connection.type)
            && sidebarLayout == .tree
    }

    var hasDatabaseFilter: Bool {
        !SharedSidebarState.forConnection(connection.id).databaseFilterSelected.isEmpty
    }

    var sidebarLayout: SidebarLayout {
        SharedSidebarState.forConnection(connection.id).sidebarLayout
    }

    func setSidebarLayout(_ layout: SidebarLayout) {
        SharedSidebarState.forConnection(connection.id).sidebarLayout = layout
    }

    var isCurrentTabEditable: Bool {
        guard let tab = coordinator?.tabManager.selectedTab, selectionOwner != .none else { return false }
        return tab.tableContext.isEditable
    }

    /// Find and the filter panel act on the result grid, so they need a table tab that is showing
    /// one. Chart mode is not, and neither is Structure, whose own grid has its own commands.
    var canUseTableResultCommands: Bool {
        guard coordinator?.toolbarState.isTableTab == true,
              let viewMode = coordinator?.tabManager.selectedTab?.display.resultsViewMode
        else {
            return false
        }
        return viewMode.showsRowFilters
    }

    var canUseGridFindCommands: Bool {
        guard coordinator?.toolbarState.isTableTab == true,
              let viewMode = coordinator?.tabManager.selectedTab?.display.resultsViewMode
        else {
            return false
        }
        return viewMode.showsFindBar
    }

    var hasActiveGridFind: Bool {
        guard canUseGridFindCommands,
              let findState = coordinator?.tabManager.selectedTab?.findState else { return false }
        return findState.isVisible && !findState.matches.isEmpty
    }

    /// What `pasteRows()` will actually do, so the Edit menu's Paste item is enabled only when it
    /// leads somewhere. AppKit gives a disabled item its key equivalent all the same, so an item
    /// enabled over a handler that returns at its first guard swallows Command+V in silence.
    var canPasteRows: Bool {
        guard !safeModeLevel.blocksAllWrites, let tab = coordinator?.tabManager.selectedTab else {
            return false
        }
        switch selectionOwner {
        case .schemaGrid:
            return coordinator?.structureActions?.pasteRows != nil && TableStructureView.canPasteStructureRows
        case .dataGrid:
            return tab.tabType == .table && isCurrentTabEditable && ClipboardService.shared.hasText
        case .none:
            return false
        }
    }

    /// The two facts Save As and Export Results actually turn on. Their menu items used to be
    /// validated on `isConnected` alone, so both stayed lit in states where the handler returns at
    /// its first guard and the click does nothing at all.
    var isQueryTab: Bool {
        coordinator?.tabManager.selectedTab?.tabType == .query
    }

    var hasResultRows: Bool {
        guard let coordinator, let tab = coordinator.tabManager.selectedTab else { return false }
        return !coordinator.tabSessionRegistry.tableRows(for: tab.id).rows.isEmpty
    }

    var hasRowSelection: Bool {
        selectionOwner != .none && !resolvedRowSelection().isEmpty
    }

    /// Copy with headers and copy as JSON read the data grid's columns, so they are only meaningful
    /// when the data grid owns the indices. The structure grid has its own plain copy and nothing
    /// else; handing it these would read a structure row's position into the result rows.
    var hasDataGridRowSelection: Bool {
        dataGridOwnsSelection && !resolvedRowSelection().isEmpty
    }

    var hasTableSelection: Bool {
        !selectedTables.wrappedValue.isEmpty
    }

    /// The one selected object, or nil when the selection is empty or spans several.
    /// Commands that open a single object need this rather than `hasTableSelection`.
    var selectedObject: TableInfo? {
        let selection = selectedTables.wrappedValue
        guard selection.count == 1 else { return nil }
        return selection.first
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

    /// Scoped to the whole window, not the selected tab: closing a window closes every tab in it,
    /// so a tab the user is not looking at must still get its prompt.
    /// Every connection the window hosts, because closing the window closes all of them. Asking
    /// only about the one on screen let a background connection's unsaved edits go without a
    /// prompt, which is silent data loss rather than a missing confirmation.
    internal var hasUnsavedWorkInWindow: Bool {
        guard let host = window?.contentViewController as? MainSplitViewController else {
            return coordinator?.hasAnyUnsavedWork() ?? false
        }
        return host.workspaces.workspaces.contains { workspace in
            workspace.sessionState?.coordinator.hasAnyUnsavedWork() == true
        }
    }

    /// This connection only. Closing its tabs says nothing about what another connection in the
    /// same window has pending, so prompting about that would ask the wrong question.
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

    // MARK: - Editor Query Loading (Group A — Called Directly)

    func loadQueryIntoEditor(_ query: String) {
        coordinator?.loadQueryIntoEditor(query)
    }

    func insertQueryFromAI(_ query: String) {
        coordinator?.insertQueryFromAI(query)
    }

    // MARK: - Tab Operations (Group A — Called Directly)

    /// A new tab joins the connection's own tab list. It used to open another window whenever
    /// the list was not empty, which is why two tables meant two windows.
    func newTab(initialQuery: String? = nil) {
        guard let coordinator else { return }
        coordinator.tabManager.addTab(
            initialQuery: initialQuery,
            databaseName: coordinator.browseDatabaseName,
            claimFocus: true
        )
    }

    /// Closing the last tab leaves the connection open on its empty state, the same state it is
    /// in right after connecting. The window hosts every open connection now, so closing it here
    /// would take the other connections' tabs and their unsaved edits with it.
    func closeTab(id: UUID) {
        Task { await closeTabAwaiting(id: id) }
    }

    /// A tab holding work only a save can recover asks before it goes, which is what the window
    /// close and the batch closes already do and what the HIG requires of an app that does not
    /// autosave: "present a save dialog when people choose to close the document, quit your app,
    /// log out, or restart".
    ///
    /// Save proceeds with the close, per `NSDocument.canCloseDocumentWithDelegate`: "shouldClose
    /// will be YES if ... the user chose to discard modifications, or chose to save and the saving
    /// was successful". `saveSelectedTabWork` returns false for the one case where saving cannot
    /// finish on its own, staged principals, whose review sheet is now up and owns the decision.
    func closeTabAwaiting(id: UUID) async {
        guard let coordinator,
              let tab = coordinator.tabManager.tabs.first(where: { $0.id == id }) else { return }
        guard coordinator.hasUnsavedWork(in: tab) else {
            coordinator.closeTabsByUser(ids: [id])
            return
        }
        guard coordinator.tabClosesInFlight.insert(id).inserted else { return }
        defer { coordinator.tabClosesInFlight.remove(id) }

        let previousSelection = coordinator.tabManager.selectedTabId
        revealTab(id)

        switch await AlertHelper.confirmSaveChanges(
            message: String(localized: "Your changes will be lost if you don't save them."),
            window: closeAnchorWindow
        ) {
        case .save:
            guard await saveSelectedTabWork() else { return }
            coordinator.closeTabsByUser(ids: [id])
        case .dontSave:
            coordinator.closeTabsByUser(ids: [id])
        case .cancel:
            restoreSelection(previousSelection)
        }
    }

    /// Shown, then asked. The save and discard machinery reads the selected tab, so the tab being
    /// closed has to be the selected one before the question is put; naming work the user cannot
    /// see would also ask them to decide about something they have no way to look at first.
    private func revealTab(_ id: UUID) {
        guard let coordinator, coordinator.tabManager.selectedTabId != id else { return }
        coordinator.tabManager.selectedTabId = id
    }

    /// Cancel puts everything back, including a selection that only moved so the sheet had
    /// somewhere honest to point.
    private func restoreSelection(_ id: UUID?) {
        guard let coordinator,
              let id,
              coordinator.tabManager.selectedTabId != id,
              coordinator.tabManager.tabs.contains(where: { $0.id == id }) else { return }
        coordinator.tabManager.selectedTabId = id
    }

    /// Cmd+W closes the tab in front. Pressed again with no tabs left it closes the connection,
    /// and the window itself only once that was the last connection open in it.
    func closeTab() {
        guard let coordinator else {
            Task { await closeWindowAwaiting() }
            return
        }
        if let selected = coordinator.tabManager.selectedTab {
            closeTab(id: selected.id)
            return
        }
        Task {
            guard await confirmDiscardingUnsavedWork() else { return }
            WindowManager.shared.closeWindow(for: connectionId)
        }
    }

    /// The single close primitive. `asBatchSurvivor` is `nil` for a lone close gesture, which lets
    /// the window decide for itself whether it can go away; a batch passes `true` for the one
    /// window it keeps blank and `false` for every window it tears down.
    @discardableResult
    func closeWindowAwaiting(asBatchSurvivor: Bool? = nil) async -> WindowCloseOutcome {
        let seq = MainContentCoordinator.nextSwitchSeq()
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

    /// A background tabbed window is occluded by the selected tab, so its confirmation sheet would
    /// animate onto a surface the user cannot see. Bring it forward first.
    private func selectInTabGroup() {
        guard let target = coordinator?.contentWindow ?? window,
              let tabGroup = target.tabGroup,
              tabGroup.selectedWindow !== target else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tabGroup.selectedWindow = target
        }
    }

    /// Every close gesture funnels here, so this is the one place that can guarantee a closing
    /// tab's content outlives the window. It runs before the branch dispatch below because two of
    /// the three branches tear the window down without another chance to capture anything.
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

    /// Empties the window instead of closing it, which is how the last tab of a group lands on the
    /// no-tabs state with its connection still live.
    private func clearTabsInPlace() {
        guard let coordinator else { return }
        for tab in coordinator.tabManager.tabs {
            coordinator.tabSessionRegistry.removeTableRows(for: tab.id)
            if let url = tab.content.sourceFileURL {
                WindowLifecycleMonitor.shared.unregisterSourceFile(url)
            }
        }
        coordinator.tabManager.tabs.removeAll()
        coordinator.tabManager.selectedTabId = nil
        coordinator.toolbarState.isTableTab = false
    }

    /// The save half of a close, shared by the tab close, the window close and the batch close so
    /// the three cannot drift on what Save means. Returns whether the caller may go on to close.
    ///
    /// False comes back for exactly one case: user and role changes can only be applied after the
    /// SQL is reviewed, so Save opens the review sheet and stands the close down. Falling through
    /// there would close over the sheet and destroy every staged change.
    func saveSelectedTabWork() async -> Bool {
        guard let coordinator = coordinator else { return true }

        if isUsersRolesTab, coordinator.usersRolesActions?.hasChanges() == true {
            coordinator.usersRolesActions?.reviewAndApply()
            return false
        }

        // Structure view saves via direct coordinator call
        if coordinator.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator.structureActions?.saveChanges?()
            return true
        }

        // Data grid changes or pending table operations take priority
        let hasDataChanges = coordinator.changeManager.hasChanges
            || !pendingTruncates.wrappedValue.isEmpty
            || !pendingDeletes.wrappedValue.isEmpty
        if hasDataChanges {
            return await withCheckedContinuation { continuation in
                coordinator.saveCompletionContinuation = continuation
                saveChanges()
            }
        }

        // Sidebar-only edits (made directly in the inspector panel)
        if rightPanelState.editState.hasEdits {
            rightPanelState.onSave?()
            return true
        }

        // File save (query editor with source file)
        if coordinator.tabManager.selectedTab?.content.isFileDirty == true {
            saveFileToSourceURL()
            return true
        }

        return true
    }

    private func saveAndClose(asBatchSurvivor: Bool?) async -> Bool {
        guard coordinator != nil else {
            finish(asBatchSurvivor: asBatchSurvivor)
            return true
        }
        guard await saveSelectedTabWork() else { return false }
        finish(asBatchSurvivor: asBatchSurvivor)
        return true
    }

    private func saveFileToSourceURL() {
        guard let tab = coordinator?.tabManager.selectedTab,
              let url = tab.content.sourceFileURL else { return }

        if isExternallyModified(tab: tab, url: url) {
            requestConflictResolution(tab: tab, url: url)
            return
        }

        writeTabContent(tabId: tab.id, content: tab.content.query, to: url)
    }

    func writeTabContent(tabId: UUID, content: String, to url: URL) {
        Task {
            do {
                try await SQLFileService.writeFile(content: content, to: url)
                let mtime = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                coordinator?.tabManager.mutate(tabId: tabId) { tab in
                    tab.content.savedFileContent = content
                    tab.content.loadMtime = mtime
                    tab.content.externalModificationDetected = false
                }
            } catch {
                Self.logger.error("Failed to save file: \(error.localizedDescription)")
                saveFileAs()
            }
        }
    }

    private func isExternallyModified(tab: QueryTab, url: URL) -> Bool {
        guard let loadMtime = tab.content.loadMtime,
              let currentMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else {
            return false
        }
        return currentMtime > loadMtime.addingTimeInterval(0.5)
    }

    private func requestConflictResolution(tab: QueryTab, url: URL) {
        let mineContent = tab.content.query
        let diskContent = FileTextLoader.load(url)?.content ?? ""
        coordinator?.fileConflictRequest = MainContentCoordinator.FileConflictRequest(
            tabId: tab.id,
            url: url,
            mineContent: mineContent,
            diskContent: diskContent
        )
    }

    func reloadFileFromDisk(tabId: UUID, url: URL) {
        guard let beforeIndex = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let queryAtRequestTime = coordinator?.tabManager.tabs[beforeIndex].content.query
        Task {
            guard let loaded = FileTextLoader.load(url) else { return }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            await MainActor.run {
                guard let index = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
                let liveQuery = coordinator?.tabManager.tabs[index].content.query
                guard liveQuery == queryAtRequestTime else { return }
                coordinator?.tabManager.mutate(at: index) { tab in
                    tab.content.query = loaded.content
                    tab.content.savedFileContent = loaded.content
                    tab.content.loadMtime = mtime
                    tab.content.externalModificationDetected = false
                }
            }
        }
    }

    private func discardAndClose(asBatchSurvivor: Bool?) {
        coordinator?.changeManager.clearChangesAndUndoHistory()
        pendingTruncates.wrappedValue.removeAll()
        pendingDeletes.wrappedValue.removeAll()
        rightPanelState.editState.clearEdits()
        finish(asBatchSurvivor: asBatchSurvivor)
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

    func showQueryInsights() {
        coordinator?.showQueryInsights()
    }

    var supportsServerDashboard: Bool {
        guard let type = coordinator?.connection.type else { return false }
        return ServerDashboardQueryProviderFactory.provider(for: type) != nil
    }

    func showUsersAndRoles() {
        coordinator?.showUsersAndRoles()
    }

    var supportsUserManagement: Bool {
        guard let connectionId = coordinator?.connectionId,
              let adapter = DatabaseManager.shared.driver(for: connectionId) as? PluginDriverAdapter
        else { return false }
        return adapter.schemaPluginDriver.capabilities.contains(.userManagement)
    }

    // MARK: - Tab Navigation (Group A — Called Directly)

    /// Selects the Nth editor tab of the connection on screen. It used to index the window's
    /// native tab group, which named windows rather than tabs.
    func selectTab(number: Int) {
        coordinator?.tabManager.selectTab(at: number - 1)
    }

    func selectTab(offsetBy offset: Int) {
        coordinator?.tabManager.selectTab(offsetBy: offset)
    }

    // MARK: - Filter Operations (Group A — Called Directly)

    func toggleFilterPanel() {
        guard canUseTableResultCommands, let coordinator else { return }
        coordinator.toggleFilterPanel()
    }

    func showFindBar() {
        guard canUseGridFindCommands, let coordinator else { return }
        coordinator.findCoordinator.show()
    }

    func stepFindForward() {
        coordinator?.findCoordinator.stepForward()
    }

    func stepFindBackward() {
        coordinator?.findCoordinator.stepBackward()
    }

    // MARK: - Data Operations (Group A — Called Directly)

    func saveChanges() {
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.reviewAndApply()
            return
        }
        if coordinator?.tabManager.selectedTab?.tabType == .createTable {
            coordinator?.createTableActions?.createTable?()
            return
        }
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
        let tabId = tab.id
        Task {
            guard let url = await SQLFileService.showSavePanel(suggestedName: suggestedName) else { return }
            do {
                try await SQLFileService.writeFile(content: content, to: url)
                coordinator?.tabManager.mutate(tabId: tabId) { mutTab in
                    mutTab.content.sourceFileURL = url
                    mutTab.content.savedFileContent = content
                    mutTab.title = url.deletingPathExtension().lastPathComponent
                }
                coordinator?.tabManager.markTabRenamed(tabId)
            } catch {
                Self.logger.error("Failed to save file: \(error.localizedDescription)")
            }
        }
    }

    func openSQLFile() {
        Task {
            guard let urls = await SQLFileService.showOpenPanel() else { return }
            AppCommands.shared.openSQLFiles.send(urls)
        }
    }

    func explainQuery() {
        coordinator?.runExplain()
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

    func importTables(formatId: String) {
        coordinator?.openImportDialog(formatId: formatId)
    }

    var availableImportFormats: [ImportFormatOption] {
        PluginManager.shared.importFormatOptions(for: currentDatabaseType)
    }

    func backupDatabase() {
        coordinator?.activeSheet = .backupDatabase
    }

    var supportsBackup: Bool {
        connection.type == .postgresql || connection.type == .redshift
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
        panel.allowedContentTypes = Self.restoreSourceContentTypes
        panel.title = String(localized: "Choose Dump File")
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Select a dump file produced by pg_dump in custom archive format.")

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        coordinator?.activeSheet = .restoreDatabase(fileURL: url)
    }

    private static var restoreSourceContentTypes: [UTType] {
        if let dumpType = UTType(filenameExtension: "dump") {
            return [dumpType, .data]
        }
        return [.data]
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

    func runQueryWithoutLimit() {
        coordinator?.runQuery(bypassRowLimit: true)
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

    func toggleFold() {
        EditorEventRouter.shared.performToggleFoldForKeyWindow()
    }

    func foldAll() {
        EditorEventRouter.shared.performFoldAllForKeyWindow()
    }

    func unfoldAll() {
        EditorEventRouter.shared.performUnfoldAllForKeyWindow()
    }

    // MARK: - UI Operations (Group A — Called Directly)

    func toggleHistoryPanel() {
        guard let connectionId = coordinator?.connectionId else { return }
        let state = HistoryPanelState.forConnection(connectionId)
        state.isVisible.toggle()
    }

    func toggleRightSidebar() {
        coordinator?.inspectorProxy?.toggleInspector()
    }

    var isWorkspaceRailEnabled: Bool {
        coordinator?.splitViewController?.isWorkspaceRailEnabled ?? false
    }

    var canToggleWorkspaceRail: Bool {
        coordinator?.splitViewController?.canToggleWorkspaceRail ?? false
    }

    func toggleWorkspaceRail() {
        coordinator?.splitViewController?.toggleWorkspaceRail()
    }

    func showPreviousWorkspace() {
        coordinator?.splitViewController?.activateWorkspace(offsetBy: -1)
    }

    func showNextWorkspace() {
        coordinator?.splitViewController?.activateWorkspace(offsetBy: 1)
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

    func closeResultTab() {
        guard let coordinator else { return }
        let tab = coordinator.tabManager.selectedTab
        guard let activeId = tab?.display.activeResultSetId ?? tab?.display.resultSets.last?.id else { return }
        coordinator.closeResultSet(id: activeId)
    }

    // MARK: - Database Operations (Group A — Called Directly)

    func openDatabaseSwitcher() {
        guard let coordinator else { return }
        let type = coordinator.connection.type
        guard PluginManager.shared.supportsContainerSwitching(for: type) else { return }
        guard PluginManager.shared.connectionMode(for: type) != .fileBased else { return }
        coordinator.contentWindow?.makeFirstResponder(nil)
        coordinator.presentedScopeSwitcher = nil
        coordinator.isDatabaseSwitcherShown = true
    }

    /// The same chooser, opened from the toolbar chip so it appears against the scope it switches.
    /// Clearing first responder is what lets the popover's search field take focus, which is why
    /// the chip cannot just flip its own presentation flag.
    func openScopeSwitcher(_ target: ContainerSwitchTarget) {
        guard let coordinator else { return }
        let type = coordinator.connection.type
        guard PluginManager.shared.switchableContainers(for: type).contains(target) else { return }
        coordinator.contentWindow?.makeFirstResponder(nil)
        coordinator.isDatabaseSwitcherShown = false
        coordinator.presentedScopeSwitcher = target
    }

    func openQuickSwitcher() {
        coordinator?.showQuickSwitcher()
    }

    func openConnectionSwitcher() {
        coordinator?.contentWindow?.makeFirstResponder(nil)
        coordinator?.isConnectionSwitcherShown = true
    }

    // MARK: - Undo/Redo (Group A — Called Directly)

    func undoChange() {
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.undo()
            return
        }
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.undo?()
            return
        }
        coordinator?.contentWindow?.undoManager?.undo()
    }

    func redoChange() {
        if isUsersRolesTab {
            coordinator?.usersRolesActions?.redo()
            return
        }
        if coordinator?.tabManager.selectedTab?.display.resultsViewMode == .structure {
            coordinator?.structureActions?.redo?()
            return
        }
        coordinator?.contentWindow?.undoManager?.redo()
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
                guard let self, request.connectionId == self.connection.id,
                      let coordinator = self.coordinator else { return }
                if request.reaches(tabScope: coordinator.selectedTabScope) {
                    coordinator.reloadActiveTableData(
                        hasPendingTableOps: self.hasPendingTableOps,
                        onDiscard: { [weak self] in self?.clearPendingTableOps() }
                    )
                }
                if request.reachesBrowsedDatabase(coordinator.browseDatabaseName) {
                    Task { await coordinator.refreshTables() }
                }
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
            if let driver = DatabaseManager.shared.driver(for: coordinator.connection.id) {
                coordinator.toolbarState.databaseVersion = driver.serverVersion
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
                try? await TabRouter.shared.route(.openSQLFile(url))
            }
        }
    }
}
