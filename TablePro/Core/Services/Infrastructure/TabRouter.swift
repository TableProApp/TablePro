//
//  TabRouter.swift
//  TablePro
//

import AppKit
import Foundation
import os

internal enum TabRouterError: Error, LocalizedError {
    case connectionNotFound(UUID)
    case malformedDatabaseURL(URL)
    case fileNoLongerExists(URL)
    case userCancelled
    case unsupportedIntent(String)

    internal var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id):
            return String(
                format: String(localized: "No saved connection with ID \"%@\"."), id.uuidString
            )
        case .malformedDatabaseURL(let url):
            return String(
                format: String(localized: "Could not parse database URL: %@"), url.sanitizedForLogging
            )
        case .fileNoLongerExists(let url):
            return String(
                format: String(localized: "“%@” is no longer at that location."), url.lastPathComponent
            )
        case .userCancelled:
            return String(localized: "Cancelled by user.")
        case .unsupportedIntent(let detail):
            return String(format: String(localized: "Unsupported intent: %@"), detail)
        }
    }
}

@MainActor
internal final class TabRouter {
    internal static let shared = TabRouter()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TabRouter")

    private let externalConnectionGate: ExternalConnectionGate

    private init(externalConnectionGate: ExternalConnectionGate? = nil) {
        self.externalConnectionGate = externalConnectionGate ?? ExternalConnectionGate()
    }

    internal func route(_ intent: LaunchIntent) async throws {
        switch intent {
        case .openConnection(let id):
            try await openConnection(id: id)

        case .openTable(let id, let database, let schema, let table, let isView):
            try await openTable(
                connectionId: id, transientConnection: nil,
                database: database, schema: schema, table: table, isView: isView
            )

        case .openQuery(let id, let sql):
            try await openQuery(connectionId: id, sql: sql)

        case .openDatabaseURL(let url):
            try await openDatabaseURL(url)

        case .openDatabaseFile(let url, let type):
            try await openDatabaseFile(url, type: type)

        case .openSQLFile(let url):
            try await openSQLFile(url)

        case .reopenClosedTab(let entry):
            try await reopenClosedTab(entry)

        default:
            throw TabRouterError.unsupportedIntent(String(describing: intent))
        }
    }

    // MARK: - Recently Closed

    private func reopenClosedTab(_ entry: RecentlyClosedTabEntry) async throws {
        guard let connection = ConnectionStorage.shared.loadConnections()
            .first(where: { $0.id == entry.connectionId }) else {
            throw TabRouterError.connectionNotFound(entry.connectionId)
        }
        try await runPreConnectScriptIfNeeded(connection)
        try await DatabaseManager.shared.ensureConnected(connection)
        RecentlyClosedTabReopener.openWindowTab(for: entry)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()
    }

    // MARK: - Connection

    internal func openTransientConnection(_ connection: DatabaseConnection) async throws {
        try await openConnection(id: connection.id, transientConnection: connection)
    }

