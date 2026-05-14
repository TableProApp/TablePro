//
//  ConnectionWindowController.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

@MainActor
private final class ConnectionWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if let coordinator = MainContentCoordinator.coordinator(forWindow: self),
           let actions = coordinator.commandActions {
            actions.closeTab()
        } else {
            super.performClose(sender)
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        guard let coordinator = MainContentCoordinator.coordinator(forWindow: self),
              let actions = coordinator.commandActions else {
            super.newWindowForTab(sender)
            return
        }
        actions.newTab()
    }
}

@MainActor
internal final class ConnectionWindowController: NSWindowController, NSWindowDelegate {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let frameAutosaveName: NSWindow.FrameAutosaveName = "MainEditorWindow"

    internal let connection: DatabaseConnection
    internal let controllerId: UUID
    internal let coordinator: MainContentCoordinator

    private let sessionState: SessionStateFactory.SessionState
    private var activity: NSUserActivity?

    internal init(connection: DatabaseConnection, sessionState: SessionStateFactory.SessionState) {
        self.connection = connection
        self.controllerId = UUID()
        self.sessionState = sessionState
        self.coordinator = sessionState.coordinator

        let window = ConnectionWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.minSize = NSSize(width: 720, height: 480)
        window.isRestorable = AppSettingsStorage.shared.loadGeneral().startupBehavior == .reopenLast
        window.restorationClass = ConnectionWindowRestoration.self
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.tabbingMode = .automatic
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])

        let splitVC = MainSplitViewController(connection: connection, sessionState: sessionState)
        window.contentViewController = splitVC

        window.title = connection.name

        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.delegate = self

        refreshWindowTitle()

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            let visibleSize = (window.screen ?? NSScreen.main)?.visibleFrame.size
                ?? NSSize(width: 1_440, height: 900)
            window.setContentSize(NSSize(
                width: min(1_200, visibleSize.width),
                height: min(800, visibleSize.height)
            ))
            window.center()
        }

        Self.lifecycleLogger.info(
            "[open] ConnectionWindowController.init connId=\(connection.id, privacy: .public) controllerId=\(self.controllerId, privacy: .public)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionWindowController does not support NSCoder init")
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(connection.id.uuidString as NSString, forKey: ConnectionWindowRestoration.connectionIdKey)
    }

    // MARK: - NSWindowDelegate

    internal func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard !window.inLiveResize else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    internal func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    internal func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
    }

    internal func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.installToolbar(coordinator: coordinator)
        }
        CommandActionsRegistry.shared.current = coordinator.commandActions
        updateUserActivity()
        refreshWindowTitle()
        coordinator.handleWindowDidBecomeKey()
    }

    internal func windowDidResignKey(_ notification: Notification) {
        if let actions = coordinator.commandActions,
           CommandActionsRegistry.shared.current === actions {
            CommandActionsRegistry.shared.current = nil
        }
        activity?.resignCurrent()
        coordinator.handleWindowDidResignKey()
    }

    internal func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.lifecycleLogger.info(
            "[close] ConnectionWindowController.windowWillClose controllerId=\(self.controllerId, privacy: .public)"
        )

        cancelPendingConnectionIfNeeded()
        window.saveFrame(usingName: Self.frameAutosaveName)

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.invalidateToolbar()
        }

        coordinator.handleWindowWillClose()
        if let actions = coordinator.commandActions,
           CommandActionsRegistry.shared.current === actions {
            CommandActionsRegistry.shared.current = nil
        }
        activity?.invalidate()
        activity = nil
    }

    private func cancelPendingConnectionIfNeeded() {
        let connectionId = connection.id
        let session = DatabaseManager.shared.activeSessions[connectionId]
        guard session?.driver == nil else { return }
        Task {
            await DatabaseManager.shared.cancelEnsureConnected(connectionId)
        }
    }

    // MARK: - Window Title

    /// Single source of truth for the window title, proxy icon, and dirty dot.
    /// Resolved from the selected tab. Called on `windowDidBecomeKey`, once
    /// after the window is created, and from `MainContentView` when the
    /// selected tab changes.
    internal func refreshWindowTitle() {
        guard let window else { return }
        let selectedTab = coordinator.tabManager.selectedTab

        let title: String
        switch selectedTab?.tabType {
        case .serverDashboard:
            title = String(localized: "Server Dashboard")
        case .createTable:
            title = String(localized: "Create Table")
        case .erDiagram:
            title = String(localized: "ER Diagram")
        case .terminal:
            title = String(localized: "Terminal")
        case .table:
            title = selectedTab?.tableContext.tableName
                ?? selectedTab?.title
                ?? connection.name
        default:
            if let fileURL = selectedTab?.content.sourceFileURL {
                title = selectedTab?.title ?? fileURL.deletingPathExtension().lastPathComponent
            } else if let selectedTab {
                title = selectedTab.title
            } else {
                title = connection.name
            }
        }

        window.title = title
        window.representedURL = selectedTab?.content.sourceFileURL
        window.isDocumentEdited = selectedTab?.content.isFileDirty ?? false
    }

    // MARK: - NSUserActivity

    /// Refresh the Handoff activity from the current tab. Called on
    /// `windowDidBecomeKey` and from `MainContentView` when the selected tab
    /// changes. The key-window guard prevents a background window's tab switch
    /// from overwriting the foreground window's activity.
    internal func refreshUserActivity() {
        guard let window, window.isKeyWindow else { return }
        updateUserActivity()
    }

    private func updateUserActivity() {
        let selectedTab = coordinator.tabManager.selectedTab
        let tableName: String? = (selectedTab?.tabType == .table) ? selectedTab?.tableContext.tableName : nil
        let activityType = tableName != nil ? "com.TablePro.viewTable" : "com.TablePro.viewConnection"

        if activity?.activityType != activityType {
            activity?.invalidate()
            let newActivity = NSUserActivity(activityType: activityType)
            newActivity.isEligibleForHandoff = true
            activity = newActivity
        }

        guard let activity else { return }
        activity.title = tableName ?? connection.name
        var info: [String: Any] = ["connectionId": connection.id.uuidString]
        if let tableName {
            info["tableName"] = tableName
        }
        activity.userInfo = info
        activity.becomeCurrent()
    }
}
