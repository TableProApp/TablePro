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
        /// Before the schema load, which can take seconds, so a move waiting on the restore lands now.
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
            coordinator.pendingLoadTrigger = .userInitiated
        }
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
        /// Called from `onAppear`, which a connection switch fires again. Building a second set of
        /// actions left the hidden trailing pane holding the first, so every refresh and connect
        /// broadcast was handled twice, and both trailing panes were rebuilt on every switch.
        guard commandActions == nil else { return }
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
