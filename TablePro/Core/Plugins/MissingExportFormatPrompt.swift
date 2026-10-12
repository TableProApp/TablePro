//
//  MissingExportFormatPrompt.swift
//  TablePro
//

import AppKit
import os

@MainActor
internal enum MissingExportFormatPrompt {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MissingExportFormatPrompt")

    internal static func ensureInstalled(_ format: InstallableExportFormat, window: NSWindow?) async -> Bool {
        let confirmed = await AlertHelper.confirm(
            title: String(format: String(localized: "Install the %@ plugin?"), format.displayName),
            message: String(localized: "TablePro writes this format with a plugin it downloads from the plugin registry."),
            confirmButton: String(localized: "Install"),
            window: window
        )
        guard confirmed else { return false }

        do {
            try await PluginInstallProgressPresenter.run(
                title: String(format: String(localized: "Downloading the %@ plugin…"), format.displayName),
                window: window
            ) { progress in
                try await PluginManager.shared.installMissingExportFormat(format, progress: progress)
            }
            logger.info("Installed the \(format.formatId, privacy: .public) export format")
            return true
        } catch {
            logger.error(
                "Install failed for \(format.formatId, privacy: .public): \(error.publicLogShape, privacy: .public)"
            )
            AlertHelper.showErrorSheet(
                title: String(localized: "Plugin Installation Failed"),
                message: error.localizedDescription,
                window: window
            )
            return false
        }
    }
}
