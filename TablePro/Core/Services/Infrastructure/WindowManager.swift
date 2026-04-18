//
//  WindowManager.swift
//  TablePro
//
//  Imperative AppKit window management for main editor tabs.
//  Phase 1 scope: create TabWindowController, install into tab group with
//  correct ordering (orderFront before addTabbedWindow — avoids the synchronous
//  full-tree layout that slowed the earlier prototype 4–5×), retain strong
//  reference, release on willClose.
//
//  In later phases WindowManager will also absorb the lookup API currently
//  on WindowLifecycleMonitor (windows(for:), previewWindow(for:), etc.).
//  In Phase 1, WindowLifecycleMonitor keeps that responsibility — this
//  manager only owns window creation + controller lifetime.
//

import AppKit
import os
import SwiftUI

@MainActor
internal final class WindowManager {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let shared = WindowManager()

    /// Strong refs keyed by NSWindow identity. Because
    /// `NSWindow.isReleasedWhenClosed = false` on our windows, this is the
    /// only owner — dropping the entry deallocates controller + window.
    private var controllers: [ObjectIdentifier: TabWindowController] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    // MARK: - Open

    /// Creates and shows a new main-editor window hosting ContentView(payload:).
    /// If a sibling window with the same tabbingIdentifier is already visible,
    /// the new window joins its tab group.
    internal func openTab(payload: EditorTabPayload) {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[open] WindowManager.openTab start payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) intent=\(String(describing: payload.intent), privacy: .public) skipAutoExecute=\(payload.skipAutoExecute)"
        )

        // Eagerly create SessionState (coordinator + tab manager + toolbar state)
        // BEFORE constructing the controller. This lets `TabWindowController.init`
        // install the NSToolbar synchronously — so the window's first paint
        // already has it, eliminating the toolbar-flash that occurs when the
        // toolbar is installed later via `configureWindow` (which runs only
        // after the window is on-screen).
        //
        // The same SessionState is handed off to ContentView via
        // `SessionStateFactory.consumePending` so only ONE coordinator exists
        // per window — no duplicate tabs.
        let resolvedConnection = DatabaseManager.shared.activeSessions[payload.connectionId]?.connection
        let preCreatedSessionState: SessionStateFactory.SessionState?
        if let resolvedConnection {
            let state = SessionStateFactory.create(connection: resolvedConnection, payload: payload)
            SessionStateFactory.registerPending(state, for: payload.id)
            preCreatedSessionState = state
        } else {
            // Connection not ready yet (welcome → connect race). Fall back to
            // lazy SessionState creation inside ContentView.init + lazy toolbar
            // install via configureWindow.
            preCreatedSessionState = nil
        }

        let controller = TabWindowController(payload: payload, sessionState: preCreatedSessionState)
        guard let window = controller.window else {
            Self.lifecycleLogger.error(
                "[open] WindowManager.openTab failed: controller has no window payloadId=\(payload.id, privacy: .public)"
            )
            // Clean up the pending state we registered above so it doesn't leak.
            SessionStateFactory.removePending(for: payload.id)
            return
        }

        retain(controller: controller, window: window)

        // Pre-mark so AppDelegate.windowDidBecomeKey skips its tabbing-merge
        // block (we do the merge here, at creation, with the correct ordering).
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.configuredWindows.insert(ObjectIdentifier(window))
        }

        // --- Tab-group merge, correctly ordered ---
        //
        // The earlier prototype called `addTabbedWindow(window, …)` before
        // the window was visible. AppKit responded by synchronously flushing
        // the NSHostingView's SwiftUI layout (NavigationSplitView + editor +
        // TreeSitterClient warmup) on the main thread — observed cost
        // 800–960 ms per open.
        //
        // Ordering `orderFront(nil)` first makes the window visible and lets
        // SwiftUI render asynchronously via its normal display cycle. Then
        // `addTabbedWindow` re-parents an already-visible window into the
        // tab group, which is a cheap AppKit-level operation.
        let tabbingId = window.tabbingIdentifier ?? ""
        let groupAll = AppSettingsManager.shared.tabs.groupAllConnectionTabs
        let sibling = findSibling(
            tabbingIdentifier: tabbingId, groupAll: groupAll, excluding: window
        )

        if let sibling {
            // Tab-merge: `addTabbedWindow(_:ordered:)` both adds the window to
            // the group AND orders it — calling orderFront separately beforehand
            // triggers a redundant layout pass on NSHostingView (observed cost
            // 700-900ms vs. 75ms standalone). Let addTabbedWindow do both at once.
            if groupAll {
                // groupAll mode: retag every visible main window with the unified
                // identifier so addTabbedWindow is willing to merge.
                let otherMains = NSApp.windows.filter {
                    $0 !== window && Self.isMainWindow($0) && $0.isVisible
                }
                for existing in otherMains {
                    existing.tabbingIdentifier = tabbingId
                }
            }
            let target = sibling.tabbedWindows?.last ?? sibling
            target.addTabbedWindow(window, ordered: .above)
            // `addTabbedWindow(_:ordered:)` only inserts — it doesn't select
            // the new tab in the group. `makeKeyAndOrderFront` brings this
            // window to the front of the group AND makes it key, which is
            // what the user expects on Cmd+T.
            window.makeKeyAndOrderFront(nil)
            Self.lifecycleLogger.info(
                "[open] WindowManager joined existing tab group payloadId=\(payload.id, privacy: .public) tabbingId=\(tabbingId, privacy: .public)"
            )
        } else {
            // Standalone case: center the frame BEFORE showing so the window
            // doesn't flash at the default (0,0) position before jumping.
            // `makeKeyAndOrderFront` is the standard AppKit idiom for this.
            window.center()
            window.makeKeyAndOrderFront(nil)
            // Ensure the app is active when opening from a background context
            // (e.g. Welcome window's Connect button races with welcome close).
            NSApp.activate(ignoringOtherApps: true)
            Self.lifecycleLogger.info(
                "[open] WindowManager standalone window payloadId=\(payload.id, privacy: .public) tabbingId=\(tabbingId, privacy: .public)"
            )
        }


        Self.lifecycleLogger.info(
            "[open] WindowManager.openTab done payloadId=\(payload.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

    // MARK: - Retention

    private func retain(controller: TabWindowController, window: NSWindow) {
        let key = ObjectIdentifier(window)
        controllers[key] = controller
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.release(windowKey: key)
            }
        }
    }

    private func release(windowKey: ObjectIdentifier) {
        if let observer = closeObservers.removeValue(forKey: windowKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        controllers.removeValue(forKey: windowKey)
    }

    // MARK: - Helpers

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-")
    }

    /// Tabbing identifier for a connection. Per-connection by default;
    /// shared "com.TablePro.main" when the user enables Group All Connection
    /// Tabs in Settings → Tabs. Used by `TabWindowController.init` and by
    /// AppDelegate's pre-Phase-1 fallback in `windowDidBecomeKey`.
    internal static func tabbingIdentifier(for connectionId: UUID) -> String {
        if AppSettingsManager.shared.tabs.groupAllConnectionTabs {
            return "com.TablePro.main"
        }
        return "com.TablePro.main.\(connectionId.uuidString)"
    }

    private func findSibling(
        tabbingIdentifier: String,
        groupAll: Bool,
        excluding: NSWindow
    ) -> NSWindow? {
        NSApp.windows.first { candidate in
            candidate !== excluding
                && Self.isMainWindow(candidate)
                && candidate.isVisible
                && (groupAll || candidate.tabbingIdentifier == tabbingIdentifier)
        }
    }
}
