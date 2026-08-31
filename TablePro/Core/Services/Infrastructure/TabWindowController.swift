//
//  TabWindowController.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

/// The conformance is what makes the drag methods reachable. `NSWindow` does not adopt
/// `NSDraggingDestination`, so without it Swift emits no selector for these and AppKit, which
/// dispatches a drag by selector, runs `NSWindow`'s own refusal instead.
@MainActor
private final class EditorWindow: NSWindow, NSDraggingDestination {
    /// A window that draws its own tabs says so by redefining the close command, which is the
    /// mechanism AppKit gives native tabbed windows for free. The editor's meaning of Close lives
    /// in one place behind it, so the menu, the keyboard and any other sender cannot disagree.
    override func performClose(_ sender: Any?) {
        let editor = contentViewController as? MainSplitViewController
        guard editor?.closeFrontmostTab() != true else { return }
        super.performClose(sender)
    }

    /// Hiding the toolbar is what drops the content pane's top safe area, so the titlebar has to be
    /// reconsidered every time the user sends this from View > Show Toolbar.
    override func toggleToolbarShown(_ sender: Any?) {
        super.toggleToolbarShown(sender)
        TabWindowController.applyTitlebarChrome(to: self)
    }

    /// Deciding what a drag carries reads the head of each file, and `draggingUpdated:` fires on
    /// every pointer move. A drag session's pasteboard cannot change while it is in flight.
    private var dragSessionOperation: NSDragOperation?

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation: NSDragOperation =
            FileDropDestination.acceptedURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
        dragSessionOperation = operation
        return operation
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragSessionOperation ?? draggingEntered(sender)
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragSessionOperation = nil
    }

    func draggingEnded(_ sender: any NSDraggingInfo) {
        dragSessionOperation = nil
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = FileDropDestination.acceptedURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        FileDropDestination.open(urls)
        return true
    }
}

extension EditorWindow: CloseCommandNaming {
    var closeCommandTitle: String? {
        (contentViewController as? MainSplitViewController)?.closeCommandTitle
    }
}

@MainActor
internal final class TabWindowController: NSWindowController, NSWindowDelegate {
    nonisolated private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let frameAutosaveName: NSWindow.FrameAutosaveName = "MainEditorWindow"

    internal let payload: EditorTabPayload

    internal let controllerId: UUID

    private var activity: NSUserActivity?

