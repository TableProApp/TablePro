//
//  MissingDriverPluginPrompt.swift
//  TablePro
//

import AppKit
import os

/// Asks for the driver a file needs before the file is opened, rather than raising a window
/// headlined "Could not connect" whose only action leaves for the connection list.
@MainActor
internal enum MissingDriverPluginPrompt {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "MissingDriverPluginPrompt")

    /// Whether the open may go ahead.
    internal static func ensureInstalled(for type: DatabaseType, opening url: URL) async -> Bool {
        /// A plugin without `TableProProvidesDatabaseTypeIds` registers on the eager path, which a
        /// Finder open beats to the question: launch intents route on a fixed 150ms timer. Asking
        /// before the barrier offers to install a plugin the user already has.
        if !PluginManager.shared.isDriverInstalled(for: type) {
            await PluginManager.shared.waitForInitialLoad()
        }
        guard !PluginManager.shared.isDriverInstalled(for: type) else { return true }
        /// A plugin that ships inside the app and still did not load is disabled or damaged, and
        /// downloading cannot fix either. The connect attempt reports what actually went wrong.
        guard type.isDownloadablePlugin else { return true }

        let displayName = PluginMetadataRegistry.shared.snapshot(for: type)?.displayName ?? type.rawValue
        let confirmed = await AlertHelper.confirm(
            title: String(
                format: String(localized: "Install the %@ plugin to open “%@”?"),
                displayName,
                url.lastPathComponent
            ),
            message: String(localized: "TablePro reads this file with a driver it downloads from the plugin registry."),
            confirmButton: String(localized: "Install")
        )
        guard confirmed else { return false }

        do {
            try await PluginManager.shared.installMissingPlugin(for: type) { _ in }
            logger.info("Installed \(type.rawValue, privacy: .public) to open a file")
            return true
        } catch {
            logger.error("Install failed for \(type.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Plugin Installation Failed"),
                message: error.localizedDescription,
                window: nil
            )
            return false
        }
    }
}