    /// Open a saved connection in a window of its own. One some window already hosts takes the
    /// ordinary route instead, which selects it where it already is.
    ///
    /// The host is checked here rather than by the caller. A caller decides on a modifier key and
    /// the work runs a main-actor job later, and anything else that opens a connection in between,
    /// the MCP tool among them, would leave that answer stale and two workspaces restoring the same
    /// tabs. Nothing is awaited between the question and the window.
    ///
    /// No pre-connect script prompt here, matching the window-opening half of `openConnection`. A
    /// window whose connection carries a script does not auto-connect at all: it waits in its
    /// not-connected state, where Connect asks. Asking first would put the same question twice and
    /// the first answer would change nothing.
    internal func openConnectionPreferringNewWindow(id: UUID) async throws {
        guard WindowManager.shared.window(for: id) == nil else {
            try await openConnection(id: id)
            return
        }
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == id }) else {
            throw TabRouterError.connectionNotFound(id)
        }

        let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        WindowManager.shared.openInNewWindow(
            payload: payload,
            activate: true,
            autoConnect: true,
            joinsTabGroup: false
        )
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()
    }

    private func openConnection(id: UUID, transientConnection: DatabaseConnection? = nil) async throws {
        let connection: DatabaseConnection
        if let stored = ConnectionStorage.shared.loadConnections().first(where: { $0.id == id }) {
            connection = stored
        } else if let transientConnection {
            connection = transientConnection
        } else {
            throw TabRouterError.connectionNotFound(id)
        }
        if let existing = WindowLifecycleMonitor.shared.mostRecentWindow(for: id)
            ?? WindowManager.shared.window(for: id) {
            /// A window that is a background member of a tab group is one AppKit will make key
            /// without bringing to the front of its group, so the tab has to be selected first or
            /// the user is left looking at a different one.
            if let group = existing.tabGroup, group.selectedWindow !== existing {
                group.selectedWindow = existing
            }
            existing.makeKeyAndOrderFront(nil)
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            WindowOpener.shared.closeWelcome()
            let host = existing.contentViewController as? MainSplitViewController
            /// Raising the window is not the same as showing the connection the user picked, and a
            /// window hosts several. Without this, choosing a connected one from the connection list
            /// re-fronted a window still showing a different connection and stopped there.
            if let host, host.workspaces.contains(id) {
                host.selectHostedConnection(id)
            }
            guard DatabaseManager.shared.activeSessions[id]?.driver == nil else { return }
            if let host, host.workspaces.contains(id) {
                host.reconnectWorkspace(id)
            } else {
                try await runPreConnectScriptIfNeeded(connection)
                try await DatabaseManager.shared.ensureConnected(connection)
            }
            return
        }
        let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        if transientConnection != nil {
            DatabaseManager.shared.registerPendingSession(connection)
        }
        WindowManager.shared.openTab(payload: payload, autoConnect: true)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()
    }

    // MARK: - Table

    private func openTable(
        connectionId: UUID, transientConnection: DatabaseConnection? = nil,
        database: String?, schema: String?, table: String, isView: Bool,
        passwordOverride: String? = nil, sshPasswordOverride: String? = nil
    ) async throws {
        let connection: DatabaseConnection
        if let transientConnection {
            connection = transientConnection
        } else if let stored = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) {
            connection = stored
        } else {
            throw TabRouterError.connectionNotFound(connectionId)
        }
        if focusExistingTableTab(connectionId: connectionId, database: database, schema: schema, table: table) {
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            WindowOpener.shared.closeWelcome()
            return
        }

        try await runPreConnectScriptIfNeeded(connection)

        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .table,
            tableName: table,
            databaseName: database,
            schemaName: schema,
            isView: isView
        )
        DatabaseManager.shared.registerPendingSession(connection)
        WindowManager.shared.openTab(payload: payload)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()

        try await DatabaseManager.shared.ensureConnected(
            connection,
            passwordOverride: passwordOverride,
            sshPasswordOverride: sshPasswordOverride
        )

        await applyContainerSwitch(connectionId: connectionId, database: database, schema: schema)
    }

    private func focusExistingTableTab(
        connectionId: UUID, database: String?, schema: String?, table: String
    ) -> Bool {
        for coordinator in MainContentCoordinator.allActiveCoordinators()
            where coordinator.connectionId == connectionId {
            guard let match = coordinator.tabManager.tabs.first(where: { tab in
                guard tab.tabType == .table,
                      tab.tableContext.tableName == table else { return false }
                let databaseMatches = database.map { db in
                    tab.tableContext.databaseName == db
                } ?? true
                let schemaMatches = schema.map { sch in
                    tab.tableContext.schemaName.map { $0 == sch } ?? false
                } ?? true
                return databaseMatches && schemaMatches
            }) else { continue }
            coordinator.selectTabAndFocusWindow(match.id)
            return true
        }
        return false
    }

    // MARK: - Query

    private func openQuery(connectionId: UUID, sql: String) async throws {
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) else {
            throw TabRouterError.connectionNotFound(connectionId)
        }

        let preview = previewForSQL(sql)
        let confirmed = await AlertHelper.runApprovalModal(
            title: String(localized: "Open Query from Link"),
            message: String(
                format: String(localized: "An external link wants to open a query on \"%@\":\n\n%@"),
                connection.name, preview
            ),
            confirm: String(localized: "Open Query"),
            cancel: String(localized: "Cancel")
        )
        guard confirmed else { throw TabRouterError.userCancelled }

        if focusExistingQueryTab(connectionId: connectionId, sql: sql) {
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            WindowOpener.shared.closeWelcome()
            return
        }

        try await runPreConnectScriptIfNeeded(connection)

        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .query,
            initialQuery: sql
        )
        DatabaseManager.shared.registerPendingSession(connection)
        WindowManager.shared.openTab(payload: payload)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()

        try await DatabaseManager.shared.ensureConnected(connection)
    }

    private func focusExistingQueryTab(connectionId: UUID, sql: String) -> Bool {
        for coordinator in MainContentCoordinator.allActiveCoordinators()
            where coordinator.connectionId == connectionId {
            let match = coordinator.tabManager.tabs.first { tab in
                tab.tabType == .query && tab.content.query == sql
            }
            guard let match else { continue }
            coordinator.tabManager.selectedTabId = match.id
            if let windowId = coordinator.windowId,
               let window = WindowLifecycleMonitor.shared.window(for: windowId) {
                window.makeKeyAndOrderFront(nil)
            }
            return true
        }
        return false
    }

    private func previewForSQL(_ sql: String) -> String {
        let nsSQL = sql as NSString
        guard nsSQL.length > 300 else { return sql }
        let head = nsSQL.substring(to: 300)
        let hidden = nsSQL.length - 300
        return head + String(format: String(localized: "\n\n… (%d more characters not shown)"), hidden)
    }

    // MARK: - Database URL

    private func openDatabaseURL(_ url: URL) async throws {
        guard case .success(let parsed) = ConnectionURLParser.parse(url.absoluteString) else {
            throw TabRouterError.malformedDatabaseURL(url)
        }

        let connections = ConnectionStorage.shared.loadConnections()
        let matched = connections.first { conn in
            conn.type == parsed.type
                && conn.host == parsed.host
                && (parsed.port == nil || conn.port == parsed.port)
                && conn.database == parsed.database
                && (parsed.username.isEmpty || conn.username == parsed.username)
        }

        let connection: DatabaseConnection
        let isTransient: Bool
        if let matched {
            connection = matched
            isTransient = false
        } else {
            connection = TransientConnectionFactory.build(from: parsed)
            isTransient = true
        }

        guard await externalConnectionGate.authorize(connection, scopeName: parsed.connectionName) else {
            throw TabRouterError.userCancelled
        }

        let passwordOverride = parsed.password.isEmpty ? nil : parsed.password
        let sshPasswordOverride = parsed.sshPassword.flatMap { $0.isEmpty ? nil : $0 }

        if let table = parsed.tableName {
            try await openTable(
                connectionId: connection.id,
                transientConnection: isTransient ? connection : nil,
                database: parsed.database.isEmpty ? nil : parsed.database,
                schema: parsed.schema,
                table: table,
                isView: parsed.isView,
                passwordOverride: passwordOverride,
                sshPasswordOverride: sshPasswordOverride
            )
            if parsed.filterColumn != nil || parsed.filterCondition != nil {
                try await applyFilterFromParsedURL(parsed: parsed, connectionId: connection.id)
            }
            return
        }

        try await runPreConnectScriptIfNeeded(connection)
        let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        DatabaseManager.shared.registerPendingSession(connection)
        WindowManager.shared.openTab(payload: payload)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()
        try await DatabaseManager.shared.ensureConnected(
            connection,
            passwordOverride: passwordOverride,
            sshPasswordOverride: sshPasswordOverride
        )

        await applyContainerSwitch(
            connectionId: connection.id, database: nil, schema: parsed.schema
        )
    }

    // MARK: - Database File

    /// A driver that opens a local file keeps the path in whichever field it declares, and DuckDB
    /// and libSQL leave `database` empty. Reading it directly missed a live session on the same
    /// file, and a second `duckdb_open` is an independent read-write instance whose writes the
    /// first one never sees.
    private func openDatabaseFile(_ url: URL, type: DatabaseType) async throws {
        let filePath = url.path(percentEncoded: false)
        let connectionName = url.deletingPathExtension().lastPathComponent
        let pathField = PluginManager.shared.localFilePathField(for: type) ?? .database

        for (sessionId, session) in DatabaseManager.shared.activeSessions
        where session.connection.type == type
            && session.connection.localFilePath(in: pathField) == filePath
            && session.driver != nil {
            bringConnectionWindowToFront(sessionId)
            return
        }

        guard await MissingDriverPluginPrompt.ensureInstalled(for: type, opening: url) else {
            throw TabRouterError.userCancelled
        }

        /// Installing the driver can take long enough for the file to be renamed or removed under
        /// us, and both engines create a database at a path that no longer exists. An empty one
        /// left where the original stood is worse than reporting that it is gone.
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw TabRouterError.fileNoLongerExists(url)
        }

        let connection = DatabaseConnection(
            name: connectionName,
            host: "",
            port: 0,
            database: "",
            username: "",
            type: type
        ).substitutingLocalFilePath(filePath, in: pathField)

        let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        DatabaseManager.shared.registerPendingSession(connection)
        WindowManager.shared.openTab(payload: payload)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        WindowOpener.shared.closeWelcome()
        try await DatabaseManager.shared.ensureConnected(connection)
    }

    // MARK: - SQL File

    private func openSQLFile(_ url: URL) async throws {
        if let existing = WindowLifecycleMonitor.shared.window(forSourceFile: url) {
            existing.makeKeyAndOrderFront(nil)
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            return
        }

        if let session = DatabaseManager.shared.lastActiveSession {
            let content = await Task.detached(priority: .userInitiated) { () -> String? in
                try? String(contentsOf: url, encoding: .utf8)
            }.value
            guard let content else {
                Self.logger.error("Failed to read SQL file: \(url.lastPathComponent, privacy: .public)")
                return
            }
            let payload = EditorTabPayload(
                connectionId: session.connection.id,
                tabType: .query,
                initialQuery: content,
                sourceFileURL: url
            )
            WindowManager.shared.openTab(payload: payload)
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        } else {
            WelcomeRouter.shared.enqueueSQLFile(url)
        }
    }

    // MARK: - Helpers

    internal func bringConnectionWindowToFront(_ connectionId: UUID) {
        if let window = WindowLifecycleMonitor.shared.mostRecentWindow(for: connectionId) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
    }

    private func applyContainerSwitch(connectionId: UUID, database: String?, schema: String?) async {
        guard let coordinator = MainContentCoordinator.allActiveCoordinators()
            .first(where: { $0.connectionId == connectionId }) else { return }
        await coordinator.switchContainers(database: database, schema: schema)
    }

    private func runPreConnectScriptIfNeeded(_ connection: DatabaseConnection) async throws {
        guard await PreConnectScriptPrompt.confirmIfNeeded(for: connection) else {
            throw TabRouterError.userCancelled
        }
    }

    private func applyFilterFromParsedURL(parsed: ParsedConnectionURL, connectionId: UUID) async throws {
        let description: String
        if let condition = parsed.filterCondition, !condition.isEmpty {
            description = (condition as NSString).length > 300
                ? String(condition.prefix(300)) + "…" : condition
        } else {
            description = [parsed.filterColumn, parsed.filterOperation, parsed.filterValue]
                .compactMap { $0 }.joined(separator: " ")
        }
        if !description.isEmpty {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Apply Filter from Link"),
                message: String(
                    format: String(localized: "An external link wants to apply a filter:\n\n%@"),
                    description
                ),
                confirmButton: String(localized: "Apply Filter"),
                cancelButton: String(localized: "Cancel"),
                window: NSApp.keyWindow
            )
            guard confirmed else { throw TabRouterError.userCancelled }
        }

        guard let coordinator = MainContentCoordinator.allActiveCoordinators()
            .first(where: { $0.connectionId == connectionId }) else { return }
        coordinator.applyURLFilter(
            condition: parsed.filterCondition,
            column: parsed.filterColumn,
            operation: parsed.filterOperation,
            value: parsed.filterValue
        )
    }
}
