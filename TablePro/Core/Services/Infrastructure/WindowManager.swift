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

    internal func openTab(payload: EditorTabPayload) {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[open] WindowManager.openTab start payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) intent=\(String(describing: payload.intent), privacy: .public) skipAutoExecute=\(payload.skipAutoExecute)"
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

        let controller = TabWindowController(payload: payload, sessionState: preCreatedSessionState)
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
        let groupAll = AppSettingsManager.shared.tabs.groupAllConnectionTabs
        let sibling = findSibling(
            tabbingIdentifier: tabbingId, groupAll: groupAll, excluding: window
        )

        if let sibling {
            if groupAll {
                let otherMains = NSApp.windows.filter {
                    $0 !== window && Self.isMainWindow($0) && $0.isVisible
                }
                for existing in otherMains {
                    existing.tabbingIdentifier = tabbingId
                }
            }
            let target = sibling.tabbedWindows?.last ?? sibling
            target.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            Self.lifecycleLogger.info(
                "[open] WindowManager joined existing tab group payloadId=\(payload.id, privacy: .public) tabbingId=\(tabbingId, privacy: .public)"
            )
        } else {
            window.makeKeyAndOrderFront(nil)
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

    internal func hasOpenWindow(for connectionId: UUID) -> Bool {
        controllers.values.contains { $0.payload.connectionId == connectionId }
    }

    internal func closeWindow(for connectionId: UUID) {
        let matching = controllers.values.filter { $0.payload.connectionId == connectionId }
        for controller in matching {
            guard let window = controller.window, window.isVisible else { continue }
            window.close()
        }
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-")
    }

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
