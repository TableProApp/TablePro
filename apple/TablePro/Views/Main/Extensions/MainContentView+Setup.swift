//
//  MainContentView+Setup.swift
//  TablePro
//
//  Extension containing initialization, command setup, and database switching
//  for MainContentView. Extracted to reduce main view complexity.
//

import os
import SwiftUI

extension MainContentView {
    // MARK: - Initialization

    func initializeAndRestoreTabs() async {
        guard !coordinator.hasRestoredTabs else {
            MainContentView.lifecycleLogger.info(
                "[open] initializeAndRestoreTabs skipped (already initialized) windowId=\(windowId, privacy: .public)"
            )
            return
        }
        coordinator.hasRestoredTabs = true
        let schemaTaskStart = Date()
        async let schemaLoad: Void = {
            await coordinator.loadSchemaIfNeeded()
            MainContentView.lifecycleLogger.info(
                "[open] loadSchemaIfNeeded done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(schemaTaskStart) * 1_000))"
            )
        }()

        if let payload {
            MainContentView.lifecycleLogger.info(
                "[open] initializeAndRestoreTabs intent=\(String(describing: payload.intent), privacy: .public) windowId=\(windowId, privacy: .public) skipAutoExecute=\(payload.skipAutoExecute)"
            )
            if payload.intent == .openContent {
                await prepareFoundingContent(skipAutoExecute: payload.skipAutoExecute)
            }
        }

        if payload == nil || payload?.intent == .restoreOrDefault {
            await coordinator.restoreSavedTabs()
        }
        // Before the schema load, which can take seconds, so a move waiting on the restore lands now.
        coordinator.settleTabRestore()
        _ = await schemaLoad
    }

    private func prepareFoundingContent(skipAutoExecute: Bool) async {
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
        if skipAutoExecute {
            await coordinator.rebuildSelectedTableQueryForHiddenColumnsIfNeeded()
            return
        }
        guard let selectedTab = tabManager.selectedTab,
              selectedTab.tabType == .table,
              !selectedTab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if let session = DatabaseManager.shared.activeSessions[connection.id], session.isConnected {
            coordinator.lazyLoadCurrentTabIfNeeded()
        } else {
            coordinator.parkedTableLoad = ParkedTableLoad(tabId: selectedTab.id, trigger: .userInitiated)
        }
    }

    // MARK: - Command Actions Setup

    // One resolution of what is staged, so commit, its verb and Preview SQL agree; staged principals once left Cmd+S dim.
    func updateToolbarPendingState() {
        let kind = PendingChangeKind.resolve(
            tabType: tabManager.selectedTab?.tabType,
            hasDataChanges: changeManager.hasChanges || !pendingTruncates.isEmpty || !pendingDeletes.isEmpty,
            hasStructureChanges: toolbarState.hasStructureChanges || toolbarState.hasTypeChanges
                || coordinator.selectedDiagramHasStagedEdits,
            hasCreateTablePending: toolbarState.hasCreateTablePending,
            hasPrincipalChanges: toolbarState.hasPrincipalChanges,
            isFileDirty: tabManager.selectedTab?.content.isFileDirty ?? false
        )
        toolbarState.pendingChange = kind
        toolbarState.hasPendingChanges = kind != nil
        // Narrower than the commit: a dirty query file and staged principals raise the commit but have no grid SQL to show.
        toolbarState.hasDataPendingChanges = kind == .data || kind == .structure
    }

    // The edited dot is written directly: the unsaved work it reports stays in the window under an agent conversation.
    func updateWindowTitleAndFileState() {
        let selectedTab = tabManager.selectedTab
        let resolved = WindowTitleResolver.resolveWindow(
            pane: .content,
            contentMode: .browse,
            agentSessionTitle: nil,
            connection: connection,
            tab: selectedTab,
            hasTabs: !tabManager.visibleTabs.isEmpty,
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

    // Called by WindowAccessor once the window exists.
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
        // `onAppear` refires on a connection switch; a second set of actions handled every broadcast twice and rebuilt both panes.
        guard commandActions == nil else { return }
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
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
