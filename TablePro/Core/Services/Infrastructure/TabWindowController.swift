//
//  TabWindowController.swift
//  TablePro
//
//  NSWindowController for an editor-tab-window. Replaces the SwiftUI
//  `WindowGroup(id: "main", for: EditorTabPayload.self)` scene.
//
//  Phase 1 scope: window creation, NSHostingView installation, tabbing
//  configuration. Existing MainContentView lifecycle hooks (.onAppear,
//  .onDisappear, NSWindow notification observers, .userActivity) continue to
//  work unchanged — this controller's job in Phase 1 is limited to replacing
//  SwiftUI scene-driven window construction.
//
//  Phase 2 will migrate lifecycle responsibilities (markActivated, teardown,
//  userActivity, didBecomeKey/didResignKey) into NSWindowDelegate methods
//  on this controller.
//

import AppKit
import os
import SwiftUI

/// NSWindow subclass that routes the standard tab-related responder selectors
/// (`performClose:`, `newWindowForTab:`) through the coordinator. Menus and
/// toolbar buttons reach this via `NSApp.sendAction(_:to:nil:from:)`, the same
/// pattern AppKit uses for `selectNextTab:` and `selectPreviousTab:`.
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
        guard let coordinator = MainContentCoordinator.coordinator(forWindow: self),
              let actions = coordinator.commandActions else {
            super.newWindowForTab(sender)
            return
        }
        actions.newTab()
    }
}

@MainActor
internal final class TabWindowController: NSWindowController, NSWindowDelegate {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")
    private static let frameLogger = Logger(subsystem: "com.TablePro", category: "WindowFrame")

    internal static let frameAutosaveName: NSWindow.FrameAutosaveName = "MainEditorWindow"

    private static var frameDefaultsKey: String { "NSWindow Frame \(frameAutosaveName)" }

    internal static var hasSavedFrame: Bool {
        UserDefaults.standard.object(forKey: frameDefaultsKey) != nil
    }

    private static func currentSavedFrameString() -> String {
        UserDefaults.standard.string(forKey: frameDefaultsKey) ?? "<nil>"
    }

