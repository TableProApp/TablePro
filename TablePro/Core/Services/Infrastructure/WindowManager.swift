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

    internal func openTab(payload: EditorTabPayload, activate: Bool = true, autoConnect: Bool = false) {
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
        controllers.values.contains { $0.payload.connectionId == connectionId }
    }

    /// Every connection window from the moment it is created, including one that has not
    /// connected yet. `WindowLifecycleMonitor` only learns about a window once its content
    /// view mounts, which needs a live session.
    internal func allConnectionIds() -> Set<UUID> {
        Set(controllers.values.map(\.payload.connectionId))
    }

    internal func window(for connectionId: UUID) -> NSWindow? {
        controllers.values
            .first { $0.payload.connectionId == connectionId && $0.window?.isVisible == true }?
            .window
    }

    internal func connectionIdsRetainingRestoreIntent() -> [UUID] {
        var seen = Set<UUID>()
        return controllers.values.compactMap { controller -> UUID? in
            guard let splitVC = controller.window?.contentViewController as? MainSplitViewController,
                  splitVC.retainsRestoreIntent else { return nil }
            let connectionId = controller.payload.connectionId
            return seen.insert(connectionId).inserted ? connectionId : nil
        }
    }

    internal func closeWindow(for connectionId: UUID) {
        let matching = controllers.values.filter { $0.payload.connectionId == connectionId }
        for controller in matching {
            guard let window = controller.window, window.isVisible else { continue }
            window.close()
        }
    }

    internal static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-")
    }

    /// Fallback when the connection record is not available yet. Prefer
    /// `tabbingIdentifier(for: WorkspaceContextKey)` so tabs from different databases
    /// or schemas never join the same native group.
    internal static func tabbingIdentifier(for connectionId: UUID) -> String {
        "com.TablePro.main.\(connectionId.uuidString)"
    }

    internal static func tabbingIdentifier(for key: WorkspaceContextKey) -> String {
        key.tabbingIdentifier
    }

    internal static func tabbingIdentifier(payload: EditorTabPayload) -> String {
        guard let connection = WorkspaceContextResolver.connection(for: payload.connectionId) else {
            return tabbingIdentifier(for: payload.connectionId)
        }
        return tabbingIdentifier(for: WorkspaceContextResolver.resolve(payload: payload, connection: connection))
    }

    private func findSibling(tabbingIdentifier: String, excluding: NSWindow) -> NSWindow? {
        NSApp.windows.first { candidate in
            candidate !== excluding
                && Self.isMainWindow(candidate)
                && candidate.isVisible
                && candidate.tabbingIdentifier == tabbingIdentifier
        }
    }
}
