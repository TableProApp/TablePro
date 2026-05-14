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

        await handleRestoreOrDefault()
        _ = await schemaLoad
    }

    private func handleRestoreOrDefault() async {
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
                        "[open] buildBaseTableQuery failed for restored tab table=\(tableName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }

        tabManager.tabs = restoredTabs
        let selectedId = result.selectedTabId.flatMap { id in
            restoredTabs.contains(where: { $0.id == id }) ? id : nil
        }
        tabManager.selectedTabId = selectedId ?? restoredTabs.first?.id

        for tab in restoredTabs {
            if let sourceURL = tab.content.sourceFileURL {
                WindowLifecycleMonitor.shared.registerSourceFile(sourceURL, windowId: windowId)
            }
        }

        guard let selectedTab = tabManager.selectedTab,
              selectedTab.tabType == .table,
              !selectedTab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        if let session = DatabaseManager.shared.activeSessions[connection.id], session.isConnected {
            if !selectedTab.tableContext.databaseName.isEmpty,
               selectedTab.tableContext.databaseName != session.activeDatabase {
                Task { await coordinator.switchDatabase(to: selectedTab.tableContext.databaseName) }
            } else {
                if let tableName = selectedTab.tableContext.tableName {
                    coordinator.restoreLastHiddenColumnsForTable(tableName)
                }
                coordinator.executeTableTabQueryDirectly()
            }
        } else {
            coordinator.needsLazyLoad = true
        }
    }

    // MARK: - Command Actions Setup

    func updateToolbarPendingState() {
        let hasDataChanges =
            changeManager.hasChanges
            || !pendingTruncates.isEmpty
            || !pendingDeletes.isEmpty
            || toolbarState.hasStructureChanges
        let hasFileChanges = tabManager.selectedTab?.content.isFileDirty ?? false
        toolbarState.hasDataPendingChanges = hasDataChanges
        toolbarState.hasPendingChanges = hasDataChanges || hasFileChanges
    }

    /// Refresh the window title, proxy icon, and dirty dot. Delegates to
    /// `ConnectionWindowController.refreshWindowTitle()` — the single source of
    /// truth for window-title resolution.
    func updateWindowTitleAndFileState() {
        (viewWindow?.windowController as? ConnectionWindowController)?.refreshWindowTitle()
    }

    /// Configure the hosting NSWindow — called by WindowAccessor when the window is available.
    func configureWindow(_ window: NSWindow) {
        let start = Date()
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow start windowId=\(windowId, privacy: .public) connId=\(connection.id, privacy: .public)"
        )
        window.subtitle = connection.name
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
        window.representedURL = tabManager.selectedTab?.content.sourceFileURL
        window.isDocumentEdited = tabManager.selectedTab?.content.isFileDirty ?? false

        // Update command actions window reference now that it's available
        commandActions?.window = window

        // Publish command actions to the registry NOW. `windowDidBecomeKey`
        // also publishes, but for the first window after welcome→connect the
        // coordinator's `contentWindow` isn't set when AppKit's first
        // becomeKey fires — `coordinator(forWindow:)` returns nil and the
        // publish is skipped. configureWindow IS the moment the coordinator
        // gets linked to its NSWindow, so this is the earliest reliable
        // point to publish.
        //
        // No `window.isKeyWindow` guard: when this method runs, the window
        // has been ordered front but isn't yet key (becomeKey fires after
        // a runloop tick). We trust that newly opened windows will become
        // key shortly; overwriting from a non-key window is acceptable
        // because the next becomeKey on any window will rewrite the
        // registry anyway.
        if let actions = commandActions {
            CommandActionsRegistry.shared.current = actions
        }

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.installToolbar(coordinator: coordinator)
        }
        MainContentView.lifecycleLogger.info(
            "[open] configureWindow done windowId=\(windowId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(start) * 1_000))"
        )
    }

    func setupCommandActions() {
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(
                get: { sidebarState.selectedTables },
                set: { sidebarState.selectedTables = $0 }
            ),
            pendingTruncates: $pendingTruncates,
            pendingDeletes: $pendingDeletes,
            tableOperationOptions: $tableOperationOptions,
            rightPanelState: rightPanelState
        )
        actions.window = viewWindow
        coordinator.commandActions = actions
        commandActions = actions
    }

    // MARK: - Database Switcher

    func switchDatabase(to database: String) {
        Task {
            await coordinator.switchDatabase(to: database)
        }
    }
}
