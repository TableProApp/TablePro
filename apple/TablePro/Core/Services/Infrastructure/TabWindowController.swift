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
private final class EditorWindow: ContentWindow, NSDraggingDestination {
    /// A window that draws its own tabs says so by redefining the close command, which is the
    /// mechanism AppKit gives native tabbed windows for free. The editor's meaning of Close lives
    /// in one place behind it, so the menu, the keyboard and any other sender cannot disagree.
    override func performClose(_ sender: Any?) {
        let editor = contentViewController as? MainSplitViewController
        guard editor?.closeFrontmostTab() != true else { return }
        super.performClose(sender)
    }

    /// The window's first focus belongs to the tab it shows. AppKit reads `initialFirstResponder`
    /// once, as the window is first placed on screen, so it is named as soon as the content that
    /// owns the answer is installed.
    override var contentViewController: NSViewController? {
        didSet {
            initialFirstResponder = (contentViewController as? MainSplitViewController)?
                .initialFirstResponderContainer
        }
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

    @MainActor
    internal static var frameAutosaveName: NSWindow.FrameAutosaveName? {
        SplitViewAutosaveName.current("MainEditorWindow")
    }

    internal let payload: EditorTabPayload

    internal let controllerId: UUID

    private var activity: NSUserActivity?

    private let windowBackdrop: ThemeWindowBackdrop
    private let updateIndicator: UpdateIndicatorAccessory

    // Set while a close question is open: its sheet attaches a moment after the click, and a second click would ask twice.
    private(set) var pendingCloseAnswer: Task<Void, Never>?

    // Vars so a test can script them instead of showing the alert.
    var runningWork: (RunningWorkScope) -> [RunningWork] = { RunningWorkRegistry.shared.items(in: $0) }
    var confirmStoppingWork: (RunningWorkPrompt, NSWindow?) async -> Bool = { prompt, window in
        await RunningWorkApproval.confirm(prompt, window: window)
    }

    /// `adopting` carries a connection that is moving here from another window, whole. Everything
    /// the user has in it lives on that object, so the window takes it rather than building a
    /// second one around the same connection.
    ///
    /// `pinnedWindowSize` is the screenshot size, passed in so a test can build the real window at
    /// one without the UI test sandbox.
    internal init(
        payload: EditorTabPayload,
        sessionState: SessionStateFactory.SessionState? = nil,
        autoConnect: Bool = false,
        pinnedWindowSize: CGSize? = ScreenshotEnvironment.windowSize,
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
        window.representedURL = splitVC.windowRepresentedURL
        splitVC.installTabStripAccessory(on: window)
        windowBackdrop = ThemeWindowBackdrop(window: window)
        updateIndicator = UpdateIndicatorAccessory(window: window)

        super.init(window: window)

        window.isReleasedWhenClosed = false
        Self.placeInitialFrame(of: window, pinnedSize: pinnedWindowSize)
        window.delegate = self

        Self.lifecycleLogger.info(
            "[open] TabWindowController.init payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) controllerId=\(self.controllerId, privacy: .public) eagerToolbar=\(sessionState != nil)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabWindowController does not support NSCoder init")
    }

    /// Every frame the window starts with is settled here, before it is shown or laid out. A resize
    /// issued from inside the window's own layout pass lands under `_layoutSubtreeWithOldSize:`,
    /// which has already captured the old size and resizes the content view by the difference a
    /// second time. Measured on macOS 27 with a 1200x800 window pinned to 1512x861 from a SwiftUI
    /// `viewDidMoveToWindow`, which is where the screenshot pin used to run: the split view came out
    /// 1824x922 at y -61, so the sidebar's top row sat under the titlebar and the inspector divider
    /// stood 312pt past the window's edge, taking the toolbar's trailing items into the overflow
    /// menu. Activating the window afterwards did not repair it.
    ///
    /// Placed before the controller becomes the window's delegate, so the starting frame is not
    /// filed under `frameAutosaveName` as if the user had chosen it. A pinned size is not theirs.
    /// The frame is still saved on close.
    private static func placeInitialFrame(of window: NSWindow, pinnedSize: CGSize?) {
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        if let pinnedSize {
            let pinned = visibleFrame.map { ScreenshotEnvironment.pinnedFrame(size: pinnedSize, in: $0) }
                ?? NSRect(origin: window.frame.origin, size: pinnedSize)
            window.setFrame(pinned, display: false)
            return
        }
        guard !window.setFrame(usingAutosaveName: frameAutosaveName) else { return }
        let visibleSize = visibleFrame?.size ?? NSSize(width: 1_440, height: 900)
        window.setContentSize(NSSize(
            width: min(1_200, visibleSize.width),
            height: min(800, visibleSize.height)
        ))
        window.center()
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
        window.keepsKeyViewLoopCurrent()
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        // A toolbar and content of one color get a half-width rule separating nothing. From macOS 26
        // only the transparent titlebar removes it; this property no longer reaches it there.
        window.titlebarSeparatorStyle = .none
        /// `.automatic` is AppKit reading the user's own tabbing preference. Hard-coding
        /// `.preferred` overrode that setting, which an app that draws its own editor tabs has no
        /// reason to do.
        window.tabbingMode = .automatic
        window.tabbingIdentifier = WindowManager.mainTabbingIdentifier
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])
        return window
    }

    // MARK: - NSWindowDelegate

    internal func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard !window.inLiveResize else { return }
        window.saveFrame(usingAutosaveName: Self.frameAutosaveName)
    }

    internal func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.saveFrame(usingAutosaveName: Self.frameAutosaveName)
    }

    internal func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.saveFrame(usingAutosaveName: Self.frameAutosaveName)
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
            splitVC.syncFrontmostTabManager()
            // The recovery list records the connection the front window shows.
            SessionRecoveryTracker.sync()
        }

        guard let coordinator = MainContentCoordinator.coordinator(forWindow: window) else { return }
        Self.lifecycleLogger.debug(
            "[switch] windowDidBecomeKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public) connId=\(coordinator.connectionId, privacy: .public)"
        )
        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.pointToolbar(at: coordinator)
        }
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) installToolbar ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        updateUserActivity(coordinator: coordinator)
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) userActivity ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        coordinator.handleWindowDidBecomeKey()
        Self.lifecycleLogger.debug("[switch] windowDidBecomeKey seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    // Every undo domain registering on the window lands in the selected connection's history for the mode on screen.
    internal func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let host = window.contentViewController as? MainSplitViewController else { return nil }
        return host.workspaces.selected?.activeUndoManager
    }

    internal func windowDidResignKey(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow else { return }

        // Closing or backgrounding this window leaves its yield on a menu it no longer
        // owns, and the window taking over may not be one of ours.
        MainMenuBuilder.syncKeyEquivalents()
        (window.contentViewController as? MainSplitViewController)?.syncFrontmostTabManager()

        guard let coordinator = MainContentCoordinator.coordinator(forWindow: window) else { return }
        Self.lifecycleLogger.debug(
            "[switch] windowDidResignKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public)"
        )
        activity?.resignCurrent()
        coordinator.handleWindowDidResignKey()
        Self.lifecycleLogger.debug("[switch] windowDidResignKey seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    // The close button reaches here without performClose:, and Option-click sends its action to every window.
    // close() skips this, so the close the answer ends in does not ask again.
    internal func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard pendingCloseAnswer == nil else { return false }
        guard let host = sender.contentViewController as? MainSplitViewController else { return true }
        guard let actions = host.closeQuestionActions else { return asksToStopWork(in: host, closing: sender) }
        guard actions.holdsWorkOnWindowClose() else { return true }
        let answer: Task<Void, Never>
        if let event = NSApp.currentEvent, WindowCloseReview.closesEveryWindow(event) {
            answer = WindowCloseReview.shared.enlist(actions, window: sender, for: event)
        } else {
            answer = Task { _ = await actions.closeWindowAwaiting(asBatchSurvivor: false) }
        }
        pendingCloseAnswer = Task { [weak self] in
            await answer.value
            self?.pendingCloseAnswer = nil
        }
        return false
    }

    // No browse content has mounted (Agent mode while still connecting), so nothing is unsaved, yet an agent reply can run.
    private func asksToStopWork(in host: MainSplitViewController, closing window: NSWindow) -> Bool {
        let work = runningWork(.window(ids: [], connectionIds: Set(host.workspaces.connectionIds)))
        guard let prompt = RunningWorkPrompt.make(action: .close, work: work) else { return true }
        let confirm = confirmStoppingWork
        pendingCloseAnswer = Task { [weak self, weak window] in
            if await confirm(prompt, window) {
                for item in work { item.cancel() }
                window?.close()
            }
            self?.pendingCloseAnswer = nil
        }
        return false
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

        window.saveFrame(usingAutosaveName: Self.frameAutosaveName)

        if let splitVC = window.contentViewController as? MainSplitViewController {
            splitVC.invalidateToolbar()
        }

        // Every hosted connection saves and tears down, not only the one a window lookup answers.
        if let splitVC = window.contentViewController as? MainSplitViewController {
            let closing = splitVC.workspaces.workspaces
            for workspace in closing {
                workspace.sessionState?.coordinator.handleWindowWillClose()
                if workspace.sessionState == nil {
                    MainContentCoordinator.endTabSessionIfUnhosted(for: workspace.connectionId, closing: workspace)
                }
            }
            // Next turn, once close() has ordered the window out: emptying a pane on screen shows a blank frame.
            Task { @MainActor in
                Self.releaseWorkspaces(closing)
            }
        }
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) handleWindowWillClose ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
        activity?.invalidate()
        activity = nil
        Self.lifecycleLogger.info("[close] windowWillClose seq=\(seq) total ms=\(Int(Date().timeIntervalSince(t0) * 1_000))")
    }

    // The panes retain the SwiftUI trees, which retain the window and the coordinator. A workspace
    // another window hosts by now keeps its panes.
    internal static func releaseWorkspaces(
        _ closing: [ConnectionWorkspace],
        hosted: (UUID) -> [ConnectionWorkspace] = { WindowManager.shared.workspaces(for: $0) }
    ) {
        for workspace in closing where !hosted(workspace.connectionId).contains(where: { $0 === workspace }) {
            workspace.teardown()
        }
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
