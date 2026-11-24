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

    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchTracer.shared.mark(.willFinishLaunchingBegan)
        // First: the migration below writes the flag that tells an existing install from a new one.
        AppModule.recordDefaults(
            in: AppStorageEnvironment.shared.defaults,
            isExistingInstall: AppSettingsStorage.shared.hasLaunchedBefore()
        )
        AppSettingsStorage.shared.migrateStartupBehaviorToReopenLastIfNeeded()
        AppSettingsStorage.shared.removeRetiredFieldHeightKeys()
        AIProviderRegistration.registerAll()
        // Before sync can pull a language change, and not earlier: settings built before the migrations above would miss them.
        LanguageLaunchState.record()

        // Before any window exists, so the bar is right from the first frame.
        MainMenuBuilder.install(keyboard: AppSettingsManager.shared.keyboard)
        MainMenuBuilder.syncKeyEquivalentsOnKeyWindowChange()
        LaunchTracer.shared.mark(.menuInstalled)

        _ = DataFileDocumentController()
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if #available(macOS 14.0, *) {
            FeatureTipsBootstrap.configure()
        }
        PluginManager.shared.loadPlugins()
        LaunchTracer.shared.mark(.pluginsDiscovered)
        LaunchTracer.shared.mark(.willFinishLaunchingEnded)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Logger(subsystem: "com.TablePro", category: "DataFiles")
            .debug("AppDelegate.application(_:open:) urls=\(urls.map(\.lastPathComponent).joined(separator: ","), privacy: .private(mask: .hash))")
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTracer.shared.mark(.didFinishLaunchingBegan)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.logger.info("Running under XCTest, skipping normal app startup")
            return
        }

        // AppSettingsManager.init already resolved the theme; only a screenshot run overrides the mode and resolves again.
        if let screenshotMode = ScreenshotEnvironment.appearanceMode {
            let appearanceSettings = AppSettingsManager.shared.appearance
            ThemeEngine.shared.apply(
                mode: screenshotMode,
                lightThemeId: appearanceSettings.preferredLightThemeId,
                darkThemeId: appearanceSettings.preferredDarkThemeId
            )
        }

        NSWindow.allowsAutomaticWindowTabbing = true
        WindowOpener.shared.setWelcomePresenter { WelcomeWindowController.present() }
        WindowOpener.shared.setConnectionFormPresenter { ConnectionEditorWindowController.present($0, facet: $1) }
        WindowOpener.shared.setIntegrationsActivityPresenter { IntegrationsActivityWindowController.present() }
        WindowOpener.shared.setSettingsPresenter { SettingsWindowController.present($0) }
        KeyRepeatFilter.shared.install()
        TableClickFocus.shared.install()
        RecentTabSwitcherController.installEditorKeyClaim()
        AppStorageEnvironment.shared.defaults.set(
            AppSettingsStorage.shared.loadSync().syncsPasswords,
            forKey: KeychainHelper.passwordSyncEnabledKey
        )
        DatabaseManager.shared.startObservingSystemEvents()
        DatabaseManager.shared.tabStatePersister = SessionTabStatePersister()

        // Not deferred: a launching notification's action arrives as soon as this returns, and these services own its categories.
        UNUserNotificationCenter.current().delegate = self
        PluginNotificationService.shared.setUp()
        OperationCompletionReporter.shared.setUp()
        AgentAttentionNotifier.shared.setUp()
        ChatToolBootstrap.register()

        // Not post-launch work: a crashed run's tunnel still holds its port when a restored connection reconnects.
        Task { await CloudflareTunnelManager.shared.sweepStalePidsIfNeeded() }
        Task { await CloudSQLProxyManager.shared.sweepStalePidsIfNeeded() }
        Task { await TunnelCommandManager.shared.sweepStalePidsIfNeeded() }
        Task { await RemoteDatabaseFileStore.shared.pruneAbandoned() }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        RecentConnectionsRecorder.shared.start()
        if #available(macOS 14.0, *) {
            ShortcutsParameterRefresher.shared.start()
        }

        // Before any intent routes: a launch with `open -g` reaches the gates and may never activate.
        AccountServices.shared.loadStoredState()

        LaunchTracer.shared.mark(.didFinishLaunchingEnded)
        AppLaunchCoordinator.shared.didFinishLaunching()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runPostLaunchActivationIfNeeded()
        guard !AppStorageEnvironment.shared.isIsolated else { return }
        SyncCoordinator.shared.syncIfNeeded()
        AccountServices.shared.applicationDidBecomeActive()
    }

    private func runPostLaunchActivationIfNeeded() {
        guard !hasRunPostLaunchActivation else { return }
        hasRunPostLaunchActivation = true
        guard !AppStorageEnvironment.shared.isIsolated else { return }

        ConnectionStorage.shared.migratePluginSecureFieldsIfNeeded()
        // Before sync starts, so a pulled change is never approved as part of the first use.
        for store in ConnectionApprovalStore.all {
            store.migrateIfNeeded()
        }
        ConnectionStorage.shared.moveMongoURISecretsToKeychain()
        ConnectionStorage.shared.keepLocalOnlySecretsOnDeviceIfNeeded()
        FavoriteTablesStorage.shared.migrateSyncIdentityIfNeeded()
        SoftwareUpdater.shared.start()
        // Before the account starts, so a stored key's migration reaches it as a sign-in.
        Telemetry.shared.start(
            sharesUsageData: AppSettingsManager.shared.generalSlice.publisher.map(\.shareAnalytics).eraseToAnyPublisher(),
            account: AccountServices.shared
        )
        AccountServices.shared.start()
        SyncCoordinator.shared.start()
        // Its gate reads the sign-in the core restores after launch.
        Task {
            await AccountServices.shared.waitUntilRestored()
            LinkedFolderWatcher.shared.start()
        }
        TeamLibrarySync.shared.start()
        SupportAskCoordinator.shared.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        SyncCoordinator.shared.pushRegistrationDidFinish(registered: true)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.logger.warning("Push registration failed: \(error.localizedDescription, privacy: .private)")
        SyncCoordinator.shared.pushRegistrationDidFinish(registered: false)
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        SyncCoordinator.shared.handleRemoteNotification(userInfo)
    }

    // Unhiding brings windows back with no window notification, and while hidden every window reports invisible.
    func applicationDidUnhide(_ notification: Notification) {
        AppActivationPolicyController.shared.reevaluate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The connection editors first: their Cancel keeps the app open before anything else is asked or stopped.
        guard ConnectionEditorWindowController.prepareToTerminate(), let plan = QuitApproval.approve() else {
            AppRelauncher.shared.terminationWasCancelled()
            return .terminateCancel
        }

        Task {
            // Team Library edits not uploaded live only in memory, so they are asked about while a Cancel changes nothing.
            guard await TeamLibraryUnsentChanges.approveQuit() else {
                NSApp.reply(toApplicationShouldTerminate: false)
                AppRelauncher.shared.terminationWasCancelled()
                return
            }
            // Before anything the app could not take back if it stays open.
            guard await QuitApproval.commitBeforeQuitting(plan) else {
                NSApp.reply(toApplicationShouldTerminate: false)
                AppRelauncher.shared.terminationWasCancelled()
                return
            }
            RunningWorkRegistry.shared.cancel(plan.work)
            // While the drivers are open: a debug stop rolls back the routine's transaction.
            await AppModuleTermination.stopModuleWork()
            await MCPServerManager.shared.stop()
            await DatabaseManager.shared.runPostDisconnectScriptsBeforeQuit()
            // A Vault lease outlives the app on the server until its TTL, so its database user goes now.
            await VaultDatabaseCredentials.shared.revokeAllLeases()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ConnectionEditorWindowController.closeAllForTermination()
        SessionRecoveryTracker.saveOnQuit()
        // Synchronously: an actor hop at terminate may never run, which lost a killed session's last turn.
        AgentSessionRegistry.shared.persistSynchronouslyForTermination()
        LinkedFolderWatcher.shared.stop()
        SQLFolderWatcher.shared.stop()
        SSHTunnelManager.shared.terminateAllProcessesSync()
        CloudflareTunnelManager.shared.terminateAllProcessesSync()
        CloudSQLProxyManager.shared.terminateAllProcessesSync()
        TunnelCommandManager.shared.terminateAllProcessesSync()
        RemoteSQLiteTransportManager.shared.terminateAllProcessesSync()
        AppRelauncher.shared.applicationWillTerminate()
    }

    @objc func handleSystemDidWake(_ notification: Notification) {
        SQLFolderWatcher.shared.reload()
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        let csvLogger = Logger(subsystem: "com.TablePro", category: "DataFiles")
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
        // Any window: a machine-started session may show only a settings window, and closing it leaves no UI.
        AppActivationPolicyController.shared.reevaluate(excluding: window)
    }

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
                if let original = LibraryGlyph.connectionNSImage(
                    type: connection.type,
                    iconName: connection.iconName,
                    accessibilityDescription: nil
                ) {
                    let resized = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                        original.draw(in: rect)
                        return true
                    }
                    item.setInformativeImage(resized)
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

// The center hands each callback over exactly once and keeps no reference, so carrying it to the main actor is safe.
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
