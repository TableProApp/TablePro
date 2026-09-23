//
//  MainContentView+Setup.swift
//  TablePro
//
//  Extension containing initialization, command setup, and database switching
//  for MainContentView. Extracted to reduce main view complexity.
//

import os
import SwiftUI

private enum RestoreLoadTiming {
    case immediate
    case deferred
}

extension MainContentView {
    // MARK: - Initialization

    func initializeAndRestoreTabs() async {
        guard !hasInitialized else {
            MainContentView.lifecycleLogger.info(
                "[open] initializeAndRestoreTabs skipped (already initialized) windowId=\(windowId, privacy: .public)"
            )
            return
        }
        hasInitialized = true
        let schemaTaskStart = Date()
        async let schemaLoad: Void = {
            await coordinator.loadSchemaIfNeeded()
            MainContentView.lifecycleLogger.info(
                "[open] loadSchemaIfNeeded done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(schemaTaskStart) * 1_000))"
            )
        }()

        guard let payload else {
            await handleRestoreOrDefault()
            _ = await schemaLoad
            return
        }

        MainContentView.lifecycleLogger.info(
            "[open] initializeAndRestoreTabs intent=\(String(describing: payload.intent), privacy: .public) windowId=\(windowId, privacy: .public) skipAutoExecute=\(payload.skipAutoExecute)"
        )

        switch payload.intent {
        case .openContent:
            if let selectedTab = tabManager.selectedTab,
                selectedTab.tabType == .table,
                selectedTab.tableContext.tableName != nil
            {
                coordinator.restoreLastHiddenColumnsForTable()
                if selectedTab.filterState.appliedFilters.isEmpty {
                    coordinator.restoreFiltersForSelectedTab()
                } else if let tabIndex = tabManager.selectedTabIndex {
                    coordinator.rebuildTableQuery(at: tabIndex)
                }
            }
            if payload.skipAutoExecute {
                await coordinator.rebuildSelectedTableQueryForHiddenColumnsIfNeeded()
                _ = await schemaLoad
                return
            }
            if let selectedTab = tabManager.selectedTab,
                selectedTab.tabType == .table,
                !selectedTab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                if let session = DatabaseManager.shared.activeSessions[connection.id],
                    session.isConnected
                {
                    coordinator.lazyLoadCurrentTabIfNeeded()
                } else {
                    coordinator.pendingLoadTrigger = .userInitiated
                }
            }
            if let sourceURL = payload.sourceFileURL {
                WindowLifecycleMonitor.shared.registerSourceFile(sourceURL, windowId: windowId)
            }

        case .newEmptyTab:
            _ = await schemaLoad
            return

        case .restoreOrDefault:
            await handleRestoreOrDefault()
        }

