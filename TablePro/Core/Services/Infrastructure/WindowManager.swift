//
//  WindowManager.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

@MainActor
internal final class WindowManager {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let shared = WindowManager()

    private var controllers: [ObjectIdentifier: TabWindowController] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    // MARK: - Open

    /// One window hosts every connection, so an open reuses the window that already exists and
    /// only adds a workspace to it. A second window is created solely when there is none.
    internal func openTab(payload: EditorTabPayload, activate: Bool = true, autoConnect: Bool = false) {
        if let host = host(for: payload.connectionId) {
            /// A connection the window already hosts still has to honour the payload, because a
            /// payload names a tab to open, not just a connection to show. Adopting the
            /// workspace alone would silently drop the table the caller asked for.
            if let existing = host.workspaces.workspace(for: payload.connectionId) {
                host.workspaces.select(payload.connectionId)
                existing.open(payload)
            } else {
                host.adoptWorkspace(payload: payload, autoConnect: autoConnect)
            }
            if activate {
                host.view.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            Self.lifecycleLogger.info(
                "[open] WindowManager adopted into existing window connId=\(payload.connectionId, privacy: .public)"
            )
            return
        }
        openInNewWindow(payload: payload, activate: activate, autoConnect: autoConnect)
    }

    /// A host is any visible window whose content controller can hold workspaces. Selecting by the
    /// `main-` identifier prefix also matched the inspector window, whose controller is a different
    /// type, so the cast failed and an inspector in front made every open create a second window.
    private func frontmostHost() -> MainSplitViewController? {
        if let key = NSApp.keyWindow, key.isVisible,
           let host = key.contentViewController as? MainSplitViewController {
            return host
        }
        return NSApp.windows
            .filter(\.isVisible)
            .compactMap { $0.contentViewController as? MainSplitViewController }
            .first
    }

    /// The window already hosting this connection wins, so opening a table for it never lands in
    /// a different window that merely happened to be in front. The choice itself is
    /// `WindowHostSelection`, which is pure and tested.
    private func host(for connectionId: UUID) -> MainSplitViewController? {
        let candidates = hosts()
        guard !candidates.isEmpty else { return nil }
        let frontmost = frontmostHost()
        let frontmostIndex = frontmost.flatMap { front in
            candidates.firstIndex { $0 === front }
        }
        guard let index = WindowHostSelection.hostIndex(
            forConnection: connectionId,
            hostedConnections: candidates.map(\.workspaces.connectionIds),
            frontmostIndex: frontmostIndex
        ) else { return nil }
        return candidates.indices.contains(index) ? candidates[index] : nil
    }

    private func openInNewWindow(payload: EditorTabPayload, activate: Bool, autoConnect: Bool) {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[open] WindowManager.openTab start payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) intent=\(String(describing: payload.intent), privacy: .public) skipAutoExecute=\(payload.skipAutoExecute) activate=\(activate)"
        )

        let resolvedConnection = DatabaseManager.shared.activeSessions[payload.connectionId]?.connection
        let preCreatedSessionState: SessionStateFactory.SessionState?
        if let resolvedConnection {
            let state = SessionStateFactory.create(connection: resolvedConnection, payload: payload)
            SessionStateFactory.registerPending(state, for: payload.id)
            preCreatedSessionState = state
        } else {
            preCreatedSessionState = nil
        }

        let controller = TabWindowController(
            payload: payload,
            sessionState: preCreatedSessionState,
            autoConnect: autoConnect
        )
        guard let window = controller.window else {
            Self.lifecycleLogger.error(
                "[open] WindowManager.openTab failed: controller has no window payloadId=\(payload.id, privacy: .public)"
            )
            SessionStateFactory.removePending(for: payload.id)
            return
        }

        retain(controller: controller, window: window)

        // orderFront before addTabbedWindow avoids a synchronous full-tree
        // SwiftUI layout pass that adds 700-900ms per open.
        let tabbingId = window.tabbingIdentifier ?? ""
        let sibling = findSibling(tabbingIdentifier: tabbingId, excluding: window)

        if let sibling {
            let target = sibling.tabbedWindows?.last ?? sibling
            target.addTabbedWindow(window, ordered: .above)
            if activate {
                window.makeKeyAndOrderFront(nil)
            }
            Self.lifecycleLogger.info(
                "[open] WindowManager joined existing tab group payloadId=\(payload.id, privacy: .public) tabbingId=\(tabbingId, privacy: .public)"
            )
        } else {
            if activate {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window.orderFront(nil)
            }
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

    internal func hasOpenWindow(for connectionId: UUID) -> Bool {
        hosts().contains { $0.workspaces.contains(connectionId) }
    }

    private func hosts() -> [MainSplitViewController] {
        controllers.values.compactMap { $0.window?.contentViewController as? MainSplitViewController }
    }

    /// Every connection window from the moment it is created, including one that has not
    /// connected yet. `WindowLifecycleMonitor` only learns about a window once its content
    /// view mounts, which needs a live session.
    internal func allConnectionIds() -> Set<UUID> {
        Set(hosts().flatMap(\.workspaces.connectionIds))
    }

    internal func window(for connectionId: UUID) -> NSWindow? {
        controllers.values
            .first { controller in
                guard controller.window?.isVisible == true else { return false }
                guard let host = controller.window?.contentViewController as? MainSplitViewController
                else { return false }
                return host.workspaces.contains(connectionId)
            }?
            .window
    }

    internal func connectionIdsRetainingRestoreIntent() -> [UUID] {
        var seen = Set<UUID>()
        return controllers.values
            .compactMap { $0.window?.contentViewController as? MainSplitViewController }
            .flatMap(\.connectionIdsRetainingRestoreIntent)
            .filter { seen.insert($0).inserted }
    }

    /// Closing a connection removes its workspace. The window itself only closes once it has no
    /// connection left to show, because it is no longer the connection's window.
    /// A miniaturized window still hosts its connections, so `isVisible` is not the test: closing a
    /// connection while its window was minimized left the workspace in place with no way to reach it.
    internal func closeWindow(for connectionId: UUID) {
        var closedAnywhere = false
        for controller in controllers.values {
            guard let window = controller.window else { continue }
            guard let host = window.contentViewController as? MainSplitViewController else { continue }
            guard let removed = host.workspaces.remove(connectionId) else { continue }
            removed.teardown()
            closedAnywhere = true
            if host.workspaces.isEmpty {
                window.close()
            } else {
                host.applySelectedWorkspace()
            }
        }
        guard closedAnywhere else { return }

        /// Closing a connection ends it. The window used to do that on its way out, which covered
        /// this while a connection owned its window; a connection closed out of a window that stays
        /// open reached nothing, and its driver, tunnel and health monitor ran on unreferenced.
        WindowLifecycleMonitor.shared.unregisterWindows(for: connectionId)
        Task { await DatabaseManager.shared.disconnectSession(connectionId) }
    }

    internal static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-")
    }

    /// One identifier for every app window. Editor tabs live in the window's own strip now, so
    /// the native tab bar is free to mean what AppKit means by it: several app windows the user
    /// chose to group. That is also what makes Merge All Windows work.
    internal static let mainTabbingIdentifier = "com.TablePro.main"

    private func findSibling(tabbingIdentifier: String, excluding: NSWindow) -> NSWindow? {
        NSApp.windows.first { candidate in
            candidate !== excluding
                && Self.isMainWindow(candidate)
                && candidate.isVisible
                && candidate.tabbingIdentifier == tabbingIdentifier
        }
    }
}
