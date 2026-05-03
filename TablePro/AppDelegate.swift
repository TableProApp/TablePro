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
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            Self.logger.info("Running under XCTest, skipping normal app startup")
            return
        }

        let appearanceSettings = AppSettingsManager.shared.appearance
        ThemeEngine.shared.updateAppearanceAndTheme(
            mode: appearanceSettings.appearanceMode,
            lightThemeId: appearanceSettings.preferredLightThemeId,
            darkThemeId: appearanceSettings.preferredDarkThemeId
        )

        NSWindow.allowsAutomaticWindowTabbing = true
        let syncSettings = AppSettingsStorage.shared.loadSync()
        let passwordSyncExpected = syncSettings.enabled && syncSettings.syncConnections && syncSettings.syncPasswords
        UserDefaults.standard.set(passwordSyncExpected, forKey: KeychainHelper.passwordSyncEnabledKey)
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

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        if AppLaunchCoordinator.isMainWindow(window) {
            let remaining = NSApp.windows.filter {
                $0 !== window && AppLaunchCoordinator.isMainWindow($0) && $0.isVisible
            }.count
            if remaining == 0 {
                NotificationCenter.default.post(name: .mainWindowWillClose, object: nil)
                WelcomeWindowFactory.openOrFront()
            }
        }
    }

    @objc func handleFocusConnectionForm() {
        if let window = NSApp.windows.first(where: { AppLaunchCoordinator.isConnectionFormWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
        }
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
        WelcomeWindowFactory.openOrFront()
    }

    @objc func newWindowForTab(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let connectionId = MainActor.assumeIsolated({
                  WindowLifecycleMonitor.shared.connectionId(forWindow: keyWindow)
              })
        else { return }

        MainActor.assumeIsolated {
            if let actions = MainContentCoordinator.allActiveCoordinators()
                .first(where: { $0.connectionId == connectionId })?.commandActions {
                actions.newTab()
            } else {
                WindowManager.shared.openTab(
                    payload: EditorTabPayload(connectionId: connectionId, intent: .newEmptyTab)
                )
            }
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
