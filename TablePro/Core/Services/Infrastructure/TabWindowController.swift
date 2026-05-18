//
//  TabWindowController.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

private let issue1313Logger = Logger(subsystem: "com.TablePro", category: "Issue1313")

@MainActor
private final class EditorWindow: NSWindow {
    override func performClose(_ sender: Any?) {
        if let coordinator = MainContentCoordinator.coordinator(forWindow: self),
           let actions = coordinator.commandActions {
            actions.closeTab()
        } else {
            super.performClose(sender)
        }
    }

    override func newWindowForTab(_ sender: Any?) {
        let winId = ObjectIdentifier(self).hashValue
        let resolvedCoordinator = MainContentCoordinator.coordinator(forWindow: self)
        let tabsCount = resolvedCoordinator?.tabManager.tabs.count ?? -1
        let selectedTabId = resolvedCoordinator?.tabManager.selectedTabId?.uuidString ?? "nil"
        let selectedIsPreview = resolvedCoordinator?.tabManager.selectedTab?.isPreview ?? false
        issue1313Logger.info(
            "[1313] EditorWindow.newWindowForTab fired winId=\(winId) isKey=\(self.isKeyWindow) tabsInCoord=\(tabsCount) selectedTabId=\(selectedTabId, privacy: .public) selectedIsPreview=\(selectedIsPreview)"
        )
        guard let coordinator = resolvedCoordinator,
              let actions = coordinator.commandActions else {
            issue1313Logger.info("[1313] newWindowForTab fallback to super (no coordinator/actions) winId=\(winId)")
            super.newWindowForTab(sender)
            return
        }
        actions.newTab()
    }
}

@MainActor
internal final class TabWindowController: NSWindowController, NSWindowDelegate {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let frameAutosaveName: NSWindow.FrameAutosaveName = "MainEditorWindow"

    internal let payload: EditorTabPayload

    internal let controllerId: UUID

    private var activity: NSUserActivity?

    internal init(payload: EditorTabPayload, sessionState: SessionStateFactory.SessionState? = nil) {
        self.payload = payload
        self.controllerId = UUID()

        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.minSize = NSSize(width: 720, height: 480)
        window.isRestorable = AppSettingsStorage.shared.loadGeneral().startupBehavior == .reopenLast
        window.restorationClass = TabWindowRestoration.self
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.tabbingIdentifier = WindowManager.tabbingIdentifier(for: payload.connectionId)
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])

        let splitVC = MainSplitViewController(payload: payload, sessionState: sessionState)
        window.contentViewController = splitVC

        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.delegate = self

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
            "[open] TabWindowController.init payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) controllerId=\(self.controllerId, privacy: .public) eagerToolbar=\(sessionState != nil)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabWindowController does not support NSCoder init")
    }

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        coder.encode(payload.connectionId.uuidString as NSString, forKey: TabWindowRestoration.connectionIdKey)
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
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow,
              let coordinator = MainContentCoordinator.coordinator(forWindow: window)
        else { return }
        let winId = ObjectIdentifier(window).hashValue
        let groupSelectedId = window.tabGroup?.selectedWindow.map { ObjectIdentifier($0).hashValue } ?? 0
        issue1313Logger.info(
            "[1313] windowDidBecomeKey seq=\(seq) winId=\(winId) controllerId=\(self.controllerId, privacy: .public) tabbedCount=\(window.tabbedWindows?.count ?? -1) tabGroupSelectedWinId=\(groupSelectedId)"
        )
        Self.lifecycleLogger.debug(
            "[switch] windowDidBecomeKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public) connId=\(coordinator.connectionId, privacy: .public)"
        )
        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.installToolbar(coordinator: coordinator)
        }
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) installToolbar ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        CommandActionsRegistry.shared.current = coordinator.commandActions
        updateUserActivity(coordinator: coordinator)
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) userActivity ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        coordinator.handleWindowDidBecomeKey()
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    internal func windowDidResignKey(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow,
              let coordinator = MainContentCoordinator.coordinator(forWindow: window)
        else { return }
        let winId = ObjectIdentifier(window).hashValue
        let groupSelectedId = window.tabGroup?.selectedWindow.map { ObjectIdentifier($0).hashValue } ?? 0
        issue1313Logger.info(
            "[1313] windowDidResignKey seq=\(seq) winId=\(winId) controllerId=\(self.controllerId, privacy: .public) tabGroupSelectedWinId=\(groupSelectedId)"
        )
        Self.lifecycleLogger.debug(
            "[switch] windowDidResignKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public)"
        )
        if let actions = coordinator.commandActions,
           CommandActionsRegistry.shared.current === actions {
            CommandActionsRegistry.shared.current = nil
        }
        activity?.resignCurrent()
        coordinator.handleWindowDidResignKey()
        Self.lifecycleLogger.debug("[switch] windowDidResignKey seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    internal func windowWillClose(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow else { return }
        issue1313Logger.info(
            "[1313] windowWillClose seq=\(seq) winId=\(ObjectIdentifier(window).hashValue) controllerId=\(self.controllerId, privacy: .public)"
        )
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) controllerId=\(self.controllerId, privacy: .public)")

        cancelPendingConnectionIfNeeded()

        window.saveFrame(usingName: Self.frameAutosaveName)

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.invalidateToolbar()
        }

        let coordinator = MainContentCoordinator.coordinator(forWindow: window)
        coordinator?.handleWindowWillClose()
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) handleWindowWillClose ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        if let actions = coordinator?.commandActions,
           CommandActionsRegistry.shared.current === actions {
            CommandActionsRegistry.shared.current = nil
        }
        activity?.invalidate()
        activity = nil
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    private func cancelPendingConnectionIfNeeded() {
        let connectionId = payload.connectionId
        let session = DatabaseManager.shared.activeSessions[connectionId]
        guard session?.driver == nil else { return }
        Task {
            await DatabaseManager.shared.cancelEnsureConnected(connectionId)
        }
    }

    // MARK: - NSUserActivity

    internal func refreshUserActivity() {
        guard let window, window.isKeyWindow,
              let coordinator = MainContentCoordinator.coordinator(forWindow: window)
        else { return }
        updateUserActivity(coordinator: coordinator)
    }

    private func updateUserActivity(coordinator: MainContentCoordinator) {
        let connection = coordinator.connection
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

        // becomeCurrent is unconditional. A previous becomeCurrent: Bool gate
        // dropped Continuity mid-session whenever the user switched between
        // table and query tabs in the same window, because the activity-type
        // flip above invalidates the old activity but never promotes its
        // replacement.
        activity.becomeCurrent()
    }
}
