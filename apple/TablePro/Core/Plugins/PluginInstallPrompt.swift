import AppKit
import Combine
import os

@MainActor
internal enum PluginInstallPrompt {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "PluginInstallPrompt")

    internal typealias Install = PluginInstallProgressPresenter.Install

    // Only asks: a sheet that offers the format runs the install in place, so no panel opens on top of it.
    internal static func confirmInstall(_ format: InstallableExportFormat, window: NSWindow?) async -> Bool {
        await confirm(
            title: String(format: String(localized: "Install the %@ plugin?"), format.displayName),
            message: String(localized: "TablePro writes this format with a plugin it downloads from the plugin registry."),
            window: window
        )
    }

    internal static func install(_ format: InstallableExportFormat) -> Install {
        { onBegin in
            try await PluginManager.shared.installMissingExportFormat(format, onBegin: onBegin)
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
        ) { onBegin in
            try await PluginManager.shared.installMissingPlugin(for: type, onBegin: onBegin)
        }
    }

    internal static func run(pluginName: String, window: NSWindow?, _ install: @escaping Install) async -> Bool {
        do {
            try await PluginInstallProgressPresenter.run(pluginName: pluginName, window: window, install)
        } catch {
            reportFailure(error, pluginName: pluginName, window: window)
            return false
        }
        logger.info("Installed the \(pluginName, privacy: .public) plugin")
        return true
    }

    // The caller shows `progress` as its sheet's root. `onEnd` takes it down before a failure alert goes on that sheet.
    internal static func run(
        _ progress: PluginInstallRun,
        window: NSWindow?,
        onEnd: () -> Void,
        _ install: @escaping Install
    ) async -> Bool {
        do {
            try await progress.run(install)
        } catch {
            onEnd()
            reportFailure(error, pluginName: progress.pluginName, window: window)
            return false
        }
        onEnd()
        logger.info("Installed the \(progress.pluginName, privacy: .public) plugin")
        return true
    }

    private static func reportFailure(_ error: any Error, pluginName: String, window: NSWindow?) {
        guard !(error is CancellationError) else {
            logger.info("Install of the \(pluginName, privacy: .public) plugin was cancelled")
            return
        }
        logger.error("Install failed for \(pluginName, privacy: .public): \(error.publicLogShape, privacy: .public)")
        AlertHelper.showErrorSheet(
            title: String(localized: "Plugin Installation Failed"),
            message: error.localizedDescription,
            window: window
        )
    }

    private static func confirm(title: String, message: String, window: NSWindow?) async -> Bool {
        await AlertHelper.confirm(
            title: title,
            message: message,
            confirmButton: String(localized: "Install"),
            window: window
        )
    }

    private static func confirmAndRun(
        pluginName: String,
        title: String,
        message: String,
        window: NSWindow?,
        install: @escaping Install
    ) async -> Bool {
        guard await confirm(title: title, message: message, window: window) else { return false }
        return await run(pluginName: pluginName, window: window, install)
    }
}

// An install shown inside the caller's own sheet, with the panel presenter's tracker entry, cancel and errors.
@MainActor
internal final class PluginInstallRun: ObservableObject {
    @Published internal private(set) var display: PluginInstallProgressPresenter.Display
    @Published internal private(set) var didCancel = false
    internal let pluginName: String
    private let tracker: PluginInstallTracker
    private var followed: AnyCancellable?
    private var pluginId: String?
    private var task: Task<Void, any Error>?

    internal var canCancel: Bool {
        display.canCancel && !didCancel
    }

    internal init(pluginName: String, tracker: PluginInstallTracker = .shared) {
        self.pluginName = pluginName
        self.tracker = tracker
        display = .make(pluginName: pluginName, phase: nil)
    }

    // Throws `CancellationError` when the user cancelled, here or through the tracker entry.
    internal func run(_ install: @escaping PluginInstallPrompt.Install) async throws {
        let task = Task { @MainActor in
            try await install { pluginId in self.follow(pluginId: pluginId) }
        }
        self.task = task
        defer {
            self.task = nil
            followed = nil
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            guard !didCancel, !PluginInstallTracker.isCancellation(error) else { throw CancellationError() }
            throw error
        }
    }

    internal func cancel() {
        guard canCancel else { return }
        didCancel = true
        if let pluginId {
            tracker.cancel(pluginId: pluginId)
        }
        task?.cancel()
    }

    private func follow(pluginId: String) {
        self.pluginId = pluginId
        followed = tracker.$entries.sink { [weak self] entries in
            guard let self else { return }
            display = .make(pluginName: pluginName, phase: entries[pluginId]?.phase)
        }
    }
}
