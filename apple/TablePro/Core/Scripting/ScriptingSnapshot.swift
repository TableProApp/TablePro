//
//  ScriptingSnapshot.swift
//  TablePro
//

import AppKit
import Foundation

// The one place a script's view of the app is decided. A Blocked External Clients connection is dropped, the same list MCP reads.
@MainActor
internal enum ScriptingSnapshot {
    // MARK: - Connections

    internal static func connections() -> [ScriptConnection] {
        ExternalConnectionDirectory.listings().map(ScriptConnection.init(listing:))
    }

    internal static func connection(withId id: UUID) -> ScriptConnection? {
        connections().first { $0.connectionId == id }
    }

    // Rechecked on paths that skip `connections()` (current tab). Read from storage: nothing syncs the level onto a live session.
    internal static func isVisibleToScripts(connectionId: UUID) -> Bool {
        guard let stored = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId })
        else {
            return false
        }
        return stored.externalAccess != .blocked
    }

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

    // The router doesn't wait on window creation or connect; the deadline beats AppleScript's two-minute timeout with a catchable error.
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

    // Name alone isn't identity: a same-named table in another database or schema may be open. Omitted parts mean the browsed one.
    private static func matches(
        _ tab: ScriptTab,
        tableName: String,
        databaseName: String?,
        schemaName: String?
    ) -> Bool {
        guard tab.kind == ScriptEnumerations.code(for: .table),
              let tabTable = tab.tableName,
              tabTable == tableName
        else { return false }
        let databaseManager = DatabaseManager.shared
        let wanted = databaseManager.requestedTableIdentity(
            table: tableName, database: databaseName, schema: schemaName, for: tab.connectionId
        )
        let browseDatabase = databaseManager.activeSessions[tab.connectionId]?.resolvedBrowseDatabase ?? ""
        return TableTabIdentity(
            table: tabTable,
            database: tab.databaseName ?? browseDatabase,
            schema: tab.schemaName
        ) == wanted
    }

    @discardableResult
    internal static func focus(tab tabId: UUID, connectionId: UUID) -> Bool {
        guard isVisibleToScripts(connectionId: connectionId),
              let coordinator = coordinator(ofTab: tabId, connectionId: connectionId)
        else {
            return false
        }
        coordinator.selectTabAndFocusWindow(tabId)
        return true
    }

    internal static func query(ofTab tabId: UUID, connectionId: UUID) -> String? {
        guard isVisibleToScripts(connectionId: connectionId) else { return nil }
        return coordinator(ofTab: tabId, connectionId: connectionId)?
            .tabManager.tabs.first { $0.id == tabId }?.content.query
    }

    // MARK: - Results

    // Selection indices are display positions, so they resolve through `DisplayedResultReader` and never subscript the buffer.
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

        // Each data tab's model keeps its own selection, mounted or not, so every tab answers for itself.
        let isSelectedTab = coordinator.tabManager.selectedTabId == tabId
        let selection = coordinator.existingGridModel(forTab: tabId)?.selection.affectedRows ?? IndexSet()
        let selected = selectedOnly ? Set(selection) : []
        if selectedOnly, selected.isEmpty {
            return ScriptResultEncoder.empty()
        }

        // A row marked for deletion stays in the buffer but not in the grid's result, so a script doesn't read it either.
        let deleted = isSelectedTab
            ? coordinator.changeManager.deletedRowIDs
            : tab.pendingChanges.deletedRowIDs

        let tableRows = coordinator.tabSessionRegistry.tableRows(for: tabId)
        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: coordinator.displayIDs(forTab: tabId),
            selectedDisplayIndices: selected,
            deletedRowIDs: deleted,
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

    // One window hosts several connections that share `contentWindow`; `coordinator(forWindow:)` asks which workspace it shows.
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
