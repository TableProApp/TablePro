//
//  AppDelegate+ConnectionHandler.swift
//  TablePro
//
//  Database URL and SQLite file open handlers with cold-start queuing
//

import AppKit
import os

private let connectionLogger = Logger(subsystem: "com.TablePro", category: "ConnectionHandler")

/// Typed queue entry for URLs waiting on the SwiftUI window system.
/// Replaces the separate `queuedDatabaseURLs` and `queuedSQLiteFileURLs` arrays.
enum QueuedURLEntry {
    case databaseURL(URL)
    case sqliteFile(URL)
    case duckdbFile(URL)
    case genericDatabaseFile(URL, DatabaseType)
}

extension AppDelegate {
    // MARK: - Database URL Handler

    func handleDatabaseURL(_ url: URL) {
        guard WindowOpener.shared.openWindow != nil else {
            queuedURLEntries.append(.databaseURL(url))
            scheduleQueuedURLProcessing()
            return
        }

        let result = ConnectionURLParser.parse(url.absoluteString)
        guard case .success(let parsed) = result else {
            connectionLogger.error("Failed to parse database URL: \(url.sanitizedForLogging, privacy: .public)")
            return
        }

        let connections = ConnectionStorage.shared.loadConnections()
        let matchedConnection = connections.first { conn in
            conn.type == parsed.type
                && conn.host == parsed.host
                && (parsed.port == nil || conn.port == parsed.port)
                && conn.database == parsed.database
                && (parsed.username.isEmpty || conn.username == parsed.username)
        }

        let connection: DatabaseConnection
        if let matched = matchedConnection {
            connection = matched
        } else {
            connection = buildTransientConnection(from: parsed)
        }

        if !parsed.password.isEmpty {
            ConnectionStorage.shared.savePassword(parsed.password, for: connection.id)
        }

        // Check if already connected or connecting (by ID or by params).
        // This catches duplicates from URL handler, auto-reconnect, or any other source.
        if DatabaseManager.shared.activeSessions[connection.id] != nil {
            if DatabaseManager.shared.activeSessions[connection.id]?.driver != nil {
                handlePostConnectionActions(parsed, connectionId: connection.id)
            }
            bringConnectionWindowToFront(connection.id)
            return
        }

        if let existingId = findSessionByParams(parsed) {
            if DatabaseManager.shared.activeSessions[existingId]?.driver != nil {
                handlePostConnectionActions(parsed, connectionId: existingId)
            }
            bringConnectionWindowToFront(existingId)
            return
        }

        // Skip if already connecting this connection from a URL (prevents duplicates).
        // Use param key to catch transient connections with different UUIDs
        // even before connectToSession creates the session.
        let paramKey = Self.paramKey(for: parsed)
        guard !connectingURLConnectionIds.contains(connection.id),
              !connectingURLParamKeys.contains(paramKey) else {
            return
        }
        connectingURLConnectionIds.insert(connection.id)
        connectingURLParamKeys.insert(paramKey)

        Task { @MainActor in
            defer {
                self.connectingURLConnectionIds.remove(connection.id)
                self.connectingURLParamKeys.remove(paramKey)
            }
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                self.openNewConnectionWindow(for: connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
                self.handlePostConnectionActions(parsed, connectionId: connection.id)
            } catch {
                connectionLogger.error("Database URL connect failed: \(error.localizedDescription)")
                await self.handleConnectionFailure(error)
            }
        }
    }

    // MARK: - SQLite File Handler