    private lazy var dataGridFieldEditor: DataGridFieldEditor = {
        let editor = DataGridFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    internal let payload: EditorTabPayload

    /// Stable identifier for this controller. Distinct from the
    /// `MainContentView.@State windowId` used inside WindowLifecycleMonitor —
    /// that one remains the authoritative per-view UUID in Phase 1. Phase 2
    /// will unify them on this controller's identifier.
    internal let controllerId: UUID

    /// NSUserActivity published while this window is key, so Handoff and
    /// other continuity flows can pick up the connection (and table, if
    /// viewing one). Replaces the SwiftUI `.userActivity(...)` modifier we
    /// removed in Phase 2 — `.userActivity` requires a Scene context and
    /// emitted `Cannot use Scene methods for URL, NSUserActivity...` warnings
    /// when used inside an `NSHostingView`.
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
        window.isRestorable = false
        window.toolbarStyle = .unified
        // Hide the window title ("Query 1 / TablePro") embedded in the unified
        // toolbar — otherwise it claims leading space and pushes our navigation
        // items to the right of it. Tab group's tab bar already shows the same
        // "Query N" label, so no information is lost. The Principal toolbar item
        // continues to show connection name + DB version.
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.tabbingIdentifier = WindowManager.tabbingIdentifier(for: payload.connectionId)
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])

        // NSSplitViewController as contentViewController so .toggleSidebar and
        // .sidebarTrackingSeparator find the split view via the responder chain.
        let splitVC = MainSplitViewController(payload: payload, sessionState: sessionState)
        window.contentViewController = splitVC

        super.init(window: window)

        Self.frameLogger.notice("[init] before-autosave persistedFrame=\(Self.currentSavedFrameString(), privacy: .public) windowFrame=\(NSStringFromRect(window.frame), privacy: .public)")

        self.windowFrameAutosaveName = Self.frameAutosaveName
        Self.frameLogger.notice("[init] after windowFrameAutosaveName setter windowAutosaveName=\(window.frameAutosaveName, privacy: .public) windowFrame=\(NSStringFromRect(window.frame), privacy: .public)")

        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        Self.frameLogger.notice("[init] explicit setFrameUsingName returned=\(restored, privacy: .public) windowFrame=\(NSStringFromRect(window.frame), privacy: .public)")

        installFrameAutosaveTrace(on: window)

        // Keep the controller alive after the window closes so NSWindowDelegate
        // hooks have time to run teardown. WindowManager drops its strong
        // reference on willClose, which triggers dealloc.
        window.isReleasedWhenClosed = false

        // Become the window's delegate so didBecomeKey/didResignKey/willClose
        // dispatch to methods on this controller — eliminates the global
        // NotificationCenter fan-out that previously ran every ContentView
        // instance's observer per focus change.
        window.delegate = self

        // Toolbar is installed by MainSplitViewController.viewWillAppear when
        // the session state is available. NSSplitViewController does not
        // overwrite window.toolbar (unlike NavigationSplitView), so no KVO
        // workaround is needed.

        Self.lifecycleLogger.info(
            "[open] TabWindowController.init payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) controllerId=\(self.controllerId, privacy: .public) eagerToolbar=\(sessionState != nil)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabWindowController does not support NSCoder init")
    }

    private var frameTraceObservers: [NSObjectProtocol] = []

    private func installFrameAutosaveTrace(on window: NSWindow) {
        let center = NotificationCenter.default

        frameTraceObservers.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            Self.frameLogger.notice("[event] didResize windowFrame=\(NSStringFromRect(window.frame), privacy: .public) inLiveResize=\(window.inLiveResize, privacy: .public) persistedFrame=\(Self.currentSavedFrameString(), privacy: .public)")
        })

        frameTraceObservers.append(center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            Self.frameLogger.notice("[event] didMove windowFrame=\(NSStringFromRect(window.frame), privacy: .public) persistedFrame=\(Self.currentSavedFrameString(), privacy: .public)")
        })

        frameTraceObservers.append(center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: window,
            queue: .main
        ) { [weak window] _ in
            guard let window else { return }
            Self.frameLogger.notice("[event] didEndLiveResize windowFrame=\(NSStringFromRect(window.frame), privacy: .public) persistedFrame=\(Self.currentSavedFrameString(), privacy: .public)")
        })
    }

    // MARK: - NSWindowDelegate

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is CellTextField else { return nil }
        return dataGridFieldEditor
    }

    internal func windowDidBecomeKey(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow,
              let coordinator = MainContentCoordinator.coordinator(forWindow: window)
        else { return }
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
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) controllerId=\(self.controllerId, privacy: .public)")

        Self.frameLogger.notice("[close] before saveFrame windowFrame=\(NSStringFromRect(window.frame), privacy: .public) styleMask.fullScreen=\(window.styleMask.contains(.fullScreen), privacy: .public) persistedFrame=\(Self.currentSavedFrameString(), privacy: .public)")
        window.saveFrame(usingName: Self.frameAutosaveName)
        Self.frameLogger.notice("[close] after saveFrame persistedFrame=\(Self.currentSavedFrameString(), privacy: .public)")

        for observer in frameTraceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        frameTraceObservers.removeAll()

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

    // MARK: - NSUserActivity

    /// Publish (or refresh) this window's NSUserActivity. Called by
    /// `windowDidBecomeKey` and by `MainContentView` when the selected tab
    /// changes — only the second case is a no-op when the window isn't key
    /// (Handoff only cares about the active activity).
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

        // Recreate when the activity type flips between viewConnection and
        // viewTable — NSUserActivity.activityType is immutable.
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

        // Always promote to current. Both call sites (`windowDidBecomeKey` and
        // `refreshUserActivity` which guards on `window.isKeyWindow`) only
        // invoke this method when the window owns Handoff. The previous
        // `becomeCurrent: Bool` parameter dropped Continuity mid-session
        // whenever the user switched between table and query tabs in the
        // same window — the type-flip branch above invalidated the old
        // activity but never promoted the replacement.
        activity.becomeCurrent()
    }
}
