//
//  AppDelegate+FileOpen.swift
//  TablePro
//
//  URL and file open handling dispatched from application(_:open:)
//

import AppKit
import os
import SwiftUI

private let fileOpenLogger = Logger(subsystem: "com.TablePro", category: "FileOpen")

extension AppDelegate {
    // MARK: - Handoff

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        handleHandoffActivity(userActivity)
        return true
    }

    private func handleHandoffActivity(_ activity: NSUserActivity) {
        guard let connectionIdString = activity.userInfo?["connectionId"] as? String,
              let connectionId = UUID(uuidString: connectionIdString) else { return }

        let connections = ConnectionStorage.shared.loadConnections()
        guard let connection = connections.first(where: { $0.id == connectionId }) else {
            fileOpenLogger.error("Handoff: no connection with ID '\(connectionIdString, privacy: .public)'")
            return
        }

        let tableName = activity.userInfo?["tableName"] as? String

        // Already connected — route to existing window's in-app tab bar
        if DatabaseManager.shared.activeSessions[connectionId]?.driver != nil {
            if let tableName {
                let payload = EditorTabPayload(connectionId: connectionId, tabType: .table, tableName: tableName)
                if !routeToExistingWindow(connectionId: connectionId, payload: payload) {
                    WindowOpener.shared.openNativeTab(payload)
                }
            } else {
                bringConnectionWindowToFront(connectionId)
            }
            return
        }

        // Window already pending (e.g., auto-reconnect in progress) — just bring to front
        let hasPending = WindowOpener.shared.pendingPayloads.contains { $0.connectionId == connectionId }
        if hasPending {
            bringConnectionWindowToFront(connectionId)
            return
        }

        // Not connected — create window, connect, then route content as in-app tab
        let initialPayload = EditorTabPayload(connectionId: connectionId, intent: .restoreOrDefault)
        WindowOpener.shared.openNativeTab(initialPayload)

        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                self.closeAllWelcomeWindows()
                if let tableName {
                    let payload = EditorTabPayload(connectionId: connectionId, tabType: .table, tableName: tableName)
                    if !routeToExistingWindow(connectionId: connectionId, payload: payload) {
                        WindowOpener.shared.openNativeTab(payload)
                    }
                }
            } catch {
                fileOpenLogger.error("Handoff connect failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - URL Classification

    private func isDatabaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        let base = scheme
            .replacingOccurrences(of: "+ssh", with: "")
            .replacingOccurrences(of: "+srv", with: "")
        let registeredSchemes = PluginManager.shared.allRegisteredURLSchemes
        return registeredSchemes.contains(base) || registeredSchemes.contains(scheme)
    }

    private func isDatabaseFile(_ url: URL) -> Bool {
        PluginManager.shared.allRegisteredFileExtensions[url.pathExtension.lowercased()] != nil
    }

    private func databaseTypeForFile(_ url: URL) -> DatabaseType? {
        PluginManager.shared.allRegisteredFileExtensions[url.pathExtension.lowercased()]
    }

    // MARK: - Main Dispatch

    func handleOpenURLs(_ urls: [URL]) {
        // application(_:open:) fires in the same run loop pass as applicationDidFinishLaunching
        // on cold launch from URL. The deferred auto-reconnect Task yields to the next run loop,
        // so this flag is guaranteed to be set before the Task checks it.
        suppressAutoReconnect = true

        let deeplinks = urls.filter { $0.scheme == "tablepro" }
        if !deeplinks.isEmpty {
            Task { @MainActor in
                for url in deeplinks { await self.handleDeeplink(url) }
            }
        }

        let plugins = urls.filter { $0.pathExtension == "tableplugin" }
        if !plugins.isEmpty {
            Task { @MainActor in
                for url in plugins { await self.handlePluginInstall(url) }
            }
        }

        let databaseURLs = urls.filter { isDatabaseURL($0) }
        if !databaseURLs.isEmpty {
            suppressWelcomeWindow()
            Task { @MainActor in
                for url in databaseURLs { self.handleDatabaseURL(url) }
                // endFileOpenSuppression is called here to match suppressWelcomeWindow above.
                // Individual handlers no longer manage this flag.
                self.endFileOpenSuppression()
            }
        }

        let databaseFiles = urls.filter { isDatabaseFile($0) }
        if !databaseFiles.isEmpty {
            suppressWelcomeWindow()
            Task { @MainActor in
                for url in databaseFiles {
                    guard let dbType = self.databaseTypeForFile(url) else { continue }
                    switch dbType {
                    case .sqlite:
                        self.handleSQLiteFile(url)
                    case .duckdb:
                        self.handleDuckDBFile(url)
                    default:
                        self.handleGenericDatabaseFile(url, type: dbType)
                    }
                }
                self.endFileOpenSuppression()
            }
        }

        // Connection share files
        let connectionShareFiles = urls.filter { $0.pathExtension.lowercased() == "tablepro" }
        for url in connectionShareFiles {
            handleConnectionShareFile(url)
        }

        let sqlFiles = urls.filter { $0.pathExtension.lowercased() == "sql" }
        if !sqlFiles.isEmpty {
            if DatabaseManager.shared.currentSession != nil {
                suppressWelcomeWindow()
                for window in NSApp.windows where isMainWindow(window) {
                    window.makeKeyAndOrderFront(nil)
                }
                closeAllWelcomeWindows()
                NotificationCenter.default.post(name: .openSQLFiles, object: sqlFiles)
                endFileOpenSuppression()
            } else {
                queuedFileURLs.append(contentsOf: sqlFiles)
                openWelcomeWindow()
            }
        }
    }

    // MARK: - In-App Tab Routing

    /// Route content to an existing connection window's in-app tab bar when possible.
    /// Returns true if the content was routed to an existing window.
    /// Falls back gracefully (returns false) when no coordinator exists for the connection.
    @discardableResult
    func routeToExistingWindow(
        connectionId: UUID,
        payload: EditorTabPayload
    ) -> Bool {
        guard let coordinator = MainContentCoordinator.firstCoordinator(for: connectionId) else {
            return false
        }
        switch payload.tabType {
        case .table:
            if let tableName = payload.tableName {
                coordinator.openTableTab(tableName, showStructure: payload.showStructure, isView: payload.isView)
            }
        case .query:
            coordinator.tabManager.addTab(
                initialQuery: payload.initialQuery,
                databaseName: payload.databaseName ?? coordinator.connection.database
            )
        default:
            coordinator.addNewQueryTab()
        }
        coordinator.contentWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: - Welcome Window Suppression

    func suppressWelcomeWindow() {
        isHandlingFileOpen = true
        fileOpenSuppressionCount += 1
        for window in NSApp.windows where isWelcomeWindow(window) {
            window.orderOut(nil)
        }
    }

    // MARK: - Deeplink Handling

    private func handleDeeplink(_ url: URL) async {
        guard let action = DeeplinkHandler.parse(url) else { return }

        switch action {
        case .connect(let name):
            connectViaDeeplink(connectionName: name)

        case .openTable(let name, let table, let database):
            connectViaDeeplink(connectionName: name) { connectionId in
                EditorTabPayload(connectionId: connectionId, tabType: .table,
                                 tableName: table, databaseName: database)
            }

        case .openQuery(let name, let sql):
            let maxDeeplinkSQLLength = 51_200
            let sqlLength = (sql as NSString).length
            guard sqlLength <= maxDeeplinkSQLLength else { return }
            let preview: String
            if sqlLength > 300 {
                let hiddenCount = sqlLength - 300
                preview = String(sql.prefix(300))
                    + String(format: String(localized: "\n\n… (%d more characters not shown)"), hiddenCount)
            } else {
                preview = sql
            }
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Open Query from Link"),
                message: String(format: String(localized: "An external link wants to open a query on connection \"%@\":\n\n%@"), name, preview),
                confirmButton: String(localized: "Open Query"),
                cancelButton: String(localized: "Cancel"),
                window: NSApp.keyWindow
            )
            guard confirmed else { return }
            connectViaDeeplink(connectionName: name) { connectionId in
                EditorTabPayload(connectionId: connectionId, tabType: .query,
                                 initialQuery: sql)
            }

        case .importConnection(let name, let host, let port, let type, let username, let database):
            await handleImportDeeplink(name: name, host: host, port: port, type: type,
                                       username: username, database: database)
        }
    }

    private func connectViaDeeplink(
        connectionName: String,
        makePayload: (@Sendable (UUID) -> EditorTabPayload)? = nil
    ) {
        guard let connection = DeeplinkHandler.resolveConnection(named: connectionName) else {
            fileOpenLogger.error("No connection named '\(connectionName, privacy: .public)'")
            AlertHelper.showErrorSheet(
                title: String(localized: "Connection Not Found"),
                message: String(format: String(localized: "No saved connection named \"%@\"."), connectionName),
                window: NSApp.keyWindow
            )
            return
        }

        let hasDriver = DatabaseManager.shared.activeSessions[connection.id]?.driver != nil
        let hasCoordinator = MainContentCoordinator.firstCoordinator(for: connection.id) != nil

        // Already connected — route to existing window's in-app tab bar
        if hasDriver {
            if let payload = makePayload?(connection.id) {
                if !routeToExistingWindow(connectionId: connection.id, payload: payload) {
                    WindowOpener.shared.openNativeTab(payload)
                }
            } else {
                bringConnectionWindowToFront(connection.id)
            }
            return
        }

        // Prevent duplicate connections from rapid deeplink invocations
        let hasPendingWindow = WindowOpener.shared.pendingPayloads.contains { $0.connectionId == connection.id }
        let isAlreadyConnecting = connectingURLConnectionIds.contains(connection.id)
        guard !isAlreadyConnecting, !hasPendingWindow else {
            bringConnectionWindowToFront(connection.id)
            return
        }

        // Has coordinator but no driver — window exists, connection may be in progress
        if hasCoordinator {
            bringConnectionWindowToFront(connection.id)
            return
        }

        let hadExistingMain = NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
        if hadExistingMain && !AppSettingsManager.shared.tabs.groupAllConnectionTabs {
            NSWindow.allowsAutomaticWindowTabbing = false
        }

        connectingURLConnectionIds.insert(connection.id)

        let deeplinkPayload = EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault)
        WindowOpener.shared.openNativeTab(deeplinkPayload)

        Task { @MainActor in
            defer { self.connectingURLConnectionIds.remove(connection.id) }
            do {
                // Confirm pre-connect script if present (deep links are external, so always confirm)
                if let script = connection.preConnectScript,
                   !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    let confirmed = await AlertHelper.confirmDestructive(
                        title: String(localized: "Pre-Connect Script"),
                        message: String(format: String(localized: "Connection \"%@\" has a script that will run before connecting:\n\n%@"), connection.name, script),
                        confirmButton: String(localized: "Run Script"),
                        cancelButton: String(localized: "Cancel"),
                        window: NSApp.keyWindow
                    )
                    guard confirmed else { return }
                }

                try await DatabaseManager.shared.connectToSession(connection)
                self.closeAllWelcomeWindows()
                if let payload = makePayload?(connection.id) {
                    if !self.routeToExistingWindow(connectionId: connection.id, payload: payload) {
                        WindowOpener.shared.openNativeTab(payload)
                    }
                }
            } catch {
                fileOpenLogger.error("Deeplink connect failed for \"\(connectionName, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
                await self.handleConnectionFailure(error)
            }
        }
    }

    private func handleImportDeeplink(
        name: String, host: String, port: Int,
        type: DatabaseType, username: String, database: String
    ) async {
        let userPart = username.isEmpty ? "" : "\(username)@"
        let details = "\(type.rawValue)://\(userPart)\(host):\(port)/\(database)"
        let confirmed = await AlertHelper.confirmDestructive(
            title: String(localized: "Import Connection from Link"),
            message: String(format: String(localized: "An external link wants to add a database connection:\n\nName: %@\n%@"), name, details),
            confirmButton: String(localized: "Add Connection"),
            cancelButton: String(localized: "Cancel"),
            window: NSApp.keyWindow
        )
        guard confirmed else { return }

        let connection = DatabaseConnection(
            name: name, host: host, port: port,
            database: database, username: username, type: type
        )
        ConnectionStorage.shared.addConnection(connection)
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)

        if let openWindow = WindowOpener.shared.openWindow {
            openWindow(id: "connection-form", value: connection.id)
        }
    }

    // MARK: - Connection Share Import

    private func handleConnectionShareFile(_ url: URL) {
        openWelcomeWindow()
        pendingConnectionShareURL = url
        NotificationCenter.default.post(name: .connectionShareFileOpened, object: url)
    }

    // MARK: - Plugin Install

    private func handlePluginInstall(_ url: URL) async {
        do {
            let entry = try await PluginManager.shared.installPlugin(from: url)
            fileOpenLogger.info("Installed plugin '\(entry.name)' from Finder")

            UserDefaults.standard.set(SettingsTab.plugins.rawValue, forKey: "selectedSettingsTab")
            NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        } catch {
            fileOpenLogger.error("Plugin install failed: \(error.localizedDescription)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Plugin Installation Failed"),
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }
}
