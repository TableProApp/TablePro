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

    private static let logger = Logger(subsystem: "com.TablePro", category: "TabRouter")

    private init() {}

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

        default:
            throw TabRouterError.unsupportedIntent(String(describing: intent))
        }
    }

    // MARK: - Connection

    private func openConnection(id: UUID) async throws {
        guard let connection = ConnectionStorage.shared.loadConnections().first(where: { $0.id == id }) else {
            throw TabRouterError.connectionNotFound(id)
        }
        if let existing = WindowLifecycleMonitor.shared.findWindow(for: id) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await DatabaseManager.shared.ensureConnected(connection)
            closeWelcomeWindows()
            return
        }
        try await runPreConnectScriptIfNeeded(connection)
        let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        WindowManager.shared.openTab(payload: payload)
        NSApp.activate(ignoringOtherApps: true)
        try await DatabaseManager.shared.ensureConnected(connection)
        closeWelcomeWindows()
    }

    // MARK: - Table

    private func openTable(
        connectionId: UUID, transientConnection: DatabaseConnection? = nil,
        database: String?, schema: String?, table: String, isView: Bool
    ) async throws {
        let connection: DatabaseConnection
        if let transientConnection {
            connection = transientConnection
        } else if let stored = ConnectionStorage.shared.loadConnections().first(where: { $0.id == connectionId }) {
            connection = stored
        } else {
            throw TabRouterError.connectionNotFound(connectionId)
        }
        try await runPreConnectScriptIfNeeded(connection)
        try await DatabaseManager.shared.ensureConnected(connection)

        if let schema {
            await switchSchemaOrDatabase(connectionId: connectionId, target: schema)
        } else if let database {
            await switchSchemaOrDatabase(connectionId: connectionId, target: database)
        }

        if focusExistingTableTab(connectionId: connectionId, database: database, schema: schema, table: table) {
            NSApp.activate(ignoringOtherApps: true)
            closeWelcomeWindows()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .table,
            tableName: table,
            databaseName: database,
            schemaName: schema,
            isView: isView
        )
        WindowManager.shared.openTab(payload: payload)
        NSApp.activate(ignoringOtherApps: true)
        closeWelcomeWindows()
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
            coordinator.tabManager.selectedTabId = match.id
            if let windowId = coordinator.windowId,
               let window = WindowLifecycleMonitor.shared.window(for: windowId) {
                window.makeKeyAndOrderFront(nil)
            }
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

        try await runPreConnectScriptIfNeeded(connection)
        try await DatabaseManager.shared.ensureConnected(connection)

        if focusExistingQueryTab(connectionId: connectionId, sql: sql) {
            NSApp.activate(ignoringOtherApps: true)
            closeWelcomeWindows()
            return
        }

        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: .query,
            initialQuery: sql
        )
        WindowManager.shared.openTab(payload: payload)
        NSApp.activate(ignoringOtherApps: true)
        closeWelcomeWindows()
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

        if !parsed.password.isEmpty {
            ConnectionStorage.shared.savePassword(parsed.password, for: connection.id)
        }
        if let sshPass = parsed.sshPassword, !sshPass.isEmpty {
            ConnectionStorage.shared.saveSSHPassword(sshPass, for: connection.id)
        }

        do {
            if let table = parsed.tableName {
                try await openTable(
                    connectionId: connection.id,
                    transientConnection: isTransient ? connection : nil,
                    database: parsed.database.isEmpty ? nil : parsed.database,
                    schema: parsed.schema,
                    table: table,
                    isView: parsed.isView
                )
                if parsed.filterColumn != nil || parsed.filterCondition != nil {
                    try await applyFilterFromParsedURL(parsed: parsed, connectionId: connection.id)
                }
                return
            }

            try await runPreConnectScriptIfNeeded(connection)
            let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
            WindowManager.shared.openTab(payload: payload)
            NSApp.activate(ignoringOtherApps: true)
            try await DatabaseManager.shared.ensureConnected(connection)
            closeWelcomeWindows()

            if let schema = parsed.schema {
                await switchSchemaOrDatabase(connectionId: connection.id, target: schema)
            }
        } catch {
            if isTransient {
                ConnectionStorage.shared.deletePassword(for: connection.id)
                ConnectionStorage.shared.deleteSSHPassword(for: connection.id)
            }
            throw error
        }
    }

    // MARK: - Database File

    private func openDatabaseFile(_ url: URL, type: DatabaseType) async throws {
        let filePath = url.path(percentEncoded: false)
        let connectionName = url.deletingPathExtension().lastPathComponent

        for (sessionId, session) in DatabaseManager.shared.activeSessions
        where session.connection.type == type
            && session.connection.database == filePath
            && session.driver != nil {
            bringConnectionWindowToFront(sessionId)
            return
        }

        let connection = DatabaseConnection(
            name: connectionName,
            host: "",
            port: 0,
            database: filePath,
            username: "",
            type: type
        )

        let payload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        WindowManager.shared.openTab(payload: payload)
        NSApp.activate(ignoringOtherApps: true)
        try await DatabaseManager.shared.ensureConnected(connection)
        closeWelcomeWindows()
    }

    // MARK: - SQL File

    private func openSQLFile(_ url: URL) async throws {
        if let existing = WindowLifecycleMonitor.shared.window(forSourceFile: url) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let session = DatabaseManager.shared.currentSession {
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
            NSApp.activate(ignoringOtherApps: true)
        } else {
            WelcomeRouter.shared.enqueueSQLFile(url)
        }
    }

    // MARK: - Helpers

    internal func bringConnectionWindowToFront(_ connectionId: UUID) {
        let windows = WindowLifecycleMonitor.shared.windows(for: connectionId)
        if let window = windows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func switchSchemaOrDatabase(connectionId: UUID, target: String) async {
        guard let coordinator = MainContentCoordinator.allActiveCoordinators()
            .first(where: { $0.connectionId == connectionId }) else { return }
        if PluginManager.shared.supportsSchemaSwitching(for: coordinator.connection.type) {
            await coordinator.switchSchema(to: target)
        } else {
            await coordinator.switchDatabase(to: target)
        }
    }

    private func runPreConnectScriptIfNeeded(_ connection: DatabaseConnection) async throws {
        guard let script = connection.preConnectScript,
              !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let confirmed = await AlertHelper.confirmDestructive(
            title: String(localized: "Pre-Connect Script"),
            message: String(
                format: String(localized: "Connection \"%@\" has a script that will run before connecting:\n\n%@"),
                connection.name, script
            ),
            confirmButton: String(localized: "Run Script"),
            cancelButton: String(localized: "Cancel"),
            window: NSApp.keyWindow
        )
        guard confirmed else { throw TabRouterError.userCancelled }
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

    private func closeWelcomeWindows() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.close()
        }
    }
}
