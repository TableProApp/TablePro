//
//  ScriptingSnapshot.swift
//  TablePro
//

import AppKit
import Foundation

/// Reads live app state into the value objects a script sees.
///
/// The scriptable objects stay dumb on purpose: they hold strings and codes, and every question that
/// needs the running app is answered here. That keeps one place to check when asking what a script
/// can see, which for a database client is the question that matters.
///
/// A connection whose **External Clients** level is Blocked is not listed at all, so a script cannot
/// discover its name, host or database, let alone read from it. That mirrors what the MCP surface
/// already does, and it is the reason `connections` is filtered rather than annotated.
@MainActor
internal enum ScriptingSnapshot {
    // MARK: - Connections

    internal static func connections() -> [ScriptConnection] {
        let sessions = DatabaseManager.shared.activeSessions
        return ConnectionStorage.shared.loadConnections()
            .filter { $0.externalAccess != .blocked }
            .sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { ScriptConnection(connection: $0, session: sessions[$0.id]) }
    }

    internal static func connection(withId id: UUID) -> ScriptConnection? {
        connections().first { $0.connectionId == id }
    }

    /// Whether a script may see this connection at all.
    ///
    /// Asked again on every path that can reach a connection without having resolved it through
    /// `connections()` first. `current tab` is the one that can: it starts from the front window,
    /// not from the element list, so without this a Blocked connection on screen would hand a script
    /// its tab and, through the tab, its rows.
    /// Read from storage rather than from the session, because nothing reconciles the level onto a
    /// live session, and a connection deleted while its session is still up is not visible at all.
    internal static func isVisibleToScripts(connectionId: UUID) -> Bool {
        guard let stored = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId })
        else {
            return false
        }
        return stored.externalAccess != .blocked
    }

    /// The connection the frontmost window is showing, which is what an unqualified script means by
    /// "the one I am looking at".
    internal static func currentConnection() -> ScriptConnection? {
        guard let id = frontmostCoordinator()?.connectionId else { return nil }
        return connection(withId: id)
    }

    // MARK: - Tabs

    internal static func tabs(forConnection connectionId: UUID) -> [ScriptTab] {
        guard isVisibleToScripts(connectionId: connectionId) else { return [] }
        let container = ScriptingSpecifiers.connection(uniqueId: connectionId.uuidString)
        return coordinators(forConnection: connectionId).flatMap { coordinator in
            coordinator.tabManager.tabs.map {
                ScriptTab(tab: $0, connectionId: connectionId, container: container)
            }
        }
    }

    internal static func currentTab() -> ScriptTab? {
        guard let coordinator = frontmostCoordinator(),
              let tab = coordinator.tabManager.selectedTab,
              isVisibleToScripts(connectionId: coordinator.connectionId)
        else {
            return nil
        }
        let connectionId = coordinator.connectionId
        return ScriptTab(
            tab: tab,
            connectionId: connectionId,
            container: ScriptingSpecifiers.connection(uniqueId: connectionId.uuidString)
        )
    }

    /// Waits for a table tab to appear after asking for it to be opened.
    ///
    /// Opening a tab runs through window creation and a connect, neither of which the router waits
    /// on, so a command that returned immediately would hand the script a reference to nothing. The
    /// deadline is what turns a connection that never opens into an error the script can catch
    /// rather than a wait that only ends at AppleScript's own two-minute timeout.
    internal static func awaitTab(
        connectionId: UUID,
        tableName: String,
        databaseName: String?,
        schemaName: String?,
        timeout: Duration = .seconds(8),
        pollInterval: Duration = .milliseconds(50),
        clock: ContinuousClock = ContinuousClock()
    ) async -> ScriptTab? {
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let match = tabs(forConnection: connectionId).first(where: {
                matches($0, tableName: tableName, databaseName: databaseName, schemaName: schemaName)
            }) {
                return match
            }
            try? await Task.sleep(for: pollInterval)
        }
        return nil
    }

    /// The table name alone is not an identity. Another database or schema on the same connection
    /// can have a table of the same name already open, and returning that one hands the script a
    /// reference to rows it did not ask for.
    private static func matches(
        _ tab: ScriptTab,
        tableName: String,
        databaseName: String?,
        schemaName: String?
    ) -> Bool {
        guard tab.kind == ScriptEnumerations.code(for: .table), tab.tableName == tableName else {
            return false
        }
        if let databaseName, tab.databaseName != databaseName { return false }
        if let schemaName, tab.schemaName != schemaName { return false }
        return true
    }

    /// Selecting the editor tab is not enough on its own. Its window can be showing a different
    /// connection, and it can be a background member of a native tab group, either of which leaves
    /// the tab hidden while the command reports success. The connection router already does all
    /// three; this does the same in the same order.
    @discardableResult
    internal static func focus(tab tabId: UUID, connectionId: UUID) -> Bool {
        guard isVisibleToScripts(connectionId: connectionId),
              let coordinator = coordinator(ofTab: tabId, connectionId: connectionId)
        else {
            return false
        }

        coordinator.tabManager.selectedTabId = tabId

        guard let windowId = coordinator.windowId,
              let window = WindowLifecycleMonitor.shared.window(for: windowId)
        else {
            coordinator.focusWindow()
            return true
        }
        if let host = window.contentViewController as? MainSplitViewController,
           host.workspaces.contains(connectionId) {
            host.selectHostedConnection(connectionId)
        }
        if let group = window.tabGroup, group.selectedWindow !== window {
            group.selectedWindow = window
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    internal static func query(ofTab tabId: UUID, connectionId: UUID) -> String? {
        guard isVisibleToScripts(connectionId: connectionId) else { return nil }
        return coordinator(ofTab: tabId, connectionId: connectionId)?
            .tabManager.tabs.first { $0.id == tabId }?.content.query
    }

    // MARK: - Results

    /// The rows a tab is showing, or only the ones selected in its grid.
    ///
    /// Selection indices are display positions, not indices into the row buffer, so they are
    /// resolved through `DisplayedResultReader` rather than used to subscript anything.
    internal static func result(
        ofTab tabId: UUID,
        connectionId: UUID,
        selectedOnly: Bool
    ) -> [String: Any] {
        guard isVisibleToScripts(connectionId: connectionId),
              let coordinator = coordinator(ofTab: tabId, connectionId: connectionId),
              let tab = coordinator.tabManager.tabs.first(where: { $0.id == tabId })
        else {
            return ScriptResultEncoder.empty()
        }

        /// The live grid only answers for the tab it is mounted in, and only while a data grid owns
        /// its selection: in Structure or Chart mode those indices belong to the schema grid or are
        /// left over from the last data grid, and applying them to the row buffer returns unrelated
        /// rows. Every other tab's selection is the one persisted on the tab itself.
        let isSelectedTab = coordinator.tabManager.selectedTabId == tabId
        let ownsLiveSelection = isSelectedTab && GridSelectionOwner.resolve(
            tabType: tab.tabType,
            resultsViewMode: tab.display.resultsViewMode
        ) == .dataGrid
        let selected = selectedOnly
            ? (ownsLiveSelection ? coordinator.selectionState.indices : tab.selectedRowIndices)
            : []
        if selectedOnly, selected.isEmpty {
            return ScriptResultEncoder.empty()
        }

        /// A row marked for deletion is still in the buffer and is deliberately not in the result the
        /// grid is showing, so it is not in what a script reads either.
        let deleted = isSelectedTab
            ? coordinator.changeManager.deletedRowIndices
            : tab.pendingChanges.deletedRowIndices

        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tabId)
        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: coordinator.displayIDs(forTab: tabId),
            selectedDisplayIndices: selected,
            deletedDisplayIndices: deleted,
            columns: .fromColumnLayout(tab.columnLayout, columns: tableRows.columns)
        )
        let metadata = tab.display.activeResultSet.map {
            ScriptResultEncoder.Metadata(
                rowsAffected: $0.rowsAffected,
                truncated: $0.isTruncated,
                executionTimeMs: ($0.executionTime ?? 0) * 1_000,
                statusMessage: $0.statusMessage
            )
        } ?? .none
        return ScriptResultEncoder.encode(read, metadata: metadata)
    }

    // MARK: - Lookup

    nonisolated internal static func uuid(from value: Any) -> UUID? {
        if let uuid = value as? UUID { return uuid }
        if let string = value as? String { return UUID(uuidString: string) }
        return nil
    }

    private static func coordinators(forConnection connectionId: UUID) -> [MainContentCoordinator] {
        MainContentCoordinator.allActiveCoordinators().filter { $0.connectionId == connectionId }
    }

    private static func coordinator(ofTab tabId: UUID, connectionId: UUID) -> MainContentCoordinator? {
        coordinators(forConnection: connectionId).first { coordinator in
            coordinator.tabManager.tabs.contains { $0.id == tabId }
        }
    }

    /// One window hosts several connections, so every one of their coordinators reports the same
    /// `contentWindow` and picking the first match returns an arbitrary one. `coordinator(forWindow:)`
    /// asks the window which workspace it is showing, which is the only thing "the one I am looking
    /// at" can mean.
    private static func frontmostCoordinator() -> MainContentCoordinator? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let match = MainContentCoordinator.coordinator(forWindow: window) {
                return match
            }
        }
        return NSApp.orderedWindows
            .lazy
            .compactMap { MainContentCoordinator.coordinator(forWindow: $0) }
            .first
    }
}
