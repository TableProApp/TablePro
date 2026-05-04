//
//  WelcomeViewModel+Sample.swift
//  TablePro
//

import AppKit
import Foundation
import os

@MainActor
internal enum SampleDatabaseLauncher {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SampleDatabase")

    private static let sampleOpenedCountKey = "com.TablePro.sample.openedCount"
    private static let sampleAutoSelectTable = "Track"

    internal static var sampleConnectionName: String {
        String(localized: "Chinook (Sample)")
    }

    internal static func open(
        sampleService: SampleDatabaseService = .shared,
        connectionStorage: ConnectionStorage = .shared,
        onError: @MainActor @escaping (Error) -> Void = defaultErrorHandler
    ) {
        let installedURL: URL
        do {
            try sampleService.installIfNeeded()
            installedURL = sampleService.installedFileURL
        } catch {
            logger.error(
                "Failed to install sample database: \(error.localizedDescription, privacy: .public)"
            )
            onError(error)
            return
        }

        let connection = upsertSampleConnection(
            installedURL: installedURL,
            connectionStorage: connectionStorage
        )
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        bumpSampleOpenedCounter()
        launchSampleConnection(connection, onError: onError)
    }

    internal static func reset(
        sampleService: SampleDatabaseService = .shared,
        connectionStorage: ConnectionStorage = .shared,
        databaseManager: DatabaseManager = .shared
    ) {
        Task { @MainActor in
            await performReset(
                sampleService: sampleService,
                connectionStorage: connectionStorage,
                databaseManager: databaseManager
            )
        }
    }

    private static func upsertSampleConnection(
        installedURL: URL,
        connectionStorage: ConnectionStorage
    ) -> DatabaseConnection {
        let existing = connectionStorage.loadConnections().first { existing in
            existing.isSample && existing.type == .sqlite
        }

        if let existing {
            if existing.database != installedURL.path {
                var updated = existing
                updated.database = installedURL.path
                connectionStorage.updateConnection(updated)
                return updated
            }
            return existing
        }

        let nextSortOrder = (connectionStorage.loadConnections().map(\.sortOrder).max() ?? -1) + 1
        let connection = DatabaseConnection(
            name: sampleConnectionName,
            host: "",
            port: 0,
            database: installedURL.path,
            username: "",
            type: .sqlite,
            color: .green,
            sortOrder: nextSortOrder,
            localOnly: true,
            isSample: true
        )
        connectionStorage.addConnection(connection)
        return connection
    }

    private static func launchSampleConnection(
        _ connection: DatabaseConnection,
        onError: @MainActor @escaping (Error) -> Void
    ) {
        WelcomeWindowFactory.close()
        Task {
            do {
                try await TabRouter.shared.route(
                    .openTable(
                        connectionId: connection.id,
                        database: nil,
                        schema: nil,
                        table: sampleAutoSelectTable,
                        isView: false
                    )
                )
            } catch is CancellationError {
                WelcomeWindowFactory.openOrFront()
            } catch {
                logger.error(
                    "Failed to open sample database: \(error.localizedDescription, privacy: .public)"
                )
                handleSampleLaunchFailure(error: error, connectionId: connection.id, onError: onError)
            }
        }
    }

    private static func handleSampleLaunchFailure(
        error: Error,
        connectionId: UUID,
        onError: @MainActor @escaping (Error) -> Void
    ) {
        for window in WindowLifecycleMonitor.shared.windows(for: connectionId) {
            window.close()
        }
        onError(error)
        WelcomeWindowFactory.openOrFront()
    }

    private static func bumpSampleOpenedCounter() {
        let next = UserDefaults.standard.integer(forKey: sampleOpenedCountKey) + 1
        UserDefaults.standard.set(next, forKey: sampleOpenedCountKey)
    }

    private static func performReset(
        sampleService: SampleDatabaseService,
        connectionStorage: ConnectionStorage,
        databaseManager: DatabaseManager
    ) async {
        let confirmed = await AlertHelper.confirmDestructive(
            title: String(localized: "Reset Sample Database?"),
            message: String(localized: "This discards your edits to the Chinook sample and restores the original copy."),
            confirmButton: String(localized: "Reset Sample"),
            window: NSApp.keyWindow
        )
        guard confirmed else { return }

        let openSampleSessionIds = databaseManager.activeSessions.compactMap { entry -> UUID? in
            entry.value.connection.isSample ? entry.key : nil
        }
        for sessionId in openSampleSessionIds {
            await databaseManager.disconnectSession(sessionId)
        }

        do {
            try sampleService.resetToBundled()
        } catch {
            logger.error("Sample reset failed: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Could Not Reset Sample"),
                message: error.localizedDescription,
                window: NSApp.keyWindow
            )
            return
        }

        let sampleConnection = connectionStorage.loadConnections().first { $0.isSample }
        if let sampleConnection {
            do {
                try await DatabaseManager.shared.ensureConnected(sampleConnection)
                NotificationCenter.default.post(name: .connectionUpdated, object: nil)
            } catch {
                logger.warning(
                    "Reopening sample after reset failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    @MainActor
    private static func defaultErrorHandler(_ error: Error) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Could Not Open Sample"),
            message: error.localizedDescription,
            window: NSApp.keyWindow
        )
    }
}

extension WelcomeViewModel {
    func openSampleDatabase() {
        SampleDatabaseLauncher.open { [weak self] error in
            guard let self else { return }
            self.connectionError = error.localizedDescription
            self.showConnectionError = true
        }
    }
}
