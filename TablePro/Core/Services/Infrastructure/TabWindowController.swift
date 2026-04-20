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

    /// Payload identifying what content this window should display.
    internal let payload: EditorTabPayload

    /// Stable identifier for this controller. Distinct from the
    /// `MainContentView.@State windowId` used inside WindowLifecycleMonitor —
    /// that one remains the authoritative per-view UUID in Phase 1. Phase 2
    /// will unify them on this controller's identifier.
    internal let controllerId: UUID

    /// Owns the NSToolbar delegate. Created lazily once the coordinator is
    /// available (from MainContentView.onAppear → `installToolbar(coordinator:)`).
    /// Held strongly so the delegate doesn't dealloc while the toolbar is live.
    private var toolbarOwner: MainWindowToolbar?

    /// KVO observation that re-claims `window.toolbar` if anything (typically
    /// SwiftUI's `NavigationSplitView`, which installs its own toolbar during
    /// initial layout) replaces our managed toolbar. Without this, the user
    /// sees an empty toolbar from connect until the next `windowDidBecomeKey`.
    private var toolbarKVO: NSKeyValueObservation?

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

        // NSHostingView embeds SwiftUI as a plain NSView without scene semantics.
        // Unlike NSHostingController, it does not bridge scene methods (no
        // sceneBridgingOptions warnings) and does not force a synchronous
        // content-size measurement. Layout happens lazily after orderFront.
        let hosting = NSHostingView(rootView: ContentView(payload: payload))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting

        super.init(window: window)

        // Keep the controller alive after the window closes so NSWindowDelegate
        // hooks have time to run teardown. WindowManager drops its strong
        // reference on willClose, which triggers dealloc.
        window.isReleasedWhenClosed = false

        // Become the window's delegate so didBecomeKey/didResignKey/willClose
        // dispatch to methods on this controller — eliminates the global
        // NotificationCenter fan-out that previously ran every ContentView
        // instance's observer per focus change.
        window.delegate = self

        // Install NSToolbar BEFORE WindowManager calls makeKeyAndOrderFront so
        // the window's first paint already has the toolbar — eliminates the
        // visible "toolbar flash" (window briefly rendered without toolbar,
        // then toolbar appears). Requires the coordinator to exist now, which
        // is why WindowManager pre-creates SessionState and passes it in.
        // Falls back to lazy install (configureWindow / windowDidBecomeKey) if
        // session isn't available yet (welcome → connect race).
        if let sessionState {
            let owner = MainWindowToolbar(coordinator: sessionState.coordinator)
            self.toolbarOwner = owner
            window.toolbar = owner.managedToolbar
            startObservingToolbar(window: window, owner: owner)
        }

        Self.lifecycleLogger.info(
            "[open] TabWindowController.init payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) controllerId=\(self.controllerId, privacy: .public) eagerToolbar=\(sessionState != nil)"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TabWindowController does not support NSCoder init")
    }

    // MARK: - Toolbar Installation

    /// Install NSToolbar on the window. Called once from MainContentView.onAppear
    /// when the coordinator is guaranteed set up + registered. Toolbar items need
    /// `coordinator.commandActions` and `coordinator.toolbarState`, both ready
    /// at that point.
    /// Install (or re-install) the toolbar on this controller's window. Safe
    /// to call multiple times from different lifecycle triggers:
    /// - If no toolbar has been installed yet: create + assign.
    /// - If our previously-installed toolbar was discarded by macOS (can
    ///   happen during tab-group merge when called mid-transition): re-assign
    ///   the same managed instance to the window.
    /// Both Cmd+T (via menu) and the toolbar + button path exercise different
    /// lifecycle orderings; this lets either one end up with a populated
    /// toolbar regardless of whether `windowDidBecomeKey` fires.
    internal func installToolbar(coordinator: MainContentCoordinator) {
        guard let window else { return }
        if toolbarOwner == nil {
            toolbarOwner = MainWindowToolbar(coordinator: coordinator)
        }
        guard let owner = toolbarOwner else { return }
        // Synchronous assign — async dispatch caused a visible "toolbar flash"
        // (window briefly rendered with no toolbar before the async block ran
        // on the next runloop tick). If macOS discards the assignment during
        // `addTabbedWindow`'s mid-merge, the `windowDidBecomeKey` trigger
        // re-runs this method and the `window.toolbar !==` check re-assigns.
        if window.toolbar !== owner.managedToolbar {
            window.toolbar = owner.managedToolbar
        }
        startObservingToolbar(window: window, owner: owner)
    }

    /// Re-claim `window.toolbar` whenever something replaces it after our
    /// install. Empirically, SwiftUI's `NavigationSplitView` installs its own
    /// toolbar during initial layout — overwriting what we set in
    /// `configureWindow`. Without this KVO claim-back the user sees an empty
    /// toolbar from connect until they cmd-tab away and back (which fires
    /// `windowDidBecomeKey` and re-attaches via the `!==` check there).
    private func startObservingToolbar(window: NSWindow, owner: MainWindowToolbar) {
        toolbarKVO?.invalidate()
        toolbarKVO = nil
        toolbarKVO = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
            // KVO callbacks for AppKit properties run on the main thread; safe
            // to assume isolation. Guard re-checks owner since reassigning
            // `window.toolbar = owner.managedToolbar` below re-fires KVO.
            MainActor.assumeIsolated {
                guard let self,
                      let owner = self.toolbarOwner,
                      window.toolbar !== owner.managedToolbar
                else { return }
                let wasKey = window.isKeyWindow
                Self.lifecycleLogger.debug(
                    "[switch] KVO toolbar replaced — re-claiming controllerId=\(self.controllerId, privacy: .public) wasKey=\(wasKey)"
                )
                window.toolbar = owner.managedToolbar
                // Reassigning `window.toolbar` mid-flight (especially during a
                // SwiftUI view rebuild that happens AFTER the window became
                // key — observed in the toolbar "+" button path) makes AppKit
                // silently resign key with `newKeyWindow=nil`, leaving the
                // app focusless and disabling all menu shortcuts (Cmd+T,
                // Cmd+1...9). Restore key status if we just lost it.
                if wasKey && !window.isKeyWindow {
                    Self.lifecycleLogger.info(
                        "[focus] toolbar re-claim caused key loss — re-keying controllerId=\(self.controllerId, privacy: .public)"
                    )
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    internal func windowDidBecomeKey(_ notification: Notification) {
        let seq = MainContentCoordinator.nextSwitchSeq()
        let t0 = Date()
        guard let window = notification.object as? NSWindow,
              let coordinator = MainContentCoordinator.coordinator(forWindow: window)
        else { return }
        Self.lifecycleLogger.debug(
            "[switch] windowDidBecomeKey seq=\(seq) controllerId=\(self.controllerId, privacy: .public) connId=\(coordinator.connectionId, privacy: .public)"
        )
        installToolbar(coordinator: coordinator)
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
        toolbarKVO?.invalidate()
        toolbarKVO = nil

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
        let tableName: String? = (selectedTab?.tabType == .table) ? selectedTab?.tableName : nil
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
