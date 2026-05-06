//
//  TabWindowController.swift
//  TablePro
//
//  NSWindowController for an editor-tab-window. Hosts a SwiftUI
//  `MainEditorRootView` (NavigationSplitView + .inspector) inside a single
//  NSHostingController, replacing the previous NSSplitViewController + 3
//  separate NSHostingControllers (sidebar, detail, inspector).
//

import AppKit
import os
import SwiftUI

/// NSWindow subclass that routes Cmd+W (performClose:) through the coordinator's
/// closeTab() instead of AppKit's default close. This ensures the last tab clears
/// to the empty "No tabs open" state instead of closing the entire window.
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
}

@MainActor
internal final class TabWindowController: NSWindowController, NSWindowDelegate {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    private lazy var dataGridFieldEditor: DataGridFieldEditor = {
        let editor = DataGridFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    internal let payload: EditorTabPayload
    internal let controllerId: UUID

    /// Owns the SwiftUI scene's session state. Lives as long as the window.
    private let windowState: MainEditorWindowState

    /// NSToolbar owner. Installed once per window when a coordinator becomes
    /// available, invalidated on window close.
    private var toolbarOwner: MainWindowToolbar?

    /// Observes `windowState.sessionState` so the toolbar can be installed
    /// when a connection completes after window opening (e.g. cold launch
    /// reconnect).
    private var sessionObservationTask: Task<Void, Never>?

    private var activity: NSUserActivity?

    internal init(payload: EditorTabPayload, sessionState: SessionStateFactory.SessionState? = nil) {
        self.payload = payload
        self.controllerId = UUID()
        self.windowState = MainEditorWindowState(payload: payload, sessionState: sessionState)

        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.minSize = NSSize(width: 720, height: 480)
        window.isRestorable = false
        window.applyAutosaveName("MainEditorWindow")
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.tabbingMode = .preferred
        window.tabbingIdentifier = WindowManager.tabbingIdentifier(for: payload.connectionId)
        window.collectionBehavior.insert([.fullScreenPrimary, .managed])

        let hosting = NSHostingController(rootView: MainEditorRootView(windowState: self.windowState))
        window.contentViewController = hosting

        super.init(window: window)

        window.isReleasedWhenClosed = false
        window.delegate = self

        windowState.attachWindow(window)
        windowState.wireCoordinatorIfNeeded()

        applyDefaultWindowSizeIfNeeded(window)
        installToolbarIfPossible()
        startSessionObservation()

        Self.lifecycleLogger.info(
            "[open] TabWindowController.init payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) controllerId=\(self.controllerId, privacy: .public) eagerToolbar=\(sessionState != nil)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabWindowController does not support NSCoder init")
    }

    // MARK: - Window Sizing

    /// Enforce a 1200x800 minimum content size when the autosaved frame is
    /// smaller. Mirrors the previous `MainSplitViewController.viewWillAppear`
    /// behavior so connection windows don't open at a tiny restored size.
    private func applyDefaultWindowSizeIfNeeded(_ window: NSWindow) {
        let defaultSize = NSSize(width: 1_200, height: 800)
        if window.frame.width < defaultSize.width || window.frame.height < defaultSize.height {
            window.setContentSize(NSSize(
                width: max(window.frame.width, defaultSize.width),
                height: max(window.frame.height, defaultSize.height)
            ))
            window.center()
        }
    }

    // MARK: - Toolbar

    /// Install the NSToolbar when a coordinator is available. Idempotent.
    /// Replaces the old `MainSplitViewController.installToolbar`.
    private func installToolbarIfPossible() {
        guard let window, let coordinator = windowState.sessionState?.coordinator else { return }
        if toolbarOwner == nil {
            toolbarOwner = MainWindowToolbar(coordinator: coordinator)
        }
        if let owner = toolbarOwner, window.toolbar !== owner.managedToolbar {
            window.toolbar = owner.managedToolbar
        }
    }

    /// Watch `windowState.sessionState` for the case where the connection
    /// completes after the window has opened (cold launch + reconnect, dock
    /// menu open). Installs the toolbar once the coordinator is available.
    private func startSessionObservation() {
        sessionObservationTask?.cancel()
        let state = windowState
        sessionObservationTask = Task { [weak self] in
            while !Task.isCancelled {
                let hasCoordinator = state.sessionState?.coordinator != nil
                if hasCoordinator {
                    self?.installToolbarIfPossible()
                }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = state.sessionState?.coordinator
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
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
        installToolbarIfPossible()
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

        toolbarOwner?.invalidate()
        toolbarOwner = nil
        sessionObservationTask?.cancel()
        sessionObservationTask = nil

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
        activity.becomeCurrent()
    }
}
