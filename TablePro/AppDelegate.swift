//
//  AppDelegate.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AppDelegate")
    nonisolated static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    private var hasRunPostLaunchActivation = false

    // MARK: - URL & File Open

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTracer.shared.mark(.willFinishLaunchingBegan)
        AppSettingsStorage.shared.migrateStartupBehaviorToReopenLastIfNeeded()
        AppSettingsStorage.shared.migrateJsonFieldHeightKeyIfNeeded()
        AIProviderRegistration.registerAll()

        /// Installed before any window exists, so the bar is correct from the first frame.
        /// Nothing else owns it now that the app no longer runs a SwiftUI `App`.
        MainMenuBuilder.install(keyboard: AppSettingsManager.shared.keyboard)
        LaunchTracer.shared.mark(.menuInstalled)

        _ = InspectorDocumentController()
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        PluginManager.shared.loadPlugins()
        LaunchTracer.shared.mark(.pluginsDiscovered)
        LaunchTracer.shared.mark(.willFinishLaunchingEnded)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Logger(subsystem: "com.TablePro", category: "CSVInspector")
            .debug("AppDelegate.application(_:open:) urls=\(urls.map(\.lastPathComponent).joined(separator: ","), privacy: .public)")
        AppLaunchCoordinator.shared.handleOpenURLs(urls)
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        AppLaunchCoordinator.shared.handleHandoff(userActivity)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppLaunchCoordinator.shared.handleReopen(hasVisibleWindows: flag)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTracer.shared.mark(.didFinishLaunchingBegan)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.logger.info("Running under XCTest, skipping normal app startup")
            return
        }

        /// `AppSettingsManager.init` has already resolved the theme from these same three values.
        /// Only a screenshot run overrides the mode, so only a screenshot run resolves it twice.
        if let screenshotMode = ScreenshotEnvironment.appearanceMode {
            let appearanceSettings = AppSettingsManager.shared.appearance
            ThemeEngine.shared.updateAppearanceAndTheme(
                mode: screenshotMode,
                lightThemeId: appearanceSettings.preferredLightThemeId,
                darkThemeId: appearanceSettings.preferredDarkThemeId
            )
        }

        NSWindow.allowsAutomaticWindowTabbing = true
        WindowOpener.shared.setWelcomePresenter { WelcomeWindowController.present() }
        WindowOpener.shared.setConnectionFormPresenter { ConnectionFormWindowController.present($0) }
        WindowOpener.shared.setIntegrationsActivityPresenter { IntegrationsActivityWindowController.present() }
        WindowOpener.shared.setSettingsPresenter { SettingsWindowController.present(pane: $0) }
        WindowOpener.shared.setCompareSyncPresenter { CompareSyncWindowController.present(prefillSource: $0) }
        KeyRepeatFilter.shared.install()
        let syncSettings = AppSettingsStorage.shared.loadSync()
        let passwordSyncExpected = syncSettings.enabled && syncSettings.syncConnections && syncSettings.syncPasswords
        AppStorageEnvironment.shared.defaults.set(passwordSyncExpected, forKey: KeychainHelper.passwordSyncEnabledKey)
        DatabaseManager.shared.startObservingSystemEvents()
        DatabaseManager.shared.tabStatePersister = SessionTabStatePersister()

        /// A notification the person acted on to launch the app is delivered as soon as
        /// `applicationDidFinishLaunching` returns, before any window has a frame. Apple documents
        /// the delegate assignment for that reason, and the two services below own the categories
        /// `NotificationRouter` looks the action up in, so deferring either drops the action.
        UNUserNotificationCenter.current().delegate = self
        PluginNotificationService.shared.setUp()
        OperationCompletionReporter.shared.setUp()
        ChatToolBootstrap.register()
        /// Sessions are listed again here, synchronously, because this runs before any window exists
        /// and therefore before anything can ask the registry for one. A task instead of a call
        /// leaves a window in which `session(for:)` finds an empty list, creates a session, and is
        /// then joined by the stored one, which is two sessions on one conversation. Measured on the
        /// record shape this reads: 0.08ms for ten sessions, 0.6ms for two hundred.
        AgentSessionRegistry.shared.restoreIfNeeded()

        /// Prerequisites for a connection, not post-launch work: a `cloudflared` or
        /// `cloud-sql-proxy` left behind by a crash still holds its local port, and a restored
        /// connection reaches `ensureConnected` while intents are routing. Both hop straight off
        /// the main actor, so starting them here costs the first frame nothing.
        Task { await CloudflareTunnelManager.shared.sweepStalePidsIfNeeded() }
        Task { await CloudSQLProxyManager.shared.sweepStalePidsIfNeeded() }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        LaunchTracer.shared.mark(.didFinishLaunchingEnded)
        AppLaunchCoordinator.shared.didFinishLaunching()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runPostLaunchActivationIfNeeded()
        guard !AppStorageEnvironment.shared.isIsolated else { return }
        SyncCoordinator.shared.syncIfNeeded()
    }

    private func runPostLaunchActivationIfNeeded() {
        guard !hasRunPostLaunchActivation else { return }
        hasRunPostLaunchActivation = true
        guard !AppStorageEnvironment.shared.isIsolated else { return }

        ConnectionStorage.shared.migratePluginSecureFieldsIfNeeded()
        AnalyticsService.shared.startPeriodicHeartbeat()
        SyncCoordinator.shared.start()
        LinkedFolderWatcher.shared.start()
        TeamLibrarySyncCoordinator.shared.start()

        Task {
            LicenseManager.shared.startPeriodicValidation()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Unhiding is the one way a window comes back without any window notification firing, and the
    /// app reports every window it owns as invisible while it is hidden.
    func applicationDidUnhide(_ notification: Notification) {
        AppActivationPolicyController.shared.reevaluate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if CompareSyncRunRegistry.shared.isApplying {
            let alert = NSAlert()
            alert.messageText = String(localized: "A sync is still running")
            alert.informativeText = String(
                format: String(localized: "Quitting stops the run against %@. Statements that already ran stay applied."),
                CompareSyncRunRegistry.shared.applyingTargetNames.joined(separator: ", ")
            )
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Keep Running"))
            alert.addButton(withTitle: String(localized: "Stop and Quit"))
            alert.buttons[1].hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }

        let hasUnsaved = MainContentCoordinator.hasAnyUnsavedChanges()
        if hasUnsaved {
            /// Quitting can be asked for from outside the app, so this alert has to come forward on
            /// its own: it blocks termination in a nested modal loop, and a background process has
            /// no Dock icon to reach it by.
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = String(localized: "You have unsaved changes")
            alert.informativeText = String(localized: "Some tabs have unsaved edits. Quitting will discard these changes.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Cancel"))
            alert.addButton(withTitle: String(localized: "Quit Anyway"))
            alert.buttons[1].hasDestructiveAction = true
            let response = alert.runModal()
            guard response == .alertSecondButtonReturn else { return .terminateCancel }
        }

        Task {
            await MCPServerManager.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistOpenConnectionsForRecovery()
        /// Nothing used to persist AI state at quit, so a session killed mid-stream came back with
        /// its last turn missing and no record that it had been working. Written synchronously: an
        /// actor hop here may never be scheduled before the process exits.
        AgentSessionRegistry.shared.persistAtTerminate()
        LinkedFolderWatcher.shared.stop()
        SQLFolderWatcher.shared.stop()
        SSHTunnelManager.shared.terminateAllProcessesSync()
        CloudflareTunnelManager.shared.terminateAllProcessesSync()
        CloudSQLProxyManager.shared.terminateAllProcessesSync()
    }

    private func persistOpenConnectionsForRecovery() {
        LastOpenConnectionsStorage.shared.save(connectionIds: SessionRecoveryTracker.connectionIds())
    }

    @objc func handleSystemDidWake(_ notification: Notification) {
        SQLFolderWatcher.shared.reload()
    }


    // MARK: - Window Notifications

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        let csvLogger = Logger(subsystem: "com.TablePro", category: "CSVInspector")
        let isPrimary = AppLaunchCoordinator.isMainWindow(window)
        if isPrimary {
            let remaining = NSApp.windows.filter {
                $0 !== window && AppLaunchCoordinator.isMainWindow($0) && $0.isVisible
            }.count
            csvLogger.debug("AppDelegate.windowWillClose - main window '\(window.identifier?.rawValue ?? "nil", privacy: .public)' closing, remaining main windows=\(remaining, privacy: .public)")
            if WelcomeVisibilityPolicy.shouldPresentWelcome(
                closingWindowWasPrimary: isPrimary,
                remainingVisiblePrimaryWindows: remaining,
                sessionOrigin: AppActivationPolicyController.shared.origin
            ) {
                AppEvents.shared.mainWindowWillClose.send(())
                WindowOpener.shared.openWelcome()
            }
        } else {
            csvLogger.debug("AppDelegate.windowWillClose - non-main window '\(window.identifier?.rawValue ?? "nil", privacy: .public)' closing")
        }
        /// Any window, not only a primary one: a machine-started session can have nothing on screen
        /// but a settings window, and closing it leaves the process with no user interface again.
        AppActivationPolicyController.shared.reevaluate(excluding: window)
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let welcomeItem = NSMenuItem(
            title: String(localized: "Show Welcome Window"),
            action: #selector(showWelcomeFromDock),
            keyEquivalent: ""
        )
        welcomeItem.target = self
        menu.addItem(welcomeItem)

        let connections = ConnectionStorage.shared.loadConnections()
        if !connections.isEmpty {
            let connectionsItem = NSMenuItem(title: String(localized: "Open Connection"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            for connection in connections {
                let item = NSMenuItem(
                    title: connection.name,
                    action: #selector(connectFromDock(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = connection.id
                let iconName = connection.type.iconName
                let original = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                    ?? NSImage(named: iconName)
                if let original {
                    let resized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                        original.draw(in: rect)
                        return true
                    }
                    item.image = resized
                }
                submenu.addItem(item)
            }

            connectionsItem.submenu = submenu
            menu.addItem(connectionsItem)
        }

        return menu
    }

    @objc func showWelcomeFromDock() {
        WindowOpener.shared.openWelcome()
    }

    @objc func connectFromDock(_ sender: NSMenuItem) {
        guard let connectionId = sender.representedObject as? UUID else { return }
        Task {
            await LaunchIntentRouter.shared.route(.openConnection(connectionId))
        }
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

/// Carries a UserNotifications callback from the delegate thread to the main actor.
/// UNUserNotificationCenter hands each one over exactly once and keeps no reference.
private struct NotificationDelivery<Payload>: @unchecked Sendable {
    let payload: Payload
    let complete: () -> Void
}

private struct NotificationPresentationRequest: @unchecked Sendable {
    let notification: UNNotification
    let respond: (UNNotificationPresentationOptions) -> Void
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = NotificationPresentationRequest(notification: notification, respond: completionHandler)
        Task { @MainActor in
            request.respond(NotificationRouter.shared.presentationOptions(for: request.notification))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let delivery = NotificationDelivery(payload: response, complete: completionHandler)
        Task { @MainActor in
            defer { delivery.complete() }
            NotificationRouter.shared.handle(delivery.payload)
        }
    }
}
