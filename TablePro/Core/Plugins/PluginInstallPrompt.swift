import AppKit
import os

@MainActor
internal enum PluginInstallPrompt {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PluginInstallPrompt")

    internal typealias Install = (_ progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void

    internal static func ensureInstalled(_ format: InstallableExportFormat, window: NSWindow?) async -> Bool {
        await confirmAndRun(
            pluginName: format.displayName,
            title: String(format: String(localized: "Install the %@ plugin?"), format.displayName),
            message: String(localized: "TablePro writes this format with a plugin it downloads from the plugin registry."),
            window: window
        ) { progress in
            try await PluginManager.shared.installMissingExportFormat(format, progress: progress)
        }
    }

    internal static func ensureInstalled(for type: DatabaseType, opening url: URL) async -> Bool {
        // A Finder open is routed before eager-path plugins register, so asking first offers one the user has.
        if !PluginManager.shared.isDriverInstalled(for: type) {
            await PluginManager.shared.waitForInitialLoad()
        }
        guard !PluginManager.shared.isDriverInstalled(for: type) else { return true }
        // A bundled driver that did not load is disabled or damaged; the connect attempt reports which.
        guard type.isDownloadablePlugin else { return true }

        let displayName = PluginMetadataRegistry.shared.snapshot(for: type)?.displayName ?? type.rawValue
        return await confirmAndRun(
            pluginName: displayName,
            title: String(
                format: String(localized: "Install the %@ plugin to open “%@”?"),
                displayName,
                url.lastPathComponent
            ),
            message: String(localized: "TablePro reads this file with a driver it downloads from the plugin registry."),
            window: nil
        ) { progress in
            try await PluginManager.shared.installMissingPlugin(for: type, progress: progress)
        }
    }

    internal static func run(pluginName: String, window: NSWindow?, _ install: Install) async -> Bool {
        do {
            try await PluginInstallProgressPresenter.run(
                title: String(format: String(localized: "Downloading the %@ plugin…"), pluginName),
                window: window,
                install
            )
            logger.info("Installed the \(pluginName, privacy: .public) plugin")
            return true
        } catch {
            logger.error("Install failed for \(pluginName, privacy: .public): \(error.publicLogShape, privacy: .public)")
            AlertHelper.showErrorSheet(
                title: String(localized: "Plugin Installation Failed"),
                message: error.localizedDescription,
                window: window
            )
            return false
        }
    }

    private static func confirmAndRun(
        pluginName: String,
        title: String,
        message: String,
        window: NSWindow?,
        install: Install
    ) async -> Bool {
        let confirmed = await AlertHelper.confirm(
            title: title,
            message: message,
            confirmButton: String(localized: "Install"),
            window: window
        )
        guard confirmed else { return false }
        return await run(pluginName: pluginName, window: window, install)
    }
}