        _ = await schemaLoad
    }

    private func restoreConnectionContext(
        for selected: QueryTab,
        activeDatabase: String?,
        activeSchema: String?,
        loadTiming: RestoreLoadTiming
    ) {
        let isTableTab = selected.tabType == .table
            && !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        guard loadTiming == .immediate else {
            if isTableTab {
                coordinator.deferredRestoreLoadTabId = selected.id
            }
            return
        }

        guard let session = DatabaseManager.shared.activeSessions[connection.id], session.isConnected else {
            if isTableTab { coordinator.pendingLoadTrigger = .restore }
            return
        }

        Task {
            await coordinator.switchContainers(database: activeDatabase, schema: activeSchema)
            if isTableTab {
                coordinator.lazyLoadCurrentTabIfNeeded(trigger: .restore)
            }
        }
    }

    private func applyRestoredGroup(
        _ tabs: [QueryTab],
        selectedTabId: UUID?,
        activeDatabase: String? = nil,
        activeSchema: String? = nil,
        loadTiming: RestoreLoadTiming = .immediate
    ) {
        guard let firstTab = tabs.first else { return }
        tabManager.tabs = tabs
        tabManager.selectedTabId = tabs.contains(where: { $0.id == selectedTabId }) ? selectedTabId : firstTab.id

        guard let selected = tabManager.selectedTab else { return }

        if selected.tabType == .table,
            !selected.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            coordinator.restoreLastHiddenColumnsForTable()
        }

        /// Every table tab, not just the selected one. A tab whose filters were never loaded holds
        /// an empty set, and the next tab switch saves that over the filters the reader left on the
        /// table, because an empty set is what the storage reads as a delete. The hidden columns
        /// above go first, so the query this rebuilds for the selected tab selects the right ones.
        for index in tabManager.tabs.indices where tabManager.tabs[index].tabType == .table {
            coordinator.restoreFilters(forTabAt: index)
        }

        restoreConnectionContext(
            for: selected,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            loadTiming: loadTiming
        )
    }

    private func handleRestoreOrDefault() async {
        /// The split view controller owns the window and is wired up before this view is built, unlike
        /// `viewWindow`, which arrives from `configureWindow` and can still be nil here.
        guard let window = coordinator.splitViewController?.view.window else {
            MainContentView.lifecycleLogger.error(
                "[open] handleRestoreOrDefault has no window windowId=\(windowId, privacy: .public)"
            )
            return
        }
        let restoreStart = Date()
        let result = await coordinator.persistence.restoreFromDisk()
        MainContentView.lifecycleLogger.info(
            "[open] restoreFromDisk done windowId=\(windowId, privacy: .public) tabsRestored=\(result.tabs.count) source=\(String(describing: result.source), privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(restoreStart) * 1_000))"
        )
        guard !result.tabs.isEmpty else { return }

        var restoredTabs = result.tabs
        for i in restoredTabs.indices where restoredTabs[i].tabType == .table {
            if let tableName = restoredTabs[i].tableContext.tableName {
                do {
                    restoredTabs[i].content.query = try QueryTab.buildBaseTableQuery(
                        tableName: tableName,
                        databaseType: connection.type,
                        schemaName: restoredTabs[i].tableContext.schemaName
                    )
                } catch {
                    MainContentView.lifecycleLogger.error(
                        "[open] buildBaseTableQuery failed for restored tab table=\(tableName, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
                    )
                }
            }
        }

        /// One window hosts every connection, so a connection's saved tabs all belong to the one
        /// tab list. The old shape split them across windows by a saved group index, which now
        /// has nowhere to go: a group handed back to `openTab` restores nothing and the next
        /// autosave erases it.
        applyRestoredGroup(
            restoredTabs,
            selectedTabId: result.selectedTabId ?? restoredTabs.first?.id,
            activeDatabase: result.lastActiveDatabase,
            activeSchema: result.lastActiveSchema,
            loadTiming: window.isKeyWindow ? .immediate : .deferred
        )
    }


    // MARK: - Command Actions Setup

    /// One resolution of what is staged, so the commit control, its verb and Preview SQL's gate
    /// cannot disagree. The arm this replaces never read `hasPrincipalChanges`, so a Users & Roles
    /// tab with staged principals left both the toolbar's commit button and Cmd+S dim over work
    /// `saveChanges()` already knew how to apply.
    func updateToolbarPendingState() {
        let kind = PendingChangeKind.resolve(
            tabType: tabManager.selectedTab?.tabType,
            hasDataChanges: changeManager.hasChanges || !pendingTruncates.isEmpty || !pendingDeletes.isEmpty,
            hasStructureChanges: toolbarState.hasStructureChanges,
            hasCreateTablePending: toolbarState.hasCreateTablePending,
            hasPrincipalChanges: toolbarState.hasPrincipalChanges,
            isFileDirty: tabManager.selectedTab?.content.isFileDirty ?? false
        )
        toolbarState.pendingChange = kind
        toolbarState.hasPendingChanges = kind != nil
        /// Preview SQL asks a narrower question than the commit control: a dirty query file and
        /// staged principals both raise the commit and neither has grid SQL to show.
        toolbarState.hasDataPendingChanges = kind == .data || kind == .structure
    }

    /// Update window title, proxy icon, and dirty dot based on the selected tab.
    ///
    /// This tree is the browse content, so it names the window as the browse content: `.content`
    /// and `.browse` are what it is, not guesses. Whether it is the tree on screen is the window's
    /// question, and its bindings drop a name or a file written from behind an agent conversation.
    /// The edited dot is still written directly, because the unsaved work it reports is still in
    /// the window while the conversation is drawn over it.
    func updateWindowTitleAndFileState() {
        let selectedTab = tabManager.selectedTab
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: connection,
            tab: selectedTab,
            hasTabs: !tabManager.tabs.isEmpty,
            queryLanguageName: PluginManager.shared.queryLanguageName(for: connection.type)
        )
        windowTitle = resolved.title
        windowSubtitle = resolved.subtitle
        windowRepresentedURL = resolved.representedURL
        coordinator.splitViewController?.updateDetailMinimumThickness(
            for: selectedTab?.tabType,
            connectionId: connection.id
        )
        viewWindow?.isDocumentEdited = selectedTab.map(coordinator.showsUnsavedIndicator) ?? false
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    func configureWindow(_ window: NSWindow) {
        let start = Date()
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow start windowId=\(windowId, privacy: .public) connId=\(connection.id, privacy: .public)"
        )
        let isPreview = tabManager.selectedTab?.isPreview ?? payload?.isPreview ?? false

        window.tabbingIdentifier = WindowManager.mainTabbingIdentifier
        coordinator.windowId = windowId

        WindowLifecycleMonitor.shared.register(
            window: window,
            connectionId: connection.id,
            windowId: windowId
        )
        viewWindow = window
        coordinator.contentWindow = window
        coordinator.isKeyWindow = window.isKeyWindow

        // Native proxy icon (Cmd+click shows path in Finder) and dirty dot
        windowRepresentedURL = tabManager.selectedTab?.content.sourceFileURL
        window.isDocumentEdited = tabManager.selectedTab.map(coordinator.showsUnsavedIndicator) ?? false

        commandActions?.window = window

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.pointToolbar(at: coordinator)
        }

        MainContentView.lifecycleLogger.info(
            "[open] configureWindow done windowId=\(windowId, privacy: .public) isPreview=\(isPreview) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    func setupCommandActions() {
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(
                get: { coordinator.windowSidebarState.selectedTables },
                set: { coordinator.windowSidebarState.selectTables($0) }
            ),
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            trailingPaneState: trailingPaneState
        )
        actions.window = viewWindow
        coordinator.commandActions = actions
        commandActions = actions
        coordinator.splitViewController?.rebuildTrailingPanes()
    }

    // MARK: - Database Switcher

    func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }
}
