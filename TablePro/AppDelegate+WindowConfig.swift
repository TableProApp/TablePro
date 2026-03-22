//
//  AppDelegate+WindowConfig.swift
//  TablePro
//
//  Window lifecycle, styling, dock menu, and auto-reconnect
//

import AppKit
import os
import SwiftUI

private let windowLogger = Logger(subsystem: "com.TablePro", category: "WindowConfig")

extension AppDelegate {
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

    @objc func connectFromDock(_ sender: NSMenuItem) {
        guard let connectionId = sender.representedObject as? UUID else { return }
        let connections = ConnectionStorage.shared.loadConnections()
        guard let connection = connections.first(where: { $0.id == connectionId }) else { return }

        NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

        Task { @MainActor in
            do {
                try await DatabaseManager.shared.connectToSession(connection)

                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch {
                windowLogger.error("Dock connection failed for '\(connection.name)': \(error.localizedDescription)")

                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }
                self.openWelcomeWindow()
            }
        }
    }

    // MARK: - Reopen Handling

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            return true
        }

        openWelcomeWindow()
        return false
    }

    // MARK: - Window Identification

    func isMainWindow(_ window: NSWindow) -> Bool {
        guard let identifier = window.identifier?.rawValue else { return false }
        return identifier.contains("main")
    }

    func isWelcomeWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "welcome" ||
            window.title.lowercased().contains("welcome")
    }

    private func isConnectionFormWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("connection-form") == true
    }

    // MARK: - Welcome Window

    func openWelcomeWindow() {
        for window in NSApp.windows where isWelcomeWindow(window) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        NotificationCenter.default.post(name: .openWelcomeWindow, object: nil)
    }

    func configureWelcomeWindow() {
        Task { @MainActor [weak self] in
            for _ in 0 ..< 5 {
                guard let self else { return }
                let found = NSApp.windows.contains(where: { self.isWelcomeWindow($0) })
                if found {
                    for window in NSApp.windows where self.isWelcomeWindow(window) {
                        self.configureWelcomeWindowStyle(window)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

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

        window.level = .floating
    }

    // MARK: - Welcome Window Suppression

    func scheduleWelcomeWindowSuppression() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.closeWelcomeWindowIfMainExists()
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.closeWelcomeWindowIfMainExists()
            self.fileOpenSuppressionCount = max(0, self.fileOpenSuppressionCount - 1)
            if self.fileOpenSuppressionCount == 0 {
                self.isHandlingFileOpen = false
            }
        }
    }

    private func closeWelcomeWindowIfMainExists() {
        let hasMainWindow = NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
        guard hasMainWindow else { return }
        for window in NSApp.windows where isWelcomeWindow(window) {
            window.close()
        }
    }

    // MARK: - Window Notifications

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let windowId = ObjectIdentifier(window)

        if isWelcomeWindow(window) && isHandlingFileOpen {
            window.close()
            for mainWin in NSApp.windows where isMainWindow(mainWin) {
                mainWin.makeKeyAndOrderFront(nil)
            }
            return
        }

        if isWelcomeWindow(window) && !configuredWindows.contains(windowId) {
            configureWelcomeWindowStyle(window)
            configuredWindows.insert(windowId)
        }

        if isConnectionFormWindow(window) && !configuredWindows.contains(windowId) {
            configureConnectionFormWindowStyle(window)
            configuredWindows.insert(windowId)
        }

        if isMainWindow(window) && !configuredWindows.contains(windowId) {
            window.tabbingMode = .preferred
            let pendingId = MainActor.assumeIsolated { WindowOpener.shared.consumePendingConnectionId() }
            let existingIdentifier = NSApp.windows
                .first { $0 !== window && isMainWindow($0) && $0.isVisible }?
                .tabbingIdentifier
            window.tabbingIdentifier = TabbingIdentifierResolver.resolve(
                pendingConnectionId: pendingId,
                existingIdentifier: existingIdentifier
            )
            configuredWindows.insert(windowId)

            if !NSWindow.allowsAutomaticWindowTabbing {
                NSWindow.allowsAutomaticWindowTabbing = true
            }
        }
    }

    @objc func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        configuredWindows.remove(ObjectIdentifier(window))

        if isMainWindow(window) {
            let remainingMainWindows = NSApp.windows.filter {
                $0 !== window && isMainWindow($0) && $0.isVisible
            }.count

            if remainingMainWindows == 0 {
                NotificationCenter.default.post(name: .mainWindowWillClose, object: nil)

                DispatchQueue.main.async {
                    self.openWelcomeWindow()
                }
            }
        }
    }

    @objc func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isHandlingFileOpen else { return }

        if isWelcomeWindow(window),
           window.occlusionState.contains(.visible),
           NSApp.windows.contains(where: { isMainWindow($0) && $0.isVisible }) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isWelcomeWindow(window), window.isVisible {
                    window.close()
                }
            }
        }
    }

    // MARK: - Auto-Reconnect

    func attemptAutoReconnect(connectionId: UUID) {
        let connections = ConnectionStorage.shared.loadConnections()
        guard let connection = connections.first(where: { $0.id == connectionId }) else {
            AppSettingsStorage.shared.saveLastConnectionId(nil)
            closeRestoredMainWindows()
            openWelcomeWindow()
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

            Task { @MainActor in
                do {
                    try await DatabaseManager.shared.connectToSession(connection)

                    for window in NSApp.windows where self.isWelcomeWindow(window) {
                        window.close()
                    }
                } catch {
                    windowLogger.error("Auto-reconnect failed for '\(connection.name)': \(error.localizedDescription)")

                    for window in NSApp.windows where self.isMainWindow(window) {
                        window.close()
                    }

                    self.openWelcomeWindow()
                }
            }
        }
    }

    func closeRestoredMainWindows() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                window.close()
            }
        }
    }
}
