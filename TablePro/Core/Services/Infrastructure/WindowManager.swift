//
//  WindowManager.swift
//  TablePro
//

import AppKit
import os

@MainActor
internal final class WindowManager {
    private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let shared = WindowManager()

    private var controllers: [UUID: ConnectionWindowController] = [:]
    private var closeObservers: [UUID: NSObjectProtocol] = [:]

    private init() {}

    // MARK: - Open

    /// Open the window for a connection, or focus it if already open. When a
    /// payload is provided, its intent is routed to the connection's
    /// coordinator (a new tab is added). Returns the controller id.
    @discardableResult
    internal func openConnectionWindow(
        for connectionId: UUID,
        intent payload: EditorTabPayload? = nil
    ) -> UUID? {
        let t0 = Date()

        if let existing = controllers[connectionId] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let payload {
                existing.coordinator.handleNewTabIntent(payload)
            }
            Self.lifecycleLogger.info(
                "[open] WindowManager focused existing window connId=\(connectionId, privacy: .public)"
            )
            return existing.controllerId
        }

        guard let connection = resolveConnection(connectionId) else {
            Self.lifecycleLogger.error(
                "[open] WindowManager.openConnectionWindow failed: no connection connId=\(connectionId, privacy: .public)"
            )
            return nil
        }

        let sessionState = SessionStateFactory.create(connection: connection)
        let controller = ConnectionWindowController(connection: connection, sessionState: sessionState)
        guard let window = controller.window else {
            Self.lifecycleLogger.error(
                "[open] WindowManager.openConnectionWindow failed: controller has no window connId=\(connectionId, privacy: .public)"
            )
            return nil
        }

        retain(controller: controller, connectionId: connectionId)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let payload {
            controller.coordinator.handleNewTabIntent(payload)
        }

        Self.lifecycleLogger.info(
            "[open] WindowManager.openConnectionWindow done connId=\(connectionId, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
        return controller.controllerId
    }

    private func resolveConnection(_ connectionId: UUID) -> DatabaseConnection? {
        DatabaseManager.shared.activeSessions[connectionId]?.connection
            ?? ConnectionStorage.shared.loadConnections().first { $0.id == connectionId }
    }

    // MARK: - Retention

    private func retain(controller: ConnectionWindowController, connectionId: UUID) {
        controllers[connectionId] = controller
        guard let window = controller.window else { return }
        closeObservers[connectionId] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.release(connectionId: connectionId)
            }
        }
    }

    private func release(connectionId: UUID) {
        if let observer = closeObservers.removeValue(forKey: connectionId) {
            NotificationCenter.default.removeObserver(observer)
        }
        controllers.removeValue(forKey: connectionId)
    }

    // MARK: - Helpers

    internal func hasOpenWindow(for connectionId: UUID) -> Bool {
        controllers[connectionId] != nil
    }

    internal func window(for connectionId: UUID) -> NSWindow? {
        controllers[connectionId]?.window
    }

    internal func closeWindow(for connectionId: UUID) {
        guard let window = controllers[connectionId]?.window, window.isVisible else { return }
        window.close()
    }
}