    func handleSQLiteFile(_ url: URL) {
        guard WindowOpener.shared.openWindow != nil else {
            queuedURLEntries.append(.sqliteFile(url))
            scheduleQueuedURLProcessing()
            return
        }

        let filePath = url.path(percentEncoded: false)
        let connectionName = url.deletingPathExtension().lastPathComponent

        for (sessionId, session) in DatabaseManager.shared.activeSessions {
            if session.connection.type == .sqlite
                && session.connection.database == filePath
                && session.driver != nil {
                bringConnectionWindowToFront(sessionId)
                return
            }
        }

        let connection = DatabaseConnection(
            name: connectionName,
            host: "",
            port: 0,
            database: filePath,
            username: "",
            type: .sqlite
        )

        guard !connectingFilePaths.contains(filePath) else { return }
        connectingFilePaths.insert(filePath)

        Task { @MainActor in
            defer {
                self.connectingFilePaths.remove(filePath)
            }
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                self.openNewConnectionWindow(for: connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch {
                connectionLogger.error("SQLite file open failed for '\(filePath, privacy: .public)': \(error.localizedDescription)")
                await self.handleConnectionFailure(error)
            }
        }
    }

    // MARK: - DuckDB File Handler

    func handleDuckDBFile(_ url: URL) {
        guard WindowOpener.shared.openWindow != nil else {
            queuedURLEntries.append(.duckdbFile(url))
            scheduleQueuedURLProcessing()
            return
        }

        let filePath = url.path(percentEncoded: false)
        let connectionName = url.deletingPathExtension().lastPathComponent

        for (sessionId, session) in DatabaseManager.shared.activeSessions {
            if session.connection.type == .duckdb
                && session.connection.database == filePath
                && session.driver != nil {
                bringConnectionWindowToFront(sessionId)
                return
            }
        }

        let connection = DatabaseConnection(
            name: connectionName,
            host: "",
            port: 0,
            database: filePath,
            username: "",
            type: .duckdb
        )

        guard !connectingFilePaths.contains(filePath) else { return }
        connectingFilePaths.insert(filePath)

        Task { @MainActor in
            defer {
                self.connectingFilePaths.remove(filePath)
            }
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                self.openNewConnectionWindow(for: connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch {
                connectionLogger.error("DuckDB file open failed for '\(filePath, privacy: .public)': \(error.localizedDescription)")
                await self.handleConnectionFailure(error)
            }
        }
    }

    // MARK: - Generic Database File Handler

    func handleGenericDatabaseFile(_ url: URL, type dbType: DatabaseType) {
        guard WindowOpener.shared.openWindow != nil else {
            queuedURLEntries.append(.genericDatabaseFile(url, dbType))
            scheduleQueuedURLProcessing()
            return
        }

        let filePath = url.path(percentEncoded: false)
        let connectionName = url.deletingPathExtension().lastPathComponent

        for (sessionId, session) in DatabaseManager.shared.activeSessions {
            if session.connection.type == dbType
                && session.connection.database == filePath
                && session.driver != nil {
                bringConnectionWindowToFront(sessionId)
                return
            }
        }

        let connection = DatabaseConnection(
            name: connectionName,
            host: "",
            port: 0,
            database: filePath,
            username: "",
            type: dbType
        )

        guard !connectingFilePaths.contains(filePath) else { return }
        connectingFilePaths.insert(filePath)

        Task { @MainActor in
            defer {
                self.connectingFilePaths.remove(filePath)
            }
            do {
                try await DatabaseManager.shared.connectToSession(connection)
                self.openNewConnectionWindow(for: connection)
                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch {
                connectionLogger.error("File open failed for '\(filePath, privacy: .public)' (\(dbType.rawValue)): \(error.localizedDescription)")
                await self.handleConnectionFailure(error)
            }
        }
    }

    // MARK: - Unified Queue

    func scheduleQueuedURLProcessing() {
        guard !isProcessingQueuedURLs else {
            return
        }
        isProcessingQueuedURLs = true

        Task { @MainActor [weak self] in
            defer { self?.isProcessingQueuedURLs = false }

            let ready = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    await WindowOpener.shared.waitUntilReady()
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                return result
            }
            guard let self else { return }
            if !ready {
                connectionLogger.warning(
                    "SwiftUI window system not ready after 5s, dropping \(self.queuedURLEntries.count) queued URL(s)"
                )
                self.queuedURLEntries.removeAll()
                return
            }

            self.suppressWelcomeWindow()
            let entries = self.queuedURLEntries
            self.queuedURLEntries.removeAll()
            for entry in entries {
                switch entry {
                case .databaseURL(let url): self.handleDatabaseURL(url)
                case .sqliteFile(let url): self.handleSQLiteFile(url)
                case .duckdbFile(let url): self.handleDuckDBFile(url)
                case .genericDatabaseFile(let url, let dbType): self.handleGenericDatabaseFile(url, type: dbType)
                }
            }
            self.endFileOpenSuppression()
        }
    }

    // MARK: - SQL File Queue (drained by .databaseDidConnect)

    @objc func handleDatabaseDidConnect() {
        guard !queuedFileURLs.isEmpty else { return }
        let urls = queuedFileURLs
        queuedFileURLs.removeAll()
        postSQLFilesWhenReady(urls: urls)
    }

    private func postSQLFilesWhenReady(urls: [URL]) {
        Task { @MainActor in
            await waitForConnection(timeout: .seconds(3))
            NotificationCenter.default.post(name: .openSQLFiles, object: urls)
        }
    }

    // MARK: - Connection Window Helper

    private func openNewConnectionWindow(for connection: DatabaseConnection) {
        let hadExistingMain = NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
        if hadExistingMain && !AppSettingsManager.shared.tabs.groupAllConnectionTabs {
            NSWindow.allowsAutomaticWindowTabbing = false
        }
        let payload = EditorTabPayload(connectionId: connection.id)
        WindowOpener.shared.openNativeTab(payload)
    }

    // MARK: - Post-Connect Actions

    private func handlePostConnectionActions(_ parsed: ParsedConnectionURL, connectionId: UUID) {
        Task { @MainActor in
            await waitForConnection(timeout: .seconds(5))

            if let schema = parsed.schema {
                NotificationCenter.default.post(
                    name: .switchSchemaFromURL,
                    object: nil,
                    userInfo: ["connectionId": connectionId, "schema": schema]
                )
                await waitForNotification(.refreshData, timeout: .seconds(3))
            }

            if let tableName = parsed.tableName {
                let payload = EditorTabPayload(
                    connectionId: connectionId,
                    tabType: .table,
                    tableName: tableName,
                    isView: parsed.isView
                )
                WindowOpener.shared.openNativeTab(payload)

                if parsed.filterColumn != nil || parsed.filterCondition != nil {
                    await waitForNotification(.refreshData, timeout: .seconds(3))

                    // All filters from external URLs require explicit user confirmation
                    let filterDescription: String
                    if let condition = parsed.filterCondition, !condition.isEmpty {
                        let preview = (condition as NSString).length > 300
                            ? String(condition.prefix(300)) + "…" : condition
                        filterDescription = preview
                    } else {
                        filterDescription = [parsed.filterColumn, parsed.filterOperation, parsed.filterValue]
                            .compactMap { $0 }.joined(separator: " ")
                    }
                    if !filterDescription.isEmpty {
                        let confirmed = await AlertHelper.confirmDestructive(
                            title: String(localized: "Apply Filter from Link"),
                            message: String(
                                format: String(localized: "An external link wants to apply a filter:\n\n%@"),
                                filterDescription
                            ),
                            confirmButton: String(localized: "Apply Filter"),
                            cancelButton: String(localized: "Cancel"),
                            window: NSApp.keyWindow
                        )
                        guard confirmed else { return }
                    }

                    NotificationCenter.default.post(
                        name: .applyURLFilter,
                        object: nil,
                        userInfo: [
                            "connectionId": connectionId,
                            "column": parsed.filterColumn as Any,
                            "operation": parsed.filterOperation as Any,
                            "value": parsed.filterValue as Any,
                            "condition": parsed.filterCondition as Any
                        ]
                    )
                }
            }
        }
    }

    private func waitForConnection(timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            var observer: NSObjectProtocol?

            func resumeOnce() {
                guard !didResume else { return }
                didResume = true
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                continuation.resume()
            }

            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                resumeOnce()
            }
            observer = NotificationCenter.default.addObserver(
                forName: .databaseDidConnect,
                object: nil,
                queue: .main
            ) { _ in
                timeoutTask.cancel()
                resumeOnce()
            }
        }
    }

