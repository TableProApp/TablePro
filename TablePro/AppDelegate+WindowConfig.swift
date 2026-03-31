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

        WindowOpener.shared.pendingConnectionId = connection.id
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

    private enum WindowId {
        static let main = "main"
        static let welcome = "welcome"
        static let connectionForm = "connection-form"
    }

    func isMainWindow(_ window: NSWindow) -> Bool {
        guard let rawValue = window.identifier?.rawValue else { return false }
        return rawValue == WindowId.main || rawValue.hasPrefix("\(WindowId.main)-")
    }

    func isWelcomeWindow(_ window: NSWindow) -> Bool {
        guard let rawValue = window.identifier?.rawValue else { return false }
        return rawValue == WindowId.welcome || rawValue.hasPrefix("\(WindowId.welcome)-")
    }

    private func isConnectionFormWindow(_ window: NSWindow) -> Bool {
        guard let rawValue = window.identifier?.rawValue else { return false }
        return rawValue == WindowId.connectionForm || rawValue.hasPrefix("\(WindowId.connectionForm)-")
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

    /// Called by connection handlers when the file-open connection attempt finishes
    /// (success or failure). Decrements the suppression counter and resets the flag
    /// when all outstanding file opens have completed.
    func endFileOpenSuppression() {
        fileOpenSuppressionCount = max(0, fileOpenSuppressionCount - 1)
        if fileOpenSuppressionCount == 0 {
            isHandlingFileOpen = false
        }
    }

    @discardableResult
    private func closeWelcomeWindowIfMainExists() -> Bool {
        let hasMainWindow = NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
        guard hasMainWindow else { return false }
        for window in NSApp.windows where isWelcomeWindow(window) {
            window.close()
        }
        return true
    }

    // MARK: - Window Notifications

    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let windowId = ObjectIdentifier(window)

        if isWelcomeWindow(window) && isHandlingFileOpen {
            // Only close welcome if a main window exists to take its place;
            // otherwise just hide it so the user doesn't see a flash.
            if let mainWin = NSApp.windows.first(where: { isMainWindow($0) }) {
                window.close()
                mainWin.makeKeyAndOrderFront(nil)
            } else {
                window.orderOut(nil)
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

        if isMainWindow(window) && isHandlingFileOpen {
            closeWelcomeWindowIfMainExists()
        }

        if isMainWindow(window) && !configuredWindows.contains(windowId) {
            window.tabbingMode = .preferred
            window.isRestorable = false
            let pendingId = MainActor.assumeIsolated { WindowOpener.shared.consumePendingConnectionId() }

            // If no code opened this window (pendingId is nil), this is a
            // SwiftUI WindowGroup state restoration — not a window we created.
            // Hide it (orderOut, not close) to break the close→restore loop.
            if pendingId == nil && !isAutoReconnecting {
                configuredWindows.insert(windowId)
                window.orderOut(nil)
                return
            }

            let existingIdentifier = NSApp.windows
                .first { $0 !== window && isMainWindow($0) && $0.isVisible }?
                .tabbingIdentifier
            let resolvedIdentifier = TabbingIdentifierResolver.resolve(
                pendingConnectionId: pendingId,
                existingIdentifier: existingIdentifier
            )
            window.tabbingIdentifier = resolvedIdentifier
            configuredWindows.insert(windowId)

            if !NSWindow.allowsAutomaticWindowTabbing {
                NSWindow.allowsAutomaticWindowTabbing = true
            }

            // Explicitly attach to existing tab group — automatic tabbing
            // doesn't work when tabbingIdentifier is set after window creation.
            if let existingWindow = NSApp.windows.first(where: {
                $0 !== window && isMainWindow($0) && $0.isVisible
                    && $0.tabbingIdentifier == resolvedIdentifier
            }) {
                let targetWindow = existingWindow.tabbedWindows?.last ?? existingWindow
                targetWindow.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
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
                openWelcomeWindow()
            }
        }
    }

    @objc func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              isHandlingFileOpen else { return }

        if isWelcomeWindow(window),
           window.occlusionState.contains(.visible),
           NSApp.windows.contains(where: { isMainWindow($0) && $0.isVisible }),
           window.isVisible {
            window.close()
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

        isAutoReconnecting = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            WindowOpener.shared.pendingConnectionId = connection.id
            NotificationCenter.default.post(name: .openMainWindow, object: connection.id)

            defer { self.isAutoReconnecting = false }
            do {
                try await DatabaseManager.shared.connectToSession(connection)

                for window in NSApp.windows where self.isWelcomeWindow(window) {
                    window.close()
                }
            } catch is CancellationError {
                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }
                self.openWelcomeWindow()
            } catch {
                windowLogger.error("Auto-reconnect failed for '\(connection.name)': \(error.localizedDescription)")

                for window in NSApp.windows where self.isMainWindow(window) {
                    window.close()
                }

                self.openWelcomeWindow()
            }
        }
    }

    func closeRestoredMainWindows() {
        DispatchQueue.main.async { [weak self] in
            for window in NSApp.windows where self?.isMainWindow(window) == true {
                window.close()
            }
        }
    }
}