    /// `adopting` carries a connection that is moving here from another window, whole. Everything
    /// the user has in it lives on that object, so the window takes it rather than building a
    /// second one around the same connection.
    internal init(
        payload: EditorTabPayload,
        sessionState: SessionStateFactory.SessionState? = nil,
        autoConnect: Bool = false,
        adopting workspace: ConnectionWorkspace? = nil
    ) {
        self.payload = payload
        self.controllerId = UUID()

        let window = Self.makeEditorWindow()

        let splitVC = MainSplitViewController(
            payload: payload,
            sessionState: sessionState,
            autoConnect: autoConnect,
            adopting: workspace
        )
        window.contentViewController = splitVC
        FileDropDestination.register(on: window)
        window.title = splitVC.windowTitle
        window.subtitle = splitVC.windowSubtitle
        splitVC.installTabStripAccessory(on: window)

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

    /// The one place an editor window's chrome is configured, so a test can hold the whole shape.
    internal static func makeEditorWindow() -> NSWindow {
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
        window.titleVisibility = .visible
        applyTitlebarChrome(to: window)
        /// `.automatic` is AppKit reading the user's own tabbing preference. Hard-coding
        /// `.preferred` overrode that setting, which an app that draws its own editor tabs has no
        /// reason to do.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = WindowManager.mainTabbingIdentifier
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])
        return window
    }

    /// AppKit rules a line between the toolbar and the content pane, and stops it at the sidebar
    /// divider, so a window whose toolbar and content are the same colour gets a half-width rule
    /// separating nothing. `titlebarSeparatorStyle` is the property for that, and it stopped
    /// reaching the rule in macOS 26: the content section's titlebar background now draws it
    /// through a scroll pocket, and `.none`, `.line` and `.shadow` all render identically there.
    ///
    /// `isFullScreen` is passed in for the transition hooks, which run either side of the style
    /// mask changing rather than at the moment it does.
    internal static func applyTitlebarChrome(to window: NSWindow, isFullScreen: Bool? = nil) {
        window.titlebarSeparatorStyle = .none
        guard #available(macOS 26.0, *) else { return }
        window.titlebarAppearsTransparent = titlebarIsTransparent(
            isFullScreen: isFullScreen ?? window.styleMask.contains(.fullScreen),
            toolbarVisible: window.toolbar?.isVisible ?? false
        )
    }

    /// A transparent titlebar is what removes that rule, and it is free while the content pane is
    /// inset below the titlebar, which it is in every state but one. A full-screen window with its
    /// toolbar hidden has a top safe area of zero, so its content owns the whole screen, and the
    /// titlebar AppKit slides back down over that content needs a background of its own to stay
    /// legible. Nothing is lost by making it opaque there, because a titlebar that only appears on
    /// demand has no rule to suppress.
    internal static func titlebarIsTransparent(isFullScreen: Bool, toolbarVisible: Bool) -> Bool {
        isFullScreen ? toolbarVisible : true
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

    /// Both hooks name the state they are moving to, because neither runs at the moment the style
    /// mask flips: `willEnter` still reads windowed, and `didExit` is the first point that reads
    /// windowed again.
    internal func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.applyTitlebarChrome(to: window, isFullScreen: true)
    }

    internal func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        Self.applyTitlebarChrome(to: window, isFullScreen: false)
    }

    internal func windowDidBecomeKey(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow else { return }

        // Key equivalents are global while the text-focus yield that removes them is
        // per-window, so the window coming forward has to re-state the menu it
        // inherits. Without this, a yield another window installed never lifts.
        MainMenuBuilder.syncKeyEquivalents()

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.startActivationConnectIfNeeded()
        }

        guard let coordinator = MainContentCoordinator.coordinator(forWindow: window) else { return }
        Self.lifecycleLogger.debug(
            "[switch] windowDidBecomeKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public) connId=\(coordinator.connectionId, privacy: .public)"
        )
        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.installToolbar(coordinator: coordinator)
        }
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) installToolbar ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        updateUserActivity(coordinator: coordinator)
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) userActivity ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        coordinator.handleWindowDidBecomeKey()
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    /// `NSWindow.undoManager` resolves through here, so every undo domain that registers on the
    /// window (the data grid's change manager, and the query editor's text view) lands in the
    /// selected connection's own history. One window hosts every connection now, so sharing the
    /// window's manager let Cmd+Z in one connection roll back an edit made in another.
    internal func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let host = window.contentViewController as? MainSplitViewController else { return nil }
        return host.workspaces.selected?.undoManager
    }

    internal func windowDidResignKey(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow else { return }

        // Closing or backgrounding this window leaves its yield on a menu it no longer
        // owns, and the window taking over may not be one of ours.
        MainMenuBuilder.syncKeyEquivalents()

        guard let coordinator = MainContentCoordinator.coordinator(forWindow: window) else { return }
        Self.lifecycleLogger.debug(
            "[switch] windowDidResignKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public)"
        )
        activity?.resignCurrent()
        coordinator.handleWindowDidResignKey()
        Self.lifecycleLogger.debug("[switch] windowDidResignKey seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    internal func windowWillClose(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow else { return }
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) controllerId=\(self.controllerId, privacy: .public)")

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.markWindowClosing()
        }

        cancelPendingConnectionIfNeeded()

        window.saveFrame(usingName: Self.frameAutosaveName)

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.invalidateToolbar()
        }

        /// Every connection the window hosts closes with it, so each one saves and tears down.
        /// Resolving a single coordinator from the window persisted whichever one happened to
        /// answer and lost the rest since their last periodic save.
        if let splitVC = window.contentViewController as? MainSplitViewController {
            for workspace in splitVC.workspaces.workspaces {
                workspace.sessionState?.coordinator.handleWindowWillClose()
            }
        }
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) handleWindowWillClose ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        activity?.invalidate()
        activity = nil
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    /// Every connection the window hosts, not just the one it was opened for: a connect still
    /// dialing in a background workspace has to be called off too, or it completes into a window
    /// that no longer exists.
    private func cancelPendingConnectionIfNeeded() {
        guard let splitVC = window?.contentViewController as? MainSplitViewController else { return }
        for connectionId in splitVC.workspaces.connectionIds {
            let session = DatabaseManager.shared.activeSessions[connectionId]
            guard session?.driver == nil else { continue }
            DatabaseManager.shared.invalidateConnectionAttempt(connectionId)
            Task {
                await DatabaseManager.shared.cancelEnsureConnected(connectionId)
                guard !WindowManager.shared.hasOpenWindow(for: connectionId) else { return }
                guard DatabaseManager.shared.activeSessions[connectionId]?.driver != nil else { return }
                await DatabaseManager.shared.disconnectSession(connectionId)
            }
        }
        SessionRecoveryTracker.sync()
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
