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

    // MARK: - NSApplicationDelegate

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenURLs(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        PluginManager.shared.loadPlugins()
        ConnectionStorage.shared.migratePluginSecureFieldsIfNeeded()

        Task { @MainActor in
            LicenseManager.shared.startPeriodicValidation()
        }

        AnalyticsService.shared.startPeriodicHeartbeat()

        SyncCoordinator.shared.start()

        Task.detached(priority: .background) {
            _ = QueryHistoryStorage.shared
        }

        configureWelcomeWindow()

        let settings = AppSettingsStorage.shared.loadGeneral()
        if settings.startupBehavior == .reopenLast,
           let lastConnectionId = AppSettingsStorage.shared.loadLastConnectionId() {
            attemptAutoReconnect(connectionId: lastConnectionId)
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
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SyncCoordinator.shared.syncIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
        SSHTunnelManager.shared.terminateAllProcessesSync()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
