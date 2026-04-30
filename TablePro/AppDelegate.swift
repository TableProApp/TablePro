//
//  AppDelegate.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AppDelegate")
    static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    var configuredWindows = Set<ObjectIdentifier>()

    // MARK: - URL & File Open

    func application(_ application: NSApplication, open urls: [URL]) {
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

        Task {
            LicenseManager.shared.startPeriodicValidation()
        }

        AnalyticsService.shared.startPeriodicHeartbeat()

        SyncCoordinator.shared.start()
        LinkedFolderWatcher.shared.start()

        if AppSettingsManager.shared.mcp.enabled {
            Task {
                await MCPServerManager.shared.start(port: UInt16(clamping: AppSettingsManager.shared.mcp.port))
            }
        }

        Task.detached(priority: .background) {
            _ = QueryHistoryStorage.shared
        }

        AppLaunchCoordinator.shared.didFinishLaunching()

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePluginsRejected(_:)),
            name: .pluginsRejected, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFocusConnectionForm),
            name: .focusConnectionFormWindowRequested, object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        SyncCoordinator.shared.syncIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasUnsaved = MainContentCoordinator.hasAnyUnsavedChanges()
        if hasUnsaved {
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
        LinkedFolderWatcher.shared.stop()
        TerminalProcessManager.registry.terminateAllSync()
        SSHTunnelManager.shared.terminateAllProcessesSync()
    }

    @objc func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://docs.tablepro.app") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Plugin Rejection Alert

    @objc private func handlePluginsRejected(_ notification: Notification) {
        guard let rejected = notification.object as? [RejectedPlugin],
              !rejected.isEmpty else { return }
        let details = rejected.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        Task {
            let alert = NSAlert()
            alert.messageText = String(
                format: String(localized: "%d plugin(s) could not be loaded"),
                rejected.count
            )
            alert.informativeText = String(
                format: String(localized: "The following plugins were rejected:\n\n%@\n\nYou can update them from the plugin registry in Settings."),
                details
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Open Plugin Settings"))
            alert.addButton(withTitle: String(localized: "Dismiss"))

            let response: NSApplication.ModalResponse
            if let window = AlertHelper.resolveWindow(nil) {
                response = await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { resp in
                        continuation.resume(returning: resp)
                    }
                }
            } else {
                response = alert.runModal()
            }

            if response == .alertFirstButtonReturn {
                UserDefaults.standard.set(SettingsTab.plugins.rawValue, forKey: "selectedSettingsTab")
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
        }
    }

    // MARK: - Window Notifications

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let windowId = ObjectIdentifier(window)

        if AppLaunchCoordinator.isWelcomeWindow(window) && !configuredWindows.contains(windowId) {
            configureWelcomeWindowStyle(window)
            configuredWindows.insert(windowId)
        }

        if AppLaunchCoordinator.isConnectionFormWindow(window) && !configuredWindows.contains(windowId) {
            configureConnectionFormWindowStyle(window)
            configuredWindows.insert(windowId)
        }
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configuredWindows.remove(ObjectIdentifier(window))

        if AppLaunchCoordinator.isMainWindow(window) {
            let remaining = NSApp.windows.filter {
                $0 !== window && AppLaunchCoordinator.isMainWindow($0) && $0.isVisible
            }.count
            if remaining == 0 {
                NotificationCenter.default.post(name: .mainWindowWillClose, object: nil)
                openWelcomeWindow()
            }
        }
    }

    @objc func handleFocusConnectionForm() {
        if let window = NSApp.windows.first(where: { AppLaunchCoordinator.isConnectionFormWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func openWelcomeWindow() {
        for window in NSApp.windows where AppLaunchCoordinator.isWelcomeWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        NotificationCenter.default.post(name: .openWelcomeWindow, object: nil)
    }

    // MARK: - Window Style

    private func configureWelcomeWindowStyle(_ window: NSWindow) {
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.styleMask.remove(.miniaturizable)

        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)

        if window.styleMask.contains(.resizable) {
            window.styleMask.remove(.resizable)
        }

        let welcomeSize = NSSize(width: 700, height: 450)
        if window.frame.size != welcomeSize {
            window.setContentSize(welcomeSize)
            window.center()
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true

        window.makeKeyAndOrderFront(nil)

        if let textField = window.contentView?.firstEditableTextField() {
            window.makeFirstResponder(textField)
        }
    }

    private func configureConnectionFormWindowStyle(_ window: NSWindow) {
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.styleMask.remove(.miniaturizable)

        window.collectionBehavior.remove(.fullScreenPrimary)
        window.collectionBehavior.insert(.fullScreenNone)
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
        openWelcomeWindow()
    }

    @objc func newWindowForTab(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let connectionId = MainActor.assumeIsolated({
                  WindowLifecycleMonitor.shared.connectionId(forWindow: keyWindow)
              })
        else { return }

        let payload = EditorTabPayload(
            connectionId: connectionId,
            intent: .newEmptyTab
        )
        MainActor.assumeIsolated {
            WindowManager.shared.openTab(payload: payload)
        }
    }

    @objc func connectFromDock(_ sender: NSMenuItem) {
        guard let connectionId = sender.representedObject as? UUID else { return }
        Task {
            await LaunchIntentRouter.shared.route(.openConnection(connectionId))
        }
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