    private func waitForNotification(_ name: Notification.Name, timeout: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            var observer: NSObjectProtocol?

            func resumeOnce() {
                guard !didResume else { return }
                didResume = true
                if let obs = observer {
                    NotificationCenter.default.removeObserver(obs)
                }
                continuation.resume()
            }

            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                resumeOnce()
            }
            observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                timeoutTask.cancel()
                resumeOnce()
            }
        }
    }

    // MARK: - Session Lookup

    /// Finds any session (connected or still connecting) matching the parsed URL params.
    private func findSessionByParams(_ parsed: ParsedConnectionURL) -> UUID? {
        for (id, session) in DatabaseManager.shared.activeSessions {
            let conn = session.connection
            if conn.type == parsed.type
                && conn.host == parsed.host
                && conn.database == parsed.database
                && (parsed.port == nil || conn.port == parsed.port || conn.port == parsed.type.defaultPort)
                && (parsed.username.isEmpty || conn.username == parsed.username)
                && (parsed.redisDatabase == nil || conn.redisDatabase == parsed.redisDatabase) {
                return id
            }
        }
        return nil
    }

    /// Normalized key for deduplicating connection attempts by URL params.
    static func paramKey(for parsed: ParsedConnectionURL) -> String {
        let rdb = parsed.redisDatabase.map { "/redis:\($0)" } ?? ""
        return "\(parsed.type.rawValue):\(parsed.username)@\(parsed.host):\(parsed.port ?? 0)/\(parsed.database)\(rdb)"
    }

    func bringConnectionWindowToFront(_ connectionId: UUID) {
        let windows = WindowLifecycleMonitor.shared.windows(for: connectionId)
        if let window = windows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.windows.first { isMainWindow($0) && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Connection Failure

    func handleConnectionFailure(_ error: Error) async {
        closeOrphanedMainWindows()

        // User cancelled password prompt — no error dialog needed
        if error is CancellationError { return }

        await Task.yield()
        AlertHelper.showErrorSheet(
            title: String(localized: "Connection Failed"),
            message: error.localizedDescription,
            window: NSApp.keyWindow
        )
    }

    /// Closes main windows that have no active database session, then opens the welcome window if none remain.
    private func closeOrphanedMainWindows() {
        for window in NSApp.windows where isMainWindow(window) {
            let hasActiveSession = DatabaseManager.shared.activeSessions.values.contains {
                window.subtitle == $0.connection.name
                    || window.subtitle == "\($0.connection.name) — Preview"
            }
            if !hasActiveSession { window.close() }
        }
        if !NSApp.windows.contains(where: { isMainWindow($0) && $0.isVisible }) {
            openWelcomeWindow()
        }
    }

    // MARK: - Transient Connection Builder

    private func buildTransientConnection(from parsed: ParsedConnectionURL) -> DatabaseConnection {
        var sshConfig = SSHConfiguration()
        if let sshHost = parsed.sshHost {
            sshConfig.enabled = true
            sshConfig.host = sshHost
            sshConfig.port = parsed.sshPort ?? 22
            sshConfig.username = parsed.sshUsername ?? ""
            if parsed.usePrivateKey == true {
                sshConfig.authMethod = .privateKey
            }
            if parsed.useSSHAgent == true {
                sshConfig.authMethod = .sshAgent
                sshConfig.agentSocketPath = parsed.agentSocket ?? ""
            }
        }

        var sslConfig = SSLConfiguration()
        if let sslMode = parsed.sslMode {
            sslConfig.mode = sslMode
        }

        var color: ConnectionColor = .none
        if let hex = parsed.statusColor {
            color = ConnectionURLParser.connectionColor(fromHex: hex)
        }

        var tagId: UUID?
        if let envName = parsed.envTag {
            tagId = ConnectionURLParser.tagId(fromEnvName: envName)
        }

        var connection = DatabaseConnection(
            name: parsed.connectionName ?? parsed.suggestedName,
            host: parsed.host,
            port: parsed.port ?? parsed.type.defaultPort,
            database: parsed.database,
            username: parsed.username,
            type: parsed.type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: color,
            tagId: tagId,
            mongoAuthSource: parsed.authSource,
            mongoUseSrv: parsed.useSrv,
            mongoAuthMechanism: parsed.mongoQueryParams["authMechanism"],
            mongoReplicaSet: parsed.mongoQueryParams["replicaSet"],
            redisDatabase: parsed.redisDatabase,
            oracleServiceName: parsed.oracleServiceName
        )

        for (key, value) in parsed.mongoQueryParams where !value.isEmpty {
            if key != "authMechanism" && key != "replicaSet" {
                connection.additionalFields["mongoParam_\(key)"] = value
            }
        }

        return connection
    }
}
