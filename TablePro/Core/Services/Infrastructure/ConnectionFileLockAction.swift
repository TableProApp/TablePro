//
//  ConnectionFileLockAction.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

/// The one path a user-requested lock release takes, whatever surface asked for it. The menu bar
/// and the workspace rail both land here so the wording and the failure handling exist once.
@MainActor
internal enum ConnectionFileLockAction {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFileLock")

    /// What the command should be called for this connection, or nil when it holds nothing it can
    /// give up. Read straight off the live driver rather than off the database type, because it is
    /// a fact about this connection: a DuckDB connection to a Parquet file or to a remote Quack
    /// server holds no file lock, while its neighbour on a `.duckdb` file does.
    internal static func commandTitle(connectionId: UUID?) -> String? {
        guard let connectionId,
              let driver = DatabaseManager.shared.activeSessions[connectionId]?.driver
        else { return nil }
        return driver.releasableResourceCommandTitle
    }

    internal static func release(
        connectionId: UUID,
        connectionName: String,
        presentingWindow: NSWindow?
    ) async {
        guard let driver = DatabaseManager.shared.activeSessions[connectionId]?.driver else { return }

        let outcome: PluginResourceRelease
        do {
            outcome = try await driver.releaseIdleResource()
        } catch {
            logger.error("Releasing the file lock for \(connectionName, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Could not release the file"),
                message: error.localizedDescription,
                window: presentingWindow
            )
            return
        }

        /// A release that worked is reported by the file becoming available to whatever the user
        /// was trying to run, not by an alert congratulating them. A refusal is worth interrupting
        /// for, because they asked for something that did not happen and only the driver knows why.
        /// Resource-neutral, because the same path serves a DuckDB file lock and a MySQL server
        /// connection. Naming the file to someone who released a connection reads as a different
        /// failure than the one they hit.
        guard !outcome.didRelease, let reason = outcome.reason else { return }
        AlertHelper.showErrorSheet(
            title: String(format: String(localized: "“%@” is still in use"), connectionName),
            message: reason,
            window: presentingWindow
        )
    }
}
