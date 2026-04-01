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
                for window in NSApp.windows where isWelcomeWindow(window) {
                    window.close()
                }
                NotificationCenter.default.post(name: .openSQLFiles, object: sqlFiles)
                endFileOpenSuppression()
            } else {
                queuedFileURLs.append(contentsOf: sqlFiles)
                openWelcomeWindow()
            }
        }
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
            let preview = (sql as NSString).length > 300 ? String(sql.prefix(300)) + "…" : sql
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Open Query from Link"),
                message: String(localized: "An external link wants to open a query on connection \"\(name)\":\n\n\(preview)"),
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
            fileOpenLogger.error("Deep link: no connection named '\(connectionName, privacy: .public)'")
            AlertHelper.showErrorSheet(
                title: String(localized: "Connection Not Found"),
                message: String(localized: "No saved connection named \"\(connectionName)\"."),
                window: NSApp.keyWindow
            )
            return
        }

        if DatabaseManager.shared.activeSessions[connection.id]?.driver != nil {
            if let payload = makePayload?(connection.id) {
                WindowOpener.shared.openNativeTab(payload)
            } else {
                for window in NSApp.windows where isMainWindow(window) {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            }
            return
        }

        let hadExistingMain = NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
        if hadExistingMain && !AppSettingsManager.shared.tabs.groupAllConnectionTabs {
            NSWindow.allowsAutomaticWindowTabbing = false
        }

        let deeplinkPayload = EditorTabPayload(connectionId: connection.id)
        WindowOpener.shared.openNativeTab(deeplinkPayload)

        Task { @MainActor in
            do {
                // Confirm pre-connect script if present (deep links are external, so always confirm)
                if let script = connection.preConnectScript,
                   !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    let confirmed = await AlertHelper.confirmDestructive(
                        title: String(localized: "Pre-Connect Script"),
                        message: String(localized: "Connection \"\(connection.name)\" has a script that will run before connecting:\n\n\(script)"),
                        confirmButton: String(localized: "Run Script"),
                        cancelButton: String(localized: "Cancel"),
                        window: NSApp.keyWindow
                    )
                    guard confirmed else { return }
                }

                try await DatabaseManager.shared.connectToSession(connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
                if let payload = makePayload?(connection.id) {
                    WindowOpener.shared.openNativeTab(payload)
                }
            } catch {
                fileOpenLogger.error("Deep link connect failed: \(error.localizedDescription)")
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
            message: String(localized: "An external link wants to add a database connection:\n\nName: \(name)\n\(details)"),
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
        // Delay to ensure WelcomeWindowView's .onReceive is registered after window renders
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .connectionShareFileOpened, object: url)
        }
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
