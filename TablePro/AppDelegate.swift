//
//  AppDelegate.swift
//  TablePro
//
//  Window configuration using AppKit-native approach
//

import AppKit
import os
import SwiftUI

internal extension URL {
    /// Returns the URL string with the password component replaced by `***` for safe logging.
    var sanitizedForLogging: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.password != nil else {
            return absoluteString
        }
        components.password = "***"
        return components.string ?? absoluteString
    }
}

/// AppDelegate handles window lifecycle events using proper AppKit patterns.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppDelegate")

    /// Track windows that have been configured to avoid re-applying styles
    var configuredWindows = Set<ObjectIdentifier>()

    /// SQL files queued until a database connection is active (drained on .databaseDidConnect)
    var queuedFileURLs: [URL] = []

    /// Database URL and SQLite file entries queued until the SwiftUI window system is ready
    var queuedURLEntries: [QueuedURLEntry] = []

    /// True while handling a file-open event — suppresses welcome window
    var isHandlingFileOpen = false

    /// Counter for outstanding suppressions; welcome window is suppressed while > 0
    var fileOpenSuppressionCount = 0

    /// True while a queued URL polling task is active — prevents duplicate pollers
    var isProcessingQueuedURLs = false

    /// True while auto-reconnect is in progress at startup
    var isAutoReconnecting = false

    /// ConnectionIds currently being connected from URL handlers.
    /// Prevents duplicate connections when the same URL is opened twice rapidly.
    var connectingURLConnectionIds = Set<UUID>()

    /// Normalized param keys for URLs currently being connected.
    /// Catches duplicates even before connectToSession creates the session.
    var connectingURLParamKeys = Set<String>()

    /// File paths currently being connected from file-open handlers.
    /// Prevents duplicate connections when the same file is opened twice rapidly.
    var connectingFilePaths = Set<String>()

    /// Connection share file URL pending consumption by WelcomeViewModel.setUp()
    var pendingConnectionShareURL: URL?

    // MARK: - NSApplicationDelegate

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenURLs(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-apply appearance now that NSApp exists.
        // AppSettingsManager.shared may already be initialized (by @State in TableProApp),
        // but NSApp was nil at that point so NSApp?.appearance was a no-op.
        let appearanceSettings = AppSettingsManager.shared.appearance
        ThemeEngine.shared.updateAppearanceAndTheme(
            mode: appearanceSettings.appearanceMode,
            lightThemeId: appearanceSettings.preferredLightThemeId,
            darkThemeId: appearanceSettings.preferredDarkThemeId
        )

        NSWindow.allowsAutomaticWindowTabbing = true
        let syncSettings = AppSettingsStorage.shared.loadSync()
        let passwordSyncExpected = syncSettings.enabled && syncSettings.syncConnections && syncSettings.syncPasswords
        let previousSyncState = UserDefaults.standard.bool(forKey: KeychainHelper.passwordSyncEnabledKey)
        UserDefaults.standard.set(passwordSyncExpected, forKey: KeychainHelper.passwordSyncEnabledKey)
        Task.detached(priority: .utility) {
            KeychainHelper.shared.migrateFromLegacyKeychainIfNeeded()
        }
        if passwordSyncExpected != previousSyncState {
            Task.detached(priority: .background) {
                KeychainHelper.shared.migratePasswordSyncState(synchronizable: passwordSyncExpected)
            }
        }
        DatabaseManager.shared.startObservingSystemEvents()

        MemoryPressureAdvisor.startMonitoring()
        PluginManager.shared.loadPlugins()
        ConnectionStorage.shared.migratePluginSecureFieldsIfNeeded()

        Task { @MainActor in
            LicenseManager.shared.startPeriodicValidation()
        }

        AnalyticsService.shared.startPeriodicHeartbeat()

        SyncCoordinator.shared.start()
        LinkedFolderWatcher.shared.start()

        Task.detached(priority: .background) {
            _ = QueryHistoryStorage.shared
        }

        let settings = AppSettingsStorage.shared.loadGeneral()
        if settings.startupBehavior == .reopenLast {
            let connectionIds = AppSettingsStorage.shared.loadLastOpenConnectionIds()
            if !connectionIds.isEmpty {
                closeWelcomeWindowEagerly()
                attemptAutoReconnectAll(connectionIds: connectionIds)
            } else if let lastConnectionId = AppSettingsStorage.shared.loadLastConnectionId() {
                // Backward compat: fall back to single lastConnectionId for upgrades
                closeWelcomeWindowEagerly()
                attemptAutoReconnect(connectionId: lastConnectionId)
            } else {
                // Crash recovery: if the app crashed before applicationWillTerminate
                // could save the list, scan the TabState directory for connections
                // that still have saved tab state on disk.
                Task { @MainActor [weak self] in
                    let diskIds = await TabDiskActor.shared.connectionIdsWithSavedState()
                    if !diskIds.isEmpty {
                        self?.closeWelcomeWindowEagerly()
                        self?.attemptAutoReconnectAll(connectionIds: diskIds)
                    } else {
                        self?.closeRestoredMainWindows()
                    }
                }
            }
        } else {
            closeRestoredMainWindows()
        }

        // NOTE: These observers are not explicitly removed because AppDelegate
        // lives for the entire app lifetime. NotificationCenter uses weak
        // references for selector-based observers on macOS 10.11+.

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeOcclusionState(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDatabaseDidConnect),
            name: .databaseDidConnect, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePluginsRejected(_:)),
            name: .pluginsRejected, object: nil
        )
    }

    @objc private func handlePluginsRejected(_ notification: Notification) {
        guard let rejected = notification.object as? [(name: String, reason: String)],
              !rejected.isEmpty else { return }
        let details = rejected.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = String(
                format: String(localized: "%d plugin(s) could not be loaded"),
                rejected.count
            )
            alert.informativeText = String(
                format: String(localized: "The following plugins were rejected:\n\n%@\n\nPlease update them from the plugin registry."),
                details
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SyncCoordinator.shared.syncIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasUnsaved = MainContentCoordinator.hasAnyUnsavedChanges()
        guard hasUnsaved else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "You have unsaved changes")
        alert.informativeText = String(localized: "Some tabs have unsaved edits. Quitting will discard these changes.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save all currently open connection IDs for multi-session restore.
        // Sort by connection name for deterministic restore order across launches
        // (Dictionary.keys has no guaranteed order).
        let connections = ConnectionStorage.shared.loadConnections()
        let activeIds = Set(DatabaseManager.shared.activeSessions.keys)
        let openConnectionIds = connections
            .filter { activeIds.contains($0.id) }
            .map(\.id)
        AppSettingsStorage.shared.saveLastOpenConnectionIds(openConnectionIds)

        LinkedFolderWatcher.shared.stop()
        UserDefaults.standard.synchronize()
        SSHTunnelManager.shared.terminateAllProcessesSync()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
